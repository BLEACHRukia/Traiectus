# Windows 发送优化的现场更新脚本

update-server.ps1 来自2026-10-11现场测试包。含中文，必须保留 UTF-8 BOM，供Windows PowerShell5.1读取。
发布测试包时需要把通过构建验证的 Traiectus-Server.exe 和 manifest.json（server_sha256、source_commit）放在同目录。
不在仓库提交生产配对配置、installed-state.json、用户机器安装回报或 exe 备份。

脚本定位正在运行的托盘及服务端，备份旧exe，仅替换服务端并重启托盘；失败尝试恢复。
`-Restore` 使用同目录的 installed-state.json 验证原备份、恢复原服务端。

现场已验证：更新、第一次失败后的自动回退、更新后重新配对使用原配置。
停止托盘会同时清理job内服务端，第二次停止的检查/操作之间存在进程消失的竞态；
只在停止失败且进程仍然存活时报告错误。不能仅凭一次 Get-Process 判定就认为 Stop-Process 必定成功。

服务端日志由托盘重新启动时清空重写；跨版本对照需在运行更新脚本前自行复制该日志。
脚本不会自动判断鼠标体感或声称现场验证通过。
