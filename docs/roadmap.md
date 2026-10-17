# 改进计划

## v0.5.0（集成分支 `release/v0.5.0-dev`，等待发布）

已完成，见 [`release-notes/v0.5.0.md`](release-notes/v0.5.0.md)：
- 服务器一键管理脚本（#7）
- 回收站（#8）
- 忘记密码与数据救援（#9）
- Android 返回键逐级返回，以及全平台交互规范自查修复（#6），清单见 [`qa/platform-conventions-audit.md`](qa/platform-conventions-audit.md)

## 下一版本（v0.4.1）

- **服务器一键管理脚本**：`scripts/syncnotes-server.sh`，Linux 服务器包内附带。中文菜单 + 子命令，支持临时运行、后台持久运行、安装为 systemd 服务并开机自启、停止、状态 / 日志、更新（自动回滚）、卸载；自动发现旧安装和手动启动的实例，备份并迁移数据。见 [`server-script.md`](server-script.md)
- 服务器程序支持 `--version`

## 之后

- 中文应用名（等待决定）
- Android 真机验证：预测性返回动画、分享进出、输入法避让；Windows 真机验证：拖放、HiDPI、多显示器窗口位置

- Windows 客户端由 CI 恢复构建（目前需要在 Windows 上手动构建，见 [`build-windows.md`](build-windows.md)）
- Android 使用固定的发布签名，升级时不必卸载旧版
