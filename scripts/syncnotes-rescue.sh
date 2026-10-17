#!/usr/bin/env bash
# SyncNotes 忘记密码 / 数据救援（syncnotes-server.sh rescue 的快捷入口）
#
#   sudo ./syncnotes-rescue.sh                       交互菜单
#   sudo ./syncnotes-rescue.sh list-users            列出用户
#   sudo ./syncnotes-rescue.sh reset <用户名> [--password X]
#                    重置密码为默认 syncnotes123456（或 X / 环境变量 SYNCNOTES_RESCUE_PASSWORD），登录后强制修改
#   sudo ./syncnotes-rescue.sh export <用户名> [输出.zip]
#   sudo ./syncnotes-rescue.sh backup                在线备份数据库
# 选项 -y/--yes 跳过确认。路径读取 /etc/syncnotes/syncnotes.env。
set -uo pipefail
case "${1-}" in -h|--help) sed -n '2,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/syncnotes-server.sh" rescue "$@"
