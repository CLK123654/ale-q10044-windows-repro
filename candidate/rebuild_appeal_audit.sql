.bail on
.timeout 5000
PRAGMA foreign_keys = OFF;

BEGIN IMMEDIATE;

DROP TABLE IF EXISTS thread_summary;
DROP TABLE IF EXISTS sla_report;
DROP TABLE IF EXISTS rule_rollup;
DROP TABLE IF EXISTS quality_exceptions;
DROP TABLE IF EXISTS audit_summary;
DROP TABLE IF EXISTS temp._ticket_resolution;
DROP TABLE IF EXISTS temp._valid_ticket_map;
DROP TABLE IF EXISTS temp._event_rule_hits;
DROP TABLE IF EXISTS temp._queue_guard;

CREATE TABLE quality_exceptions (
  ticket_id TEXT PRIMARY KEY,
  issue_code TEXT NOT NULL,
  detail TEXT NOT NULL
);

CREATE TEMP TABLE _ticket_resolution AS
WITH RECURSIVE parent_walk(
  start_ticket_id,
  current_ticket_id,
  parent_ticket_id,
  walk_path,
  depth,
  root_ticket_id,
  issue_code
) AS (
  SELECT
    ticket_id,
    ticket_id,
    parent_ticket_id,
    '|' || ticket_id || '|',
    0,
    CASE WHEN parent_ticket_id IS NULL THEN ticket_id END,
    NULL
  FROM appeal_ticket

  UNION ALL

  SELECT
    walk.start_ticket_id,
    parent.ticket_id,
    parent.parent_ticket_id,
    walk.walk_path || parent.ticket_id || '|',
    walk.depth + 1,
    CASE
      WHEN instr(walk.walk_path, '|' || parent.ticket_id || '|') = 0
       AND parent.parent_ticket_id IS NULL
      THEN parent.ticket_id
    END,
    CASE
      WHEN instr(walk.walk_path, '|' || parent.ticket_id || '|') > 0
      THEN (
        SELECT issue_code
        FROM runtime_quality_issue_code
        WHERE issue_code = 'cycle_detected'
      )
    END
  FROM parent_walk AS walk
  JOIN appeal_ticket AS parent
    ON parent.ticket_id = walk.parent_ticket_id
  WHERE walk.root_ticket_id IS NULL
    AND walk.issue_code IS NULL
    AND walk.depth < 100
),
resolution AS (
  SELECT
    source.ticket_id,
    MAX(parent_walk.root_ticket_id) AS root_ticket_id,
    CASE
      WHEN MAX(parent_walk.issue_code = 'cycle_detected') = 1
      THEN (
        SELECT issue_code
        FROM runtime_quality_issue_code
        WHERE issue_code = 'cycle_detected'
      )
      WHEN MAX(parent_walk.root_ticket_id) IS NULL
       AND source.parent_ticket_id IS NOT NULL
       AND EXISTS (
         SELECT 1
         FROM parent_walk AS terminal
         WHERE terminal.start_ticket_id = source.ticket_id
           AND terminal.parent_ticket_id IS NOT NULL
           AND NOT EXISTS (
             SELECT 1
             FROM appeal_ticket AS missing_parent
             WHERE missing_parent.ticket_id = terminal.parent_ticket_id
           )
       )
      THEN (
        SELECT issue_code
        FROM runtime_quality_issue_code
        WHERE issue_code = 'orphan_parent'
      )
    END AS issue_code
  FROM appeal_ticket AS source
  JOIN parent_walk ON parent_walk.start_ticket_id = source.ticket_id
  GROUP BY source.ticket_id
)
SELECT ticket_id, root_ticket_id, issue_code
FROM resolution;

INSERT INTO quality_exceptions(ticket_id, issue_code, detail)
SELECT
  resolution.ticket_id,
  resolution.issue_code,
  CASE resolution.issue_code
    WHEN 'orphan_parent' THEN
      'parent_ticket_id ' || ticket.parent_ticket_id || ' is missing'
    WHEN 'cycle_detected' THEN
      'parent chain repeats ' || ticket.ticket_id || ' through ' || ticket.parent_ticket_id
  END
FROM _ticket_resolution AS resolution
JOIN appeal_ticket AS ticket USING (ticket_id)
WHERE resolution.issue_code IS NOT NULL
ORDER BY resolution.ticket_id;

CREATE TEMP TABLE _valid_ticket_map (
  ticket_id TEXT PRIMARY KEY,
  root_ticket_id TEXT NOT NULL
);

INSERT INTO _valid_ticket_map(ticket_id, root_ticket_id)
SELECT ticket_id, root_ticket_id
FROM _ticket_resolution
WHERE issue_code IS NULL
  AND root_ticket_id IS NOT NULL
ORDER BY ticket_id;

CREATE TEMP TABLE _queue_guard (
  all_queues_mapped INTEGER NOT NULL CHECK (all_queues_mapped = 1)
);

INSERT INTO _queue_guard
SELECT CAST(NOT EXISTS (
  SELECT 1
  FROM _valid_ticket_map AS members
  JOIN appeal_ticket AS ticket USING (ticket_id)
  LEFT JOIN runtime_queue_assignment AS assignment USING (queue)
  WHERE assignment.owner_team IS NULL
) AS INTEGER);

CREATE TEMP TABLE _event_rule_hits AS
SELECT
  event.event_id,
  event.ticket_id,
  ticket_map.root_ticket_id,
  CAST(rule_hit.value AS TEXT) AS rule_code,
  catalog.category,
  catalog.priority,
  catalog.auto_escalate
FROM ticket_event AS event
JOIN _valid_ticket_map AS ticket_map USING (ticket_id)
JOIN json_each(event.payload_json, '$.rule_hits') AS rule_hit
JOIN rule_catalog AS catalog
  ON catalog.rule_code = CAST(rule_hit.value AS TEXT);

CREATE TABLE thread_summary (
  root_ticket_id TEXT PRIMARY KEY,
  ticket_count INTEGER NOT NULL,
  open_ticket_count INTEGER NOT NULL,
  max_severity TEXT NOT NULL,
  regions TEXT NOT NULL,
  queues TEXT NOT NULL,
  owner_teams TEXT NOT NULL,
  first_created_at_utc TEXT NOT NULL,
  last_event_at_utc TEXT NOT NULL,
  rule_hit_count INTEGER NOT NULL,
  auto_escalate_hits INTEGER NOT NULL
);

INSERT INTO thread_summary
SELECT
  roots.root_ticket_id,
  (
    SELECT COUNT(*)
    FROM _valid_ticket_map AS members
    WHERE members.root_ticket_id = roots.root_ticket_id
  ),
  (
    SELECT COUNT(*)
    FROM _valid_ticket_map AS members
    JOIN appeal_ticket AS ticket USING (ticket_id)
    WHERE members.root_ticket_id = roots.root_ticket_id
      AND ticket.status = 'open'
  ),
  (
    SELECT ticket.severity
    FROM _valid_ticket_map AS members
    JOIN appeal_ticket AS ticket USING (ticket_id)
    JOIN sla_policy AS policy USING (severity)
    WHERE members.root_ticket_id = roots.root_ticket_id
    ORDER BY policy.severity_rank DESC, ticket.severity
    LIMIT 1
  ),
  (
    SELECT group_concat(region, ',')
    FROM (
      SELECT DISTINCT ticket.region
      FROM _valid_ticket_map AS members
      JOIN appeal_ticket AS ticket USING (ticket_id)
      WHERE members.root_ticket_id = roots.root_ticket_id
      ORDER BY ticket.region
    )
  ),
  (
    SELECT group_concat(queue, ',')
    FROM (
      SELECT DISTINCT ticket.queue
      FROM _valid_ticket_map AS members
      JOIN appeal_ticket AS ticket USING (ticket_id)
      WHERE members.root_ticket_id = roots.root_ticket_id
      ORDER BY ticket.queue
    )
  ),
  (
    SELECT group_concat(owner_team, ',')
    FROM (
      SELECT DISTINCT assignment.owner_team
      FROM _valid_ticket_map AS members
      JOIN appeal_ticket AS ticket USING (ticket_id)
      JOIN runtime_queue_assignment AS assignment USING (queue)
      WHERE members.root_ticket_id = roots.root_ticket_id
      ORDER BY assignment.owner_team
    )
  ),
  (
    SELECT MIN(ticket.created_at_utc)
    FROM _valid_ticket_map AS members
    JOIN appeal_ticket AS ticket USING (ticket_id)
    WHERE members.root_ticket_id = roots.root_ticket_id
  ),
  (
    SELECT MAX(event.event_ts_utc)
    FROM _valid_ticket_map AS members
    JOIN ticket_event AS event USING (ticket_id)
    WHERE members.root_ticket_id = roots.root_ticket_id
  ),
  (
    SELECT COUNT(*)
    FROM _event_rule_hits AS hit
    WHERE hit.root_ticket_id = roots.root_ticket_id
  ),
  (
    SELECT COALESCE(SUM(hit.auto_escalate), 0)
    FROM _event_rule_hits AS hit
    WHERE hit.root_ticket_id = roots.root_ticket_id
  )
FROM (
  SELECT DISTINCT root_ticket_id
  FROM _valid_ticket_map
) AS roots
ORDER BY roots.root_ticket_id;

CREATE TABLE sla_report (
  root_ticket_id TEXT PRIMARY KEY,
  max_severity TEXT NOT NULL,
  first_created_at_utc TEXT NOT NULL,
  first_response_at_utc TEXT,
  terminal_at_utc TEXT,
  response_minutes INTEGER NOT NULL,
  resolve_minutes INTEGER,
  response_sla_minutes INTEGER NOT NULL,
  resolve_sla_minutes INTEGER NOT NULL,
  response_breached INTEGER NOT NULL CHECK (response_breached IN (0, 1)),
  resolve_breached INTEGER NOT NULL CHECK (resolve_breached IN (0, 1))
);

WITH event_bounds AS (
  SELECT
    summary.root_ticket_id,
    summary.max_severity,
    summary.first_created_at_utc,
    MIN(CASE
      WHEN event.action = (SELECT first_response_action FROM runtime_contract)
      THEN event.event_ts_utc
    END) AS first_response_at_utc,
    MAX(CASE
      WHEN event.action IN (SELECT action FROM runtime_terminal_action)
      THEN event.event_ts_utc
    END) AS terminal_at_utc
  FROM thread_summary AS summary
  JOIN _valid_ticket_map AS members USING (root_ticket_id)
  JOIN ticket_event AS event USING (ticket_id)
  GROUP BY summary.root_ticket_id
),
minutes AS (
  SELECT
    bounds.*,
    CAST((
      unixepoch(COALESCE(
        bounds.first_response_at_utc,
        (SELECT report_cutoff_utc FROM runtime_contract)
      )) - unixepoch(bounds.first_created_at_utc)
    ) / 60 AS INTEGER) AS response_minutes,
    CASE
      WHEN bounds.terminal_at_utc IS NOT NULL THEN
        CAST((
          unixepoch(bounds.terminal_at_utc)
          - unixepoch(bounds.first_created_at_utc)
        ) / 60 AS INTEGER)
    END AS resolve_minutes
  FROM event_bounds AS bounds
)
INSERT INTO sla_report
SELECT
  minutes.root_ticket_id,
  minutes.max_severity,
  minutes.first_created_at_utc,
  minutes.first_response_at_utc,
  minutes.terminal_at_utc,
  minutes.response_minutes,
  minutes.resolve_minutes,
  policy.response_minutes,
  policy.resolve_minutes,
  CASE WHEN minutes.response_minutes > policy.response_minutes THEN 1 ELSE 0 END,
  CASE
    WHEN minutes.resolve_minutes IS NOT NULL
     AND minutes.resolve_minutes > policy.resolve_minutes
    THEN 1 ELSE 0
  END
FROM minutes
JOIN sla_policy AS policy
  ON policy.severity = minutes.max_severity
ORDER BY minutes.root_ticket_id;

CREATE TABLE rule_rollup (
  rule_code TEXT PRIMARY KEY,
  category TEXT NOT NULL,
  priority INTEGER NOT NULL,
  ticket_count INTEGER NOT NULL,
  thread_count INTEGER NOT NULL,
  event_count INTEGER NOT NULL,
  auto_escalate_count INTEGER NOT NULL
);

INSERT INTO rule_rollup
SELECT
  catalog.rule_code,
  catalog.category,
  catalog.priority,
  COUNT(DISTINCT hit.ticket_id),
  COUNT(DISTINCT hit.root_ticket_id),
  COUNT(DISTINCT hit.event_id),
  COALESCE(SUM(hit.auto_escalate), 0)
FROM rule_catalog AS catalog
JOIN _event_rule_hits AS hit USING (rule_code)
GROUP BY catalog.rule_code, catalog.category, catalog.priority
ORDER BY catalog.priority DESC, catalog.rule_code;

CREATE TABLE audit_summary (
  metric_key TEXT PRIMARY KEY,
  metric_value TEXT NOT NULL
);

INSERT INTO audit_summary VALUES
  ('config.report_cutoff_utc', (SELECT report_cutoff_utc FROM runtime_contract)),
  ('source.ticket_rows', (SELECT COUNT(*) FROM appeal_ticket)),
  ('source.event_rows', (SELECT COUNT(*) FROM ticket_event)),
  ('source.queue_assignment_rows', (SELECT COUNT(*) FROM runtime_queue_assignment)),
  ('result.thread_rows', (SELECT COUNT(*) FROM thread_summary)),
  ('result.valid_ticket_rows', (SELECT COUNT(*) FROM _valid_ticket_map)),
  ('result.exception_rows', (SELECT COUNT(*) FROM quality_exceptions)),
  ('result.rule_rows', (SELECT COUNT(*) FROM rule_rollup)),
  ('result.sla_rows', (SELECT COUNT(*) FROM sla_report)),
  ('result.response_breaches', (SELECT COALESCE(SUM(response_breached), 0) FROM sla_report)),
  ('result.resolve_breaches', (SELECT COALESCE(SUM(resolve_breached), 0) FROM sla_report)),
  ('result.auto_escalate_hits', (SELECT COALESCE(SUM(auto_escalate_hits), 0) FROM thread_summary)),
  (
    'check.all_queues_mapped',
    (
      SELECT CAST(NOT EXISTS (
        SELECT 1
        FROM _valid_ticket_map AS members
        JOIN appeal_ticket AS ticket USING (ticket_id)
        LEFT JOIN runtime_queue_assignment AS assignment USING (queue)
        WHERE assignment.owner_team IS NULL
      ) AS TEXT)
    )
  ),
  (
    'check.exceptions_excluded',
    (
      SELECT CAST(NOT EXISTS (
        SELECT 1
        FROM quality_exceptions AS exception
        JOIN _valid_ticket_map AS members USING (ticket_id)
      ) AS TEXT)
    )
  ),
  (
    'check.thread_sla_roots_match',
    (
      SELECT CAST(
        NOT EXISTS (
          SELECT root_ticket_id FROM thread_summary
          EXCEPT
          SELECT root_ticket_id FROM sla_report
        )
        AND NOT EXISTS (
          SELECT root_ticket_id FROM sla_report
          EXCEPT
          SELECT root_ticket_id FROM thread_summary
        )
        AS TEXT
      )
    )
  );

INSERT INTO audit_summary
SELECT
  'status',
  CASE
    WHEN MIN(CAST(metric_value AS INTEGER)) = 1
    THEN (SELECT ready_status FROM runtime_contract)
    ELSE (SELECT blocked_status FROM runtime_contract)
  END
FROM audit_summary
WHERE metric_key LIKE 'check.%';

COMMIT;

.headers on
.mode csv
.once output/reports/thread_summary.csv
SELECT
  root_ticket_id,
  ticket_count,
  open_ticket_count,
  max_severity,
  regions,
  queues,
  owner_teams,
  first_created_at_utc,
  last_event_at_utc,
  rule_hit_count,
  auto_escalate_hits
FROM thread_summary
ORDER BY root_ticket_id;

.once output/reports/sla_report.csv
SELECT
  root_ticket_id,
  max_severity,
  first_created_at_utc,
  first_response_at_utc,
  terminal_at_utc,
  response_minutes,
  resolve_minutes,
  response_sla_minutes,
  resolve_sla_minutes,
  response_breached,
  resolve_breached
FROM sla_report
ORDER BY root_ticket_id;

.once output/reports/rule_rollup.csv
SELECT
  rule_code,
  category,
  priority,
  ticket_count,
  thread_count,
  event_count,
  auto_escalate_count
FROM rule_rollup
ORDER BY priority DESC, rule_code;

.once output/reports/quality_exceptions.csv
SELECT ticket_id, issue_code, detail
FROM quality_exceptions
ORDER BY ticket_id;

.headers off
.mode list
.once output/reports/audit_summary.json
SELECT json_object(
  'status', (SELECT metric_value FROM audit_summary WHERE metric_key = 'status'),
  'report_cutoff_utc', (SELECT metric_value FROM audit_summary WHERE metric_key = 'config.report_cutoff_utc'),
  'source', json_object(
    'ticket_rows', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'source.ticket_rows') AS INTEGER),
    'event_rows', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'source.event_rows') AS INTEGER),
    'queue_assignment_rows', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'source.queue_assignment_rows') AS INTEGER)
  ),
  'result', json_object(
    'thread_rows', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'result.thread_rows') AS INTEGER),
    'valid_ticket_rows', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'result.valid_ticket_rows') AS INTEGER),
    'exception_rows', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'result.exception_rows') AS INTEGER),
    'rule_rows', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'result.rule_rows') AS INTEGER),
    'sla_rows', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'result.sla_rows') AS INTEGER),
    'response_breaches', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'result.response_breaches') AS INTEGER),
    'resolve_breaches', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'result.resolve_breaches') AS INTEGER),
    'auto_escalate_hits', CAST((SELECT metric_value FROM audit_summary WHERE metric_key = 'result.auto_escalate_hits') AS INTEGER)
  ),
  'checks', json_object(
    'all_queues_mapped', json(CASE (SELECT metric_value FROM audit_summary WHERE metric_key = 'check.all_queues_mapped') WHEN '1' THEN 'true' ELSE 'false' END),
    'exceptions_excluded', json(CASE (SELECT metric_value FROM audit_summary WHERE metric_key = 'check.exceptions_excluded') WHEN '1' THEN 'true' ELSE 'false' END),
    'thread_sla_roots_match', json(CASE (SELECT metric_value FROM audit_summary WHERE metric_key = 'check.thread_sla_roots_match') WHEN '1' THEN 'true' ELSE 'false' END)
  )
);

.once stdout
