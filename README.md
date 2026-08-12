# 内容申诉积压的SQLite线程归并与时效审计

这个仓库保存本题正文、四个附件、完成后的SQL和Windows运行脚本。输入包含申诉工单数据库、报告合同和队列责任表。SQLite负责父链归并、规则展开、时效计算和报表导出，Node.js只负责准备运行目录与调用SQLite CLI。

四个附件位于artifacts目录，任务正文位于task目录，完成后的SQL位于candidate目录。工作流使用windows-2025、Node.js24和SQLite3.51.2，核对两处带中文和空格的工作目录，并确认截止时间变化会改变开放线程时长。队列CSV还会以CRLF换行格式载入SQLite。

在Windows PowerShell中执行：

    ./scripts/windows_gate.ps1 -RepositoryRoot $PWD -EvidenceRoot $env:TEMP/ale-q10044-evidence

SQLite安装阶段需要联网。业务运行阶段只读取本地文件，不访问外部服务。
