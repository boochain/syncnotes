# SyncNotes 1

自己部署的多设备笔记。正文和文件在离开这台设备之前加密，服务器只保存密文。

这是从零重写的协议 1。它**不能**连接 0.6 的服务器，也不能打开 0.6 的本地库。旧数据导入还没有做。

## 客户端

- 登录 / 注册。同一密码在每台设备上推出同一把钥匙，用来解开笔记和文件。
- 笔记实时同步。断线时改动留在本地，连上再推。
- 附件加密后上传。进度按已经写进网络的字节走。等服务器确认时显示「确认中」。失败留在列表里，写出原因。
- 桌面：放大 / 缩小会先取消最大化，并且一定换成另一个尺寸。Windows 关闭按钮收到托盘。
- 外观只有浅色、深色、跟随系统。没有液态玻璃，也没有叠在一起的动画。

## 服务器

一个可执行文件，外加一个 SQLite 和一个文件目录。

```bash
./syncnotes-server --bind 0.0.0.0:7700 --db /var/lib/syncnotes/syncnotes.db --files-dir /var/lib/syncnotes/files
```

没写 `--db` 时，数据放在 `~/.local/share/syncnotes`（Windows 是 `%LOCALAPPDATA%\SyncNotes`），不放在程序目录里。

`GET /health` 返回 `{"ok":true,"protocol":1}`。

环境变量和以前的安装脚本兼容：`SYNCNOTES_BIND`、`SYNCNOTES_DB`、`SYNCNOTES_FILES`、`SYNCNOTES_ALLOW_REGISTER`。

## 限制

- 单篇笔记密文上限约 1 MB。单个文件上限 4 GB。
- 还没有回收站、斜杠菜单、局域网发现、恢复码和管理员导出。这些不会在旧代码上继续打补丁，要做就按这个新协议加。
