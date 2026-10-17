# 服务器一键管理脚本 `syncnotes-server.sh`

适用于 Linux（Debian / Ubuntu / CentOS / Rocky / Alpine 等）。需要 root 权限；用普通用户运行时脚本会自动通过 `sudo` 重新运行。

## 准备

把脚本和服务器程序放在同一目录（从下一个版本起，Linux 服务器压缩包里已经带有脚本）：

```bash
tar xzf syncnotes-server-<版本>-linux-x86_64.tar.gz
cd syncnotes-server-<版本>-linux-x86_64
sudo ./syncnotes-server.sh
```

## 菜单

| 选项 | 子命令 | 作用 |
|---|---|---|
| 1 临时运行 | `run` | 在当前终端前台运行，按 Ctrl+C 停止，适合试用 |
| 2 持久运行 | `start` | 后台运行（nohup + setsid），关闭 SSH 也不会停止；不开机自启。PID 文件 `/opt/syncnotes/syncnotes.pid`，日志 `/opt/syncnotes/syncnotes.log` |
| 3 安装为系统服务并开机自启 | `install [程序或 .tar.gz]` | 写入 `/etc/systemd/system/syncnotes.service`（`Restart=always`）并 `enable`；可以重复运行，用来修改配置或重新安装 |
| 4 删除开机自启 | `disable` | 停止并删除 systemd 服务，数据保留 |
| 5 停止 | `stop` | 停止系统服务、后台实例，以及任何手动启动的 `syncnotes-server` 进程 |
| 6 状态 / 日志 | `status`、`logs [-f]` | 显示配置、服务状态、进程、端口；查看最近日志（`-f` 持续跟踪） |
| 7 更新 / 替换为新版 | `update [程序或 .tar.gz]` | 备份数据库，原子替换程序，重启并检查；新版本启动失败时自动回滚 |
| 8 卸载 | `uninstall` | 需要输入 `yes` 确认；会询问是否同时删除数据（默认保留） |

在子命令后加 `-y` / `--yes` 时不再提问，直接使用上次保存的配置或默认值，适合在其他脚本中调用。

## 参数（回车使用默认值）

| 参数 | 默认值 | 说明 |
|---|---|---|
| 端口 | 7700 | 检查范围 1–65535；端口被其他程序占用时会显示占用的进程 |
| 监听地址 | 0.0.0.0 | 只给本机的反向代理（Caddy / Nginx）用时填 127.0.0.1 |
| 安装目录 | /opt/syncnotes | 程序、日志、PID 文件 |
| 数据库 | /opt/syncnotes/data/syncnotes.db | |
| 文件目录 | /opt/syncnotes/data/syncnotes-files | 上传的文件 |
| 允许注册 | 是 | 建好自己的账号后建议改为"否"（再运行一次 `install` 即可） |
| mDNS 局域网发现 | 是 | 名称默认 SyncNotes |

配置保存在 `/etc/syncnotes/syncnotes.env`（systemd 的 EnvironmentFile，变量名与服务器的环境变量相同：`SYNCNOTES_BIND`、`SYNCNOTES_DB`、`SYNCNOTES_FILES`、`SYNCNOTES_ALLOW_REGISTER`、`SYNCNOTES_MDNS`、`SYNCNOTES_MDNS_NAME`），下次运行时作为默认值。

服务以系统用户 `syncnotes` 运行（脚本自动创建，无法创建时退回 root）。
检测到 ufw 或 firewalld 时会询问是否放行端口；云服务器还需要在控制台的安全组中放行该端口。

## 旧版本与升级

`install` 和 `update` 会先检查：

- 任何调用 `syncnotes-server` 的 systemd 服务（包括旧名字、旧位置的单元文件，以及按旧版 README 安装、数据在 `/var/lib/syncnotes` 的服务）
- 用 nohup 或手动从任意目录启动的进程：通过 `/proc/<PID>/cwd`、命令行参数和环境变量找出它实际使用的数据库和文件目录
- 常见位置的旧程序（`/usr/local/bin`、`/usr/bin`、`/opt`、`/root`、`/home/*`），以及失效的 PID 文件

然后：停止所有旧实例 → 给数据库做带时间戳的备份（`syncnotes.db.bak-年月日-时分秒`，每个数据库保留最近 5 份）→ 询问是否把旧数据迁移到新目录（默认是；新位置已有数据库时不会覆盖）→ 把新程序复制为 `.new` 后 `mv` 替换，旧程序保留为 `syncnotes-server.old` → 重启并检查进程存活、端口在监听。新程序启动失败时自动换回旧程序并重启。

旧程序文件只会列出，不会删除；迁移后旧数据也保留在原处，确认无误后可以自行删除。

新程序的来源：命令中给出的路径（程序本身或 `.tar.gz`），否则使用脚本旁边的 `syncnotes-server`。替换前会先运行 `--help` 检查程序能否在本机运行（例如 CPU 架构是否正确）。

## 没有 systemd 的系统

Alpine（OpenRC）、Docker 容器或 WSL1 等没有 systemd 时，脚本会说明原因，"安装"会改为"持久运行"（后台运行，重启后需要再次运行 `start`）。OpenRC 用户可以把 `/路径/syncnotes-server.sh start --yes` 写入 `/etc/local.d/syncnotes.start` 并执行 `rc-update add local` 实现开机启动。

## 常用命令

```bash
sudo ./syncnotes-server.sh                    # 菜单
sudo ./syncnotes-server.sh install            # 安装为系统服务并开机自启
sudo ./syncnotes-server.sh status             # 状态
sudo ./syncnotes-server.sh logs -f            # 跟踪日志
sudo ./syncnotes-server.sh update 新版.tar.gz  # 升级（失败自动回滚）
sudo ./syncnotes-server.sh stop               # 停止
sudo ./syncnotes-server.sh uninstall          # 卸载
```
