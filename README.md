# 内容申诉积压的SQLite线程归并与时效审计

这个仓库只保存本题正文、四个最终附件、完成后的SQL和独立Windows门禁。输入包含申诉工单数据库、报告合同和队列责任表。SQLite负责父链归并、规则展开、时效计算和报表导出，Node.js只负责准备运行目录与调用SQLite CLI。

四个附件位于artifacts目录，任务正文位于task目录，完成后的SQL位于candidate目录。工作流使用windows-2025、Node.js24和SQLite3.51.2，在两个带中文和空格的新目录中各运行两次，再执行截止时间变化、缺少队列责任映射和CRLF换行测试。

在Windows PowerShell中执行：

    ./scripts/windows_gate.ps1 -RepositoryRoot $PWD -EvidenceRoot $env:TEMP/ale-q10044-evidence

SQLite安装阶段需要联网。业务运行阶段只读取本地文件，不访问外部服务。
