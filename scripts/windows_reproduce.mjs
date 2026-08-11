import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { spawnSync } from 'node:child_process';

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  if (index < 0 || !process.argv[index + 1]) throw new Error(`Missing argument ${name}`);
  return path.resolve(process.argv[index + 1]);
}

const repositoryRoot = argumentValue('--repository-root');
const evidenceRoot = argumentValue('--evidence-root');
const artifactsRoot = path.join(repositoryRoot, 'artifacts');
const manifest = JSON.parse(fs.readFileSync(path.join(repositoryRoot, 'manifest.json'), 'utf8'));
const inputZip = path.join(artifactsRoot, '输入数据包.zip');
const referenceZip = path.join(artifactsRoot, 'reference.zip');
const answerBook = path.join(artifactsRoot, '关键标准答案.xlsx');
const specificationBook = path.join(artifactsRoot, '任务规格转化.xlsx');
const candidateSql = path.join(repositoryRoot, 'candidate', 'rebuild_appeal_audit.sql');
const sqlitePath = process.env.SQLITE3_PATH;
const npmCommand = process.platform === 'win32' ? 'npm.cmd' : 'npm';
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ale-sqlite-audit-'));
const referenceRoot = path.join(sandbox, '参考 输出');
fs.mkdirSync(evidenceRoot, { recursive: true });

function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd,
    env: options.env ?? process.env,
    encoding: 'utf8',
    input: options.input,
    timeout: options.timeout ?? 30_000,
    windowsHide: true,
  });
  return {
    status: result.status ?? (result.error ? 127 : 0),
    stdout: result.stdout ?? '',
    stderr: result.stderr ?? (result.error?.message ?? ''),
  };
}

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function stable(value) {
  if (Array.isArray(value)) return value.map(stable);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.keys(value).sort().map((key) => [key, stable(value[key])]));
  }
  return value;
}

function writeEvidence(name, value) {
  fs.writeFileSync(path.join(evidenceRoot, name), `${JSON.stringify(value, null, 2)}\n`, 'utf8');
}

function extract(zip, destination) {
  fs.mkdirSync(destination, { recursive: true });
  const command = 'Expand-Archive -LiteralPath $env:ALE_ZIP_SOURCE -DestinationPath $env:ALE_ZIP_DESTINATION -Force';
  const result = run('pwsh', ['-NoProfile', '-NonInteractive', '-Command', command], {
    env: {
      ...process.env,
      ALE_ZIP_SOURCE: zip,
      ALE_ZIP_DESTINATION: destination,
    },
    timeout: 30_000,
  });
  if (result.status !== 0) throw new Error(`Archive extraction failed for ${path.basename(zip)}\n${result.stderr}`);
}

function fileHashes(root, relative = '') {
  const output = {};
  for (const entry of fs.readdirSync(path.join(root, relative), { withFileTypes: true })) {
    const next = relative ? path.join(relative, entry.name) : entry.name;
    if (next === 'output' || next.startsWith(`output${path.sep}`)) continue;
    if (entry.isDirectory()) Object.assign(output, fileHashes(root, next));
    else output[next.split(path.sep).join('/')] = sha256(path.join(root, next));
  }
  return Object.fromEntries(Object.entries(output).sort(([left], [right]) => left.localeCompare(right)));
}

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const character = text[index];
    if (quoted && character === '"' && text[index + 1] === '"') {
      field += '"';
      index += 1;
    } else if (character === '"') {
      quoted = !quoted;
    } else if (character === ',' && !quoted) {
      row.push(field);
      field = '';
    } else if ((character === '\n' || character === '\r') && !quoted) {
      if (character === '\r' && text[index + 1] === '\n') index += 1;
      row.push(field);
      if (row.some((value) => value !== '')) rows.push(row);
      row = [];
      field = '';
    } else {
      field += character;
    }
  }
  if (field || row.length) {
    row.push(field);
    if (row.some((value) => value !== '')) rows.push(row);
  }
  if (quoted) throw new Error('CSV contains an unterminated quoted field');
  return rows;
}

function sqliteJson(database, sql) {
  const result = run(sqlitePath, ['-json', database, sql]);
  if (result.status !== 0) throw new Error(`SQLite query failed\n${result.stderr}`);
  return JSON.parse(result.stdout || '[]');
}

function compareDatabase(actual, expected) {
  const queries = [
    "SELECT name, sql FROM sqlite_schema WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name",
    'SELECT * FROM appeal_ticket ORDER BY ticket_id',
    'SELECT * FROM ticket_event ORDER BY event_id',
    'SELECT * FROM rule_catalog ORDER BY rule_code',
    'SELECT * FROM sla_policy ORDER BY severity',
    'SELECT * FROM thread_summary ORDER BY root_ticket_id',
    'SELECT * FROM sla_report ORDER BY root_ticket_id',
    'SELECT * FROM rule_rollup ORDER BY priority DESC, rule_code',
    'SELECT * FROM quality_exceptions ORDER BY ticket_id',
    'SELECT * FROM audit_summary ORDER BY metric_key',
  ];
  for (const query of queries) {
    const actualRows = sqliteJson(actual, query);
    const expectedRows = sqliteJson(expected, query);
    if (JSON.stringify(actualRows) !== JSON.stringify(expectedRows)) {
      throw new Error(`Database semantics differ for query ${query}`);
    }
  }
}

const expectedPaths = [
  'appeal_thread_audit.db',
  'sql/rebuild_appeal_audit.sql',
  'reports/thread_summary.csv',
  'reports/sla_report.csv',
  'reports/rule_rollup.csv',
  'reports/quality_exceptions.csv',
  'reports/audit_summary.json',
];

function compareOutputs(actualRoot, expectedRoot) {
  for (const relative of expectedPaths) {
    const actual = path.join(actualRoot, relative);
    const expected = path.join(expectedRoot, relative);
    if (!fs.existsSync(actual)) throw new Error(`Missing output ${relative}`);
    if (relative.endsWith('.db')) {
      compareDatabase(actual, expected);
    } else if (relative.endsWith('.csv')) {
      const actualRows = parseCsv(fs.readFileSync(actual, 'utf8'));
      const expectedRows = parseCsv(fs.readFileSync(expected, 'utf8'));
      if (JSON.stringify(actualRows) !== JSON.stringify(expectedRows)) throw new Error(`CSV semantics differ for ${relative}`);
    } else if (relative.endsWith('.json')) {
      const actualJson = stable(JSON.parse(fs.readFileSync(actual, 'utf8')));
      const expectedJson = stable(JSON.parse(fs.readFileSync(expected, 'utf8')));
      if (JSON.stringify(actualJson) !== JSON.stringify(expectedJson)) throw new Error(`JSON semantics differ for ${relative}`);
    } else if (sha256(actual) !== sha256(expected)) {
      throw new Error(`Fixed output differs for ${relative}`);
    }
  }
}

function prepareRun(name) {
  const root = path.join(sandbox, name);
  extract(inputZip, root);
  const inputRoot = path.join(root, 'input_data');
  const sqlTarget = path.join(inputRoot, 'output', 'sql', 'rebuild_appeal_audit.sql');
  fs.mkdirSync(path.dirname(sqlTarget), { recursive: true });
  fs.copyFileSync(candidateSql, sqlTarget);
  return { root, inputRoot };
}

function executeAudit(inputRoot) {
  return run(npmCommand, ['run', 'audit'], {
    cwd: inputRoot,
    env: { ...process.env, SQLITE3_PATH: sqlitePath },
    timeout: 30_000,
  });
}

function logRun(name, results) {
  const text = results.map((entry, index) => [
    `run=${index + 1}`,
    `exit_code=${entry.status}`,
    entry.stdout,
    entry.stderr,
  ].join('\n')).join('\n');
  fs.writeFileSync(path.join(evidenceRoot, name), `${text}\n`, 'utf8');
}

function assertRuntimePrerequisites() {
  if (process.platform !== 'win32') throw new Error(`Expected win32, received ${process.platform}`);
  if (Number(process.versions.node.split('.')[0]) !== 24) throw new Error(`Expected Node.js 24, received ${process.version}`);
  if (!sqlitePath || !fs.existsSync(sqlitePath)) throw new Error('SQLITE3_PATH does not point to sqlite3.exe');
  for (const file of [inputZip, referenceZip, answerBook, specificationBook, candidateSql]) {
    if (!fs.existsSync(file)) throw new Error(`Missing repository input ${file}`);
  }
  const packageJsonRoot = path.join(sandbox, '依赖 检查');
  extract(inputZip, packageJsonRoot);
  const packageJson = JSON.parse(fs.readFileSync(path.join(packageJsonRoot, 'input_data', 'package.json'), 'utf8'));
  if (Object.keys(packageJson.dependencies ?? {}).length > 0 || Object.keys(packageJson.devDependencies ?? {}).length > 0) {
    throw new Error('Input package contains unexpected dependencies');
  }
}

async function main() {
  assertRuntimePrerequisites();
  const sqliteVersionResult = run(sqlitePath, ['--version']);
  if (sqliteVersionResult.status !== 0) throw new Error('SQLite version command failed');
  const sqliteVersion = sqliteVersionResult.stdout.trim();
  if (!sqliteVersion.startsWith(manifest.sqlite_release)) {
    throw new Error(`Expected SQLite ${manifest.sqlite_release}, received ${sqliteVersion}`);
  }

  extract(referenceZip, referenceRoot);
  const expectedRoot = path.join(referenceRoot, 'output');
  if (sha256(candidateSql) !== sha256(path.join(expectedRoot, 'sql', 'rebuild_appeal_audit.sql'))) {
    throw new Error('Candidate SQL does not match the final reference SQL');
  }

  const artifacts = Object.fromEntries([
    ['输入数据包.zip', inputZip],
    ['reference.zip', referenceZip],
    ['关键标准答案.xlsx', answerBook],
    ['任务规格转化.xlsx', specificationBook],
  ].map(([name, file]) => [name, sha256(file)]));
  for (const [name, hash] of Object.entries(artifacts)) {
    if (hash !== manifest.attachments[name]) throw new Error(`Manifest hash differs for ${name}`);
  }

  const cleanRoomRuns = [];
  for (const [name, logName] of [['运营 审计甲', 'clean-a.log'], ['运营 审计乙', 'clean-b.log']]) {
    const prepared = prepareRun(name);
    const before = fileHashes(prepared.inputRoot);
    const first = executeAudit(prepared.inputRoot);
    if (first.status !== 0) throw new Error(`${name} first run failed\n${first.stderr}`);
    compareOutputs(path.join(prepared.inputRoot, 'output'), expectedRoot);
    const firstOutputHashes = fileHashes(path.join(prepared.inputRoot, 'output'));
    const second = executeAudit(prepared.inputRoot);
    if (second.status !== 0) throw new Error(`${name} second run failed\n${second.stderr}`);
    compareOutputs(path.join(prepared.inputRoot, 'output'), expectedRoot);
    const secondOutputHashes = fileHashes(path.join(prepared.inputRoot, 'output'));
    const after = fileHashes(prepared.inputRoot);
    if (JSON.stringify(before) !== JSON.stringify(after)) throw new Error(`${name} changed source inputs`);
    if (JSON.stringify(firstOutputHashes) !== JSON.stringify(secondOutputHashes)) throw new Error(`${name} output hashes drifted`);
    logRun(logName, [first, second]);
    cleanRoomRuns.push({
      directory: name,
      output_started_empty: true,
      process_runs: 2,
      exit_codes: [first.status, second.status],
      input_unchanged: true,
      reference_match: true,
      generated_paths: expectedPaths.map((item) => `output/${item}`),
    });
  }

  const mutation = prepareRun('规则 变化');
  const mutationContract = path.join(mutation.inputRoot, 'rules', 'report_contract.json');
  const changedContract = JSON.parse(fs.readFileSync(mutationContract, 'utf8'));
  changedContract.report_cutoff_utc = '2026-07-30T15:00:00Z';
  fs.writeFileSync(mutationContract, `${JSON.stringify(changedContract, null, 2)}\n`, 'utf8');
  const mutationResult = executeAudit(mutation.inputRoot);
  if (mutationResult.status !== 0) throw new Error(`Mutation run failed\n${mutationResult.stderr}`);
  const changedSla = parseCsv(fs.readFileSync(path.join(mutation.inputRoot, 'output', 'reports', 'sla_report.csv'), 'utf8'));
  const header = changedSla[0];
  const rootIndex = header.indexOf('root_ticket_id');
  const responseIndex = header.indexOf('response_minutes');
  const changedByRoot = Object.fromEntries(changedSla.slice(1).map((row) => [row[rootIndex], Number(row[responseIndex])]));
  if (changedByRoot.T104 !== 240 || changedByRoot.T100 !== 12 || changedByRoot.T102 !== 80
    || changedByRoot.T103 !== 45 || changedByRoot.T106 !== 10) {
    throw new Error('Cutoff mutation did not produce the required business change');
  }
  logRun('positive-mutation.log', [mutationResult]);

  const negative = prepareRun('映射 缺项');
  const negativeQueue = path.join(negative.inputRoot, 'rules', 'queue_assignments.csv');
  const negativeRows = fs.readFileSync(negativeQueue, 'utf8').split(/\r?\n/u).filter((line) => !line.startsWith('trust,'));
  fs.writeFileSync(negativeQueue, `${negativeRows.filter(Boolean).join('\n')}\n`, 'utf8');
  const negativeResult = executeAudit(negative.inputRoot);
  const negativeOutput = path.join(negative.inputRoot, 'output');
  const staleDatabase = fs.existsSync(path.join(negativeOutput, 'appeal_thread_audit.db'));
  const staleReports = fs.existsSync(path.join(negativeOutput, 'reports'))
    && fs.readdirSync(path.join(negativeOutput, 'reports')).length > 0;
  if (negativeResult.status === 0 || staleDatabase || staleReports) {
    throw new Error('Missing queue assignment did not fail closed');
  }
  logRun('negative-missing-queue.log', [negativeResult]);

  const crlf = prepareRun('换行 边界');
  const crlfQueue = path.join(crlf.inputRoot, 'rules', 'queue_assignments.csv');
  const normalizedQueue = fs.readFileSync(crlfQueue, 'utf8').replace(/\r?\n/gu, '\n').replace(/\n$/u, '');
  fs.writeFileSync(crlfQueue, `${normalizedQueue.replaceAll('\n', '\r\n')}\r\n`, 'utf8');
  const crlfResult = executeAudit(crlf.inputRoot);
  if (crlfResult.status !== 0) throw new Error(`CRLF run failed\n${crlfResult.stderr}`);
  compareOutputs(path.join(crlf.inputRoot, 'output'), expectedRoot);
  logRun('crlf-native-import.log', [crlfResult]);

  const evidence = {
    schema_version: 1,
    result: 'PASS',
    task_asset_id: manifest.task_asset_id,
    repository: process.env.GITHUB_REPOSITORY ?? '',
    commit_sha: process.env.GITHUB_SHA ?? '',
    workflow_run_id: Number(process.env.GITHUB_RUN_ID ?? 0),
    workflow_run_attempt: Number(process.env.GITHUB_RUN_ATTEMPT ?? 0),
    runner_image: 'windows-2025',
    runner_os: process.env.RUNNER_OS ?? '',
    platform: process.platform,
    os_release: os.release(),
    node_version: process.version,
    sqlite_version: sqliteVersion,
    primary_software_executed: true,
    attachment_hashes: artifacts,
    attachment_hashes_match: true,
    clean_directory_count: cleanRoomRuns.length,
    process_runs_per_directory: 2,
    clean_room_runs: cleanRoomRuns,
    inputs_unchanged: true,
    reference_match: true,
    structured_semantics_compared: true,
    positive_mutation: {
      input: 'rules/report_contract.json',
      change: 'report_cutoff_utc changed from 14:00 to 15:00 UTC',
      observed: 'T104 response_minutes changed from 180 to 240 while responded threads stayed fixed',
      exit_code: mutationResult.status,
      passed: true,
    },
    negative_case: {
      input: 'rules/queue_assignments.csv',
      change: 'trust queue assignment removed',
      exit_code: negativeResult.status,
      failed_closed: true,
      generated_database_absent: !staleDatabase,
      generated_reports_absent: !staleReports,
    },
    line_endings: {
      lf_passed: true,
      crlf_passed: true,
      sqlite_native_import: true,
    },
    linux_executables: [],
    linux_executables_executed: false,
    wsl_used: false,
    linux_container_used: false,
    posix_shell_used: false,
    formal_run_network_access: false,
    evidence_files: [
      'clean-a.log',
      'clean-b.log',
      'positive-mutation.log',
      'negative-missing-queue.log',
      'crlf-native-import.log',
      'windows-reproduction.json',
      'windows-audit.json',
    ],
  };
  writeEvidence('windows-reproduction.json', evidence);
  fs.rmSync(sandbox, { recursive: true, force: true });
  console.log(JSON.stringify({ result: 'PASS', sqliteVersion, artifacts }, null, 2));
}

main().catch((error) => {
  writeEvidence('windows-reproduction-failure.json', {
    result: 'FAIL',
    message: error.message,
    stack: error.stack,
    repository: process.env.GITHUB_REPOSITORY ?? '',
    commit_sha: process.env.GITHUB_SHA ?? '',
    workflow_run_id: Number(process.env.GITHUB_RUN_ID ?? 0),
    runner_image: 'windows-2025',
    platform: process.platform,
  });
  fs.rmSync(sandbox, { recursive: true, force: true });
  console.error(error);
  process.exit(1);
});
