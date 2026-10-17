#!/usr/bin/env bash
# SyncNotes 服务器一键管理脚本（Linux）
#
# 交互菜单：  sudo ./syncnotes-server.sh
# 子命令：    sudo ./syncnotes-server.sh <命令> [参数]
#   install [路径]   安装 / 重新安装为系统服务并开机自启（路径可以是新版程序或 .tar.gz）
#   run              临时运行（前台，Ctrl+C 停止）
#   start            持久运行（后台，关闭 SSH 也不停，不开机自启）
#   stop             停止所有正在运行的实例（系统服务 + 后台 + 手动启动的）
#   enable           安装 systemd 服务并开机自启（同 install，但不替换程序）
#   disable          删除开机自启（停止并删除 systemd 服务，数据保留）
#   status           查看状态
#   logs [-f]        查看日志（-f 持续跟踪）
#   update [路径]    更新 / 替换为新版程序（失败自动回滚）
#   uninstall        卸载
# 选项：
#   -y, --yes        全部使用默认值 / 上次保存的配置，不再提问（适合脚本调用）
#   --open-firewall  防火墙已启用时放行端口（默认从不修改防火墙；防火墙未启用时什么也不做）
#
# 配置保存在 /etc/syncnotes/syncnotes.env，下次运行时作为默认值。

set -uo pipefail
PATH="$PATH:/usr/local/sbin:/usr/sbin:/sbin"

# ---------------------------------------------------------------- 常量
ENV_DIR="${SYNCNOTES_ENV_DIR:-/etc/syncnotes}"
ENV_FILE="$ENV_DIR/syncnotes.env"
UNIT_NAME="syncnotes"
UNIT_DIR="${SYNCNOTES_UNIT_DIR:-/etc/systemd/system}"
UNIT_FILE="$UNIT_DIR/$UNIT_NAME.service"
SVC_USER="syncnotes"
BIN_NAME="syncnotes-server"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_PATH="$SCRIPT_DIR/$(basename "${BASH_SOURCE[0]}")"
ASSUME_YES=0
OPEN_FW=0
TMP_DIRS=()

# 默认值（会被 ENV_FILE 覆盖）
CFG_DIR="/opt/syncnotes"
CFG_ADDR="0.0.0.0"
CFG_PORT="7700"
CFG_DB=""
CFG_FILES=""
CFG_REGISTER="true"
CFG_MDNS="true"
CFG_MDNS_NAME="SyncNotes"

# ---------------------------------------------------------------- 输出
if [ -t 1 ]; then C_G=$'\e[32m'; C_Y=$'\e[33m'; C_R=$'\e[31m'; C_B=$'\e[1m'; C_0=$'\e[0m'; else C_G=""; C_Y=""; C_R=""; C_B=""; C_0=""; fi
info() { printf '%s\n' "${C_G}[信息]${C_0} $*"; }
warn() { printf '%s\n' "${C_Y}[注意]${C_0} $*" >&2; }
err()  { printf '%s\n' "${C_R}[错误]${C_0} $*" >&2; }
die()  { err "$*"; exit 1; }
title() { printf '\n%s\n' "${C_B}== $* ==${C_0}"; }

cleanup() { local d; for d in "${TMP_DIRS[@]+"${TMP_DIRS[@]}"}"; do rm -rf "$d"; done; }
trap cleanup EXIT

# ask 变量名 "提示" 默认值
ask() {
  local __var=$1 __prompt=$2 __def=${3-} __ans=""
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then printf -v "$__var" '%s' "$__def"; return; fi
  read -r -p "$__prompt [默认: $__def]: " __ans || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}
# ask_yn "提示" y|n  → 返回 0 表示是
ask_yn() {
  local prompt=$1 def=${2:-y} ans="" hint="[Y/n]"
  [ "$def" = n ] && hint="[y/N]"
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then [ "$def" = y ]; return; fi
  while true; do
    read -r -p "$prompt $hint: " ans || ans=""
    ans=${ans:-$def}
    case "$ans" in y|Y|yes|是) return 0 ;; n|N|no|否) return 1 ;; *) echo "请输入 y 或 n" ;; esac
  done
}
# 危险操作确认：--yes 时也要求明确
confirm_danger() {
  local prompt=$1 ans=""
  [ "$ASSUME_YES" = 1 ] && return 0
  [ -t 0 ] || return 1
  read -r -p "$prompt 输入 yes 确认: " ans || true
  [ "$ans" = yes ]
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if command -v sudo >/dev/null 2>&1; then
      info "需要 root 权限，正在通过 sudo 重新运行……"
      exec sudo -E bash "$SCRIPT_PATH" "$@"
    fi
    die "请用 root 运行（例如 sudo bash $0）"
  fi
}

has_systemd() {
  [ "${SYNCNOTES_ASSUME_SYSTEMD:-0}" = 1 ] && return 0
  [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1
}
explain_no_systemd() {
  warn "这台机器没有运行 systemd（例如 Alpine/OpenRC、Docker 容器或 WSL1），无法安装系统服务。"
  warn "可以改用菜单 2「持久运行」（后台运行，关闭 SSH 不会停止，但重启机器后需要再次启动）；"
  warn "OpenRC 用户也可以把「$SCRIPT_PATH start」加入 /etc/local.d/syncnotes.start 实现开机启动。"
}

# ---------------------------------------------------------------- 配置
SAFE_RE='^[][A-Za-z0-9._/@:+, -]*$'
safe_value() { [[ "$1" =~ $SAFE_RE ]]; }

load_config() {
  [ -f "$ENV_FILE" ] || { derive_paths; return 0; }
  local k v
  while IFS='=' read -r k v; do
    v=${v%\"}; v=${v#\"}
    case "$k" in
      SYNCNOTES_INSTALL_DIR) CFG_DIR=$v ;;
      SYNCNOTES_BIND) if [[ "$v" =~ ^(.*):([0-9]+)$ ]]; then CFG_ADDR=${BASH_REMATCH[1]}; CFG_PORT=${BASH_REMATCH[2]}; CFG_ADDR=${CFG_ADDR#[}; CFG_ADDR=${CFG_ADDR%]}; fi ;;
      SYNCNOTES_DB) CFG_DB=$v ;;
      SYNCNOTES_FILES) CFG_FILES=$v ;;
      SYNCNOTES_ALLOW_REGISTER) CFG_REGISTER=$v ;;
      SYNCNOTES_MDNS) CFG_MDNS=$v ;;
      SYNCNOTES_MDNS_NAME) CFG_MDNS_NAME=$v ;;
    esac
  done < <(grep -E '^[A-Z_]+=' "$ENV_FILE")
  derive_paths
}
derive_paths() {
  [ -n "$CFG_DB" ] || CFG_DB="$CFG_DIR/data/syncnotes.db"
  [ -n "$CFG_FILES" ] || CFG_FILES="$CFG_DIR/data/syncnotes-files"
  BIN="$CFG_DIR/$BIN_NAME"
  PIDFILE="$CFG_DIR/syncnotes.pid"
  LOGFILE="$CFG_DIR/syncnotes.log"
}
bind_value() { if [[ "$CFG_ADDR" == *:* ]]; then echo "[$CFG_ADDR]:$CFG_PORT"; else echo "$CFG_ADDR:$CFG_PORT"; fi; }

save_config() {
  mkdir -p "$ENV_DIR"
  local tmp="$ENV_FILE.tmp"
  {
    echo "# SyncNotes 服务器配置（由 syncnotes-server.sh 生成，systemd EnvironmentFile 格式）"
    echo "# 修改后执行：sudo $SCRIPT_PATH install 或 systemctl restart $UNIT_NAME"
    echo "SYNCNOTES_INSTALL_DIR=\"$CFG_DIR\""
    echo "SYNCNOTES_BIND=\"$(bind_value)\""
    echo "SYNCNOTES_DB=\"$CFG_DB\""
    echo "SYNCNOTES_FILES=\"$CFG_FILES\""
    echo "SYNCNOTES_ALLOW_REGISTER=\"$CFG_REGISTER\""
    echo "SYNCNOTES_MDNS=\"$CFG_MDNS\""
    echo "SYNCNOTES_MDNS_NAME=\"$CFG_MDNS_NAME\""
    echo "RUST_LOG=\"info\""
  } > "$tmp"
  chmod 644 "$tmp"
  mv -f "$tmp" "$ENV_FILE"
  info "配置已保存到 $ENV_FILE"
}

# ---------------------------------------------------------------- 端口
port_owner() { # 输出占用端口的进程描述，未占用时返回 1
  local port=$1 out=""
  if command -v ss >/dev/null 2>&1; then
    out=$(ss -ltnpH "sport = :$port" 2>/dev/null)
  elif command -v netstat >/dev/null 2>&1; then
    out=$(netstat -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p"$"')
  else
    (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && out="（未知进程，系统没有 ss/netstat）"
  fi
  [ -n "$out" ] || return 1
  printf '%s\n' "$out"
}
port_listening() { port_owner "$1" >/dev/null 2>&1 || (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

# ---------------------------------------------------------------- 发现旧实例
# 输出所有 syncnotes-server 进程的 PID（按可执行文件名匹配，含 nohup / 手动启动的）
find_pids() {
  local p exe
  for p in /proc/[0-9]*; do
    exe=$(readlink "$p/exe" 2>/dev/null) || continue
    case "${exe% (deleted)}" in */"$BIN_NAME"|*/"$BIN_NAME".new|*/"$BIN_NAME".old) echo "${p#/proc/}" ;; esac
  done
}
# 解析某个进程实际使用的数据库 / 文件目录
proc_data_paths() { # pid → 输出两行：db、files
  local pid=$1 cwd db="" files="" a prev=""
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd="/"
  while IFS= read -r -d '' a; do
    case "$prev" in --db) db=$a ;; --files-dir) files=$a ;; esac
    case "$a" in --db=*) db=${a#--db=} ;; --files-dir=*) files=${a#--files-dir=} ;; esac
    prev=$a
  done < "/proc/$pid/cmdline"
  if [ -z "$db" ] || [ -z "$files" ]; then
    while IFS= read -r -d '' a; do
      case "$a" in SYNCNOTES_DB=*) [ -n "$db" ] || db=${a#SYNCNOTES_DB=} ;; SYNCNOTES_FILES=*) [ -n "$files" ] || files=${a#SYNCNOTES_FILES=} ;; esac
    done < "/proc/$pid/environ" 2>/dev/null
  fi
  db=${db:-syncnotes.db}; files=${files:-syncnotes-files}
  case "$db" in /*) ;; *) db="$cwd/$db" ;; esac
  case "$files" in /*) ;; *) files="$cwd/$files" ;; esac
  printf '%s\n%s\n' "$db" "$files"
}
find_units() { # 所有调用 syncnotes-server 的 systemd 单元文件（包括旧名字）
  local d
  for d in "$UNIT_DIR" /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system; do
    [ -d "$d" ] || continue
    grep -lE "ExecStart=.*$BIN_NAME" "$d"/*.service 2>/dev/null
  done | sort -u
}
find_old_bins() {
  local f
  for f in /usr/local/bin/"$BIN_NAME" /usr/bin/"$BIN_NAME" /opt/syncnotes*/"$BIN_NAME" /root/"$BIN_NAME" /root/*/"$BIN_NAME" /home/*/"$BIN_NAME" /home/*/*/"$BIN_NAME" /srv/*/"$BIN_NAME"; do
    [ -f "$f" ] && [ "$f" != "$BIN" ] && echo "$f"
  done
}
OLD_DATA=()  # "db|files" 形式，记录发现的旧数据位置
scan_old() {
  title "检查旧版本和残留"
  local u pid paths db files found=0 b
  OLD_DATA=()
  while IFS= read -r u; do
    [ -n "$u" ] || continue
    found=1; info "发现 systemd 服务：$u"
    local wd ex
    wd=$(sed -n 's/^WorkingDirectory=//p' "$u" | head -1)
    ex=$(sed -n 's/^ExecStart=//p' "$u" | head -1)
    db=$(sed -n 's/.*--db[= ]\([^ ]*\).*/\1/p' <<<"$ex")
    files=$(sed -n 's/.*--files-dir[= ]\([^ ]*\).*/\1/p' <<<"$ex")
    if [ "$u" != "$UNIT_FILE" ] || [ -n "$db" ]; then
      [ -n "$db" ] || db=syncnotes.db
      [ -n "$files" ] || files=syncnotes-files
      case "$db" in /*) ;; *) db="${wd:-/}/$db" ;; esac
      case "$files" in /*) ;; *) files="${wd:-/}/$files" ;; esac
      OLD_DATA+=("$db|$files")
    fi
  done < <(find_units)
  for pid in $(find_pids); do
    found=1
    mapfile -t paths < <(proc_data_paths "$pid")
    info "发现正在运行的进程 PID $pid：$(readlink "/proc/$pid/exe")，工作目录 $(readlink "/proc/$pid/cwd")"
    info "    数据库 ${paths[0]}，文件目录 ${paths[1]}"
    OLD_DATA+=("${paths[0]}|${paths[1]}")
  done
  while IFS= read -r b; do [ -n "$b" ] && { found=1; info "发现旧程序：$b"; }; done < <(find_old_bins)
  for b in "$PIDFILE" /var/run/syncnotes.pid /run/syncnotes.pid /tmp/syncnotes*.pid; do
    [ -f "$b" ] || continue
    if ! kill -0 "$(cat "$b" 2>/dev/null)" 2>/dev/null; then info "删除失效的 PID 文件：$b"; rm -f "$b"; fi
  done
  [ "$found" = 1 ] || info "没有发现旧版本"
}

# ---------------------------------------------------------------- 停止
stop_all() {
  local u n pids pid i
  if has_systemd; then
    while IFS= read -r u; do
      [ -n "$u" ] || continue
      n=$(basename "$u")
      if systemctl is-active --quiet "$n" 2>/dev/null; then info "停止系统服务 $n"; systemctl stop "$n" || true; fi
    done < <(find_units)
  fi
  if [ -f "${PIDFILE:-/nonexistent}" ]; then
    pid=$(cat "$PIDFILE" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then info "停止后台实例 PID $pid"; kill "$pid" 2>/dev/null || true; fi
    rm -f "$PIDFILE"
  fi
  pids=$(find_pids | tr '\n' ' ')
  if [ -n "${pids// }" ]; then
    info "停止其他 syncnotes-server 进程：$pids"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
  fi
  for i in $(seq 1 50); do
    [ -z "$(find_pids)" ] && break
    sleep 0.2
    [ "$i" = 40 ] && { warn "进程没有及时退出，强制结束"; # shellcheck disable=SC2046
      kill -9 $(find_pids) 2>/dev/null || true; }
  done
  if [ -z "$(find_pids)" ]; then info "已全部停止"; else warn "仍有进程在运行：$(find_pids | tr '\n' ' ')"; fi
}

# ---------------------------------------------------------------- 程序文件
bin_version() { # 输出版本号；不支持 --version 的旧版输出 sha256 前 12 位
  local v
  v=$(timeout 5 "$1" --version 2>/dev/null | head -1)
  if [ -n "$v" ]; then echo "$v"; else echo "未知版本（不支持 --version，sha256 $(sha256sum "$1" | cut -c1-12)）"; fi
}
# 解析新程序来源：参数（程序或 .tar.gz）→ 脚本旁边的 syncnotes-server
resolve_new_bin() { # 结果放到 NEW_BIN
  local src=${1-} t
  NEW_BIN=""
  if [ -z "$src" ]; then
    for t in "$SCRIPT_DIR/$BIN_NAME" "$PWD/$BIN_NAME"; do [ -f "$t" ] && { src=$t; break; }; done
  fi
  [ -n "$src" ] || return 1
  [ -e "$src" ] || die "找不到 $src"
  case "$src" in
    *.tar.gz|*.tgz)
      t=$(mktemp -d); TMP_DIRS+=("$t")
      tar -xzf "$src" -C "$t" || die "解压 $src 失败"
      NEW_BIN=$(find "$t" -type f -name "$BIN_NAME" | head -1)
      [ -n "$NEW_BIN" ] || die "压缩包中没有 $BIN_NAME" ;;
    *) NEW_BIN=$(cd "$(dirname "$src")" && pwd)/$(basename "$src") ;;
  esac
  chmod +x "$NEW_BIN" 2>/dev/null || true
  if ! timeout 5 "$NEW_BIN" --help >/dev/null 2>&1; then
    die "$NEW_BIN 无法运行（文件损坏或 CPU 架构不对？本机是 $(uname -m)）"
  fi
}
# 原子替换：复制为 .new 再 mv；旧程序保留为 .old 以便回滚
install_bin() {
  local new=$1
  mkdir -p "$CFG_DIR"
  if [ -f "$BIN" ] && cmp -s "$new" "$BIN"; then info "程序没有变化（$(bin_version "$BIN")）"; return 0; fi
  if [ -f "$BIN" ]; then
    info "旧版本：$(bin_version "$BIN")"
    cp -f "$BIN" "$BIN.old"
  fi
  info "新版本：$(bin_version "$new")"
  if ! { cp -f "$new" "$BIN.new" && chmod 755 "$BIN.new" && mv -f "$BIN.new" "$BIN"; }; then die "替换程序失败"; fi
  info "程序已安装到 $BIN"
}
ensure_bin() { # 未安装时安装脚本旁边的程序
  [ -x "$BIN" ] && return 0
  resolve_new_bin "${1-}" || die "没有找到 $BIN_NAME。请把它和本脚本放在同一目录，或在命令后面写上程序 / .tar.gz 的路径"
  install_bin "$NEW_BIN"
}

# ---------------------------------------------------------------- 数据
backup_db() {
  [ -f "$1" ] || return 0
  local ts dst
  ts=$(date +%Y%m%d-%H%M%S)
  dst="$1.bak-$ts"
  if command -v sqlite3 >/dev/null 2>&1; then sqlite3 "$1" ".backup '$dst'" 2>/dev/null || cp -a "$1" "$dst"; else
    cp -a "$1" "$dst"; [ -f "$1-wal" ] && cp -a "$1-wal" "$dst-wal"
  fi
  info "已备份数据库：$dst"
  # 只保留最近 5 份备份
  local old
  local n=0
  while IFS= read -r old; do
    case "$old" in *-wal) continue ;; esac
    n=$((n + 1)); [ "$n" -gt 5 ] && rm -f "$old" "$old-wal"
  done < <(find "$(dirname "$1")" -maxdepth 1 -name "$(basename "$1").bak-*" -printf '%T@ %p\n' 2>/dev/null | sort -rn | cut -d' ' -f2-)
}
# 把旧的临时目录中的数据迁移到安装目录（只在新位置还没有数据库时）
migrate_old_data() {
  local e odb ofiles
  for e in "${OLD_DATA[@]+"${OLD_DATA[@]}"}"; do
    odb=${e%%|*}; ofiles=${e#*|}
    [ -f "$odb" ] || continue
    [ "$(readlink -f "$odb")" = "$(readlink -f "$CFG_DB" 2>/dev/null || echo "$CFG_DB")" ] && continue
    backup_db "$odb"
    if [ -f "$CFG_DB" ]; then
      warn "新位置 $CFG_DB 已有数据库，不会覆盖；旧数据库仍在 $odb"
      continue
    fi
    if ask_yn "把旧数据 $odb（及文件目录 $ofiles）迁移到 $CFG_DB ？" y; then
      mkdir -p "$(dirname "$CFG_DB")" "$CFG_FILES"
      cp -a "$odb" "$CFG_DB"
      [ -f "$odb-wal" ] && cp -a "$odb-wal" "$CFG_DB-wal"
      [ -f "$odb-shm" ] && cp -a "$odb-shm" "$CFG_DB-shm"
      if [ -d "$ofiles" ]; then cp -a "$ofiles/." "$CFG_FILES/"; fi
      info "已迁移（旧数据保留在原处，确认无误后可自行删除）"
    fi
  done
}
ensure_user() {
  id "$SVC_USER" >/dev/null 2>&1 && return 0
  if command -v useradd >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir "$CFG_DIR" --shell /usr/sbin/nologin "$SVC_USER" 2>/dev/null || useradd -r -M -s /sbin/nologin "$SVC_USER"
  elif command -v adduser >/dev/null 2>&1; then
    adduser -S -D -H -h "$CFG_DIR" -s /sbin/nologin "$SVC_USER" 2>/dev/null || adduser --system --no-create-home "$SVC_USER"
  fi
  id "$SVC_USER" >/dev/null 2>&1 || { warn "无法创建用户 $SVC_USER，将以 root 运行"; SVC_USER=root; }
}
prepare_dirs() {
  ensure_user
  mkdir -p "$CFG_DIR" "$(dirname "$CFG_DB")" "$CFG_FILES"
  touch "$LOGFILE"
  chown "$SVC_USER" "$LOGFILE" "$(dirname "$CFG_DB")" 2>/dev/null || true
  chown -R "$SVC_USER" "$CFG_FILES" 2>/dev/null || true
  local f; for f in "$CFG_DB" "$CFG_DB-wal" "$CFG_DB-shm"; do [ -e "$f" ] && chown "$SVC_USER" "$f"; done
  return 0
}

# ---------------------------------------------------------------- 参数向导
configure() {
  load_config
  [ "$ASSUME_YES" = 1 ] || title "设置参数（直接回车使用默认值）"
  local v owner
  while true; do
    ask v "监听端口" "$CFG_PORT"
    if ! [[ "$v" =~ ^[0-9]+$ ]] || [ "$v" -lt 1 ] || [ "$v" -gt 65535 ]; then err "端口必须是 1–65535 的数字"; [ "$ASSUME_YES" = 1 ] && exit 1; continue; fi
    if owner=$(port_owner "$v"); then
      local opid; opid=$(grep -o 'pid=[0-9]*' <<<"$owner" | head -1 | cut -d= -f2)
      if { [ -n "$opid" ] && grep -qx "$opid" <<<"$(find_pids)"; } || { [ -z "$opid" ] && [ -n "$(find_pids)" ]; }; then
        info "端口 $v 正被旧的 SyncNotes 实例占用，稍后会先停止它"
      else
        err "端口 $v 已被占用："; printf '%s\n' "$owner" >&2
        [ "$ASSUME_YES" = 1 ] && exit 1
        ask_yn "仍然使用这个端口？" n || continue
      fi
    fi
    CFG_PORT=$v; break
  done
  while true; do
    ask v "监听地址（0.0.0.0 = 所有网卡，127.0.0.1 = 仅本机 / 反向代理）" "$CFG_ADDR"
    if [[ "$v" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || [[ "$v" =~ ^[0-9a-fA-F:]+$ ]]; then CFG_ADDR=$v; break; fi
    err "地址格式不正确（例如 0.0.0.0、127.0.0.1 或 ::）"; [ "$ASSUME_YES" = 1 ] && exit 1
  done
  local old_dir=$CFG_DIR
  while true; do
    ask v "安装目录" "$CFG_DIR"
    case "$v" in /*) safe_value "$v" && { CFG_DIR=${v%/}; break; } ;; esac
    err "请输入绝对路径，只能包含字母、数字和 . _ - /"; [ "$ASSUME_YES" = 1 ] && exit 1
  done
  if [ "$CFG_DIR" != "$old_dir" ]; then
    [ "$CFG_DB" = "$old_dir/data/syncnotes.db" ] && CFG_DB="$CFG_DIR/data/syncnotes.db"
    [ "$CFG_FILES" = "$old_dir/data/syncnotes-files" ] && CFG_FILES="$CFG_DIR/data/syncnotes-files"
  fi
  while true; do ask v "数据库文件" "$CFG_DB"; case "$v" in /*) safe_value "$v" && { CFG_DB=$v; break; } ;; esac; err "请输入绝对路径"; [ "$ASSUME_YES" = 1 ] && exit 1; done
  while true; do ask v "上传文件目录" "$CFG_FILES"; case "$v" in /*) safe_value "$v" && { CFG_FILES=${v%/}; break; } ;; esac; err "请输入绝对路径"; [ "$ASSUME_YES" = 1 ] && exit 1; done
  [ "$ASSUME_YES" = 1 ] || echo "提示：创建好自己的账号后，建议关闭注册，防止陌生人注册（再次运行本脚本即可修改）"
  if ask_yn "允许新用户注册？" "$([ "$CFG_REGISTER" = true ] && echo y || echo n)"; then CFG_REGISTER=true; else CFG_REGISTER=false; fi
  if ask_yn "开启局域网自动发现（mDNS）？" "$([ "$CFG_MDNS" = true ] && echo y || echo n)"; then
    CFG_MDNS=true
    while true; do ask v "局域网显示名称" "$CFG_MDNS_NAME"; [ -n "$v" ] && safe_value "$v" && { CFG_MDNS_NAME=$v; break; }; err "名称只能包含字母、数字、空格和 . _ -"; [ "$ASSUME_YES" = 1 ] && exit 1; done
  else CFG_MDNS=false; fi
  derive_paths
  title "确认配置"
  printf '  监听：%s\n  安装目录：%s\n  数据库：%s\n  文件目录：%s\n  允许注册：%s\n  mDNS：%s（%s）\n' \
    "$(bind_value)" "$CFG_DIR" "$CFG_DB" "$CFG_FILES" "$CFG_REGISTER" "$CFG_MDNS" "$CFG_MDNS_NAME"
  ask_yn "确认以上配置？" y || die "已取消"
  save_config
}

# ---------------------------------------------------------------- 防火墙
# 原则：绝不自动修改防火墙。先只读检测；只有防火墙处于启用状态时才询问（默认不修改）；
# 不会启用防火墙、不会安装防火墙、不会改默认策略。脚本自己添加的规则记录在 FW_RECORD，卸载时询问后才删除。
FW_RECORD="$ENV_DIR/firewall-rules"
fw_detect() { # 输出：ufw | firewalld | nftables | iptables | none（只读）
  if command -v ufw >/dev/null 2>&1 && grep -qi "Status: active" <<<"$(ufw status 2>/dev/null)"; then echo ufw; return; fi
  if command -v firewall-cmd >/dev/null 2>&1; then
    if { command -v systemctl >/dev/null 2>&1 && [ "$(systemctl is-active firewalld 2>/dev/null)" = active ]; } \
      || [ "$(firewall-cmd --state 2>/dev/null)" = running ]; then echo firewalld; return; fi
  fi
  if command -v nft >/dev/null 2>&1; then
    local rs; rs=$(nft list ruleset 2>/dev/null)
    if grep -q "hook input" <<<"$rs" && grep -Eq "policy drop|[[:space:]](drop|reject)([[:space:]]|$)" <<<"$rs"; then echo nftables; return; fi
  fi
  if command -v iptables >/dev/null 2>&1; then
    local rl; rl=$(iptables -S INPUT 2>/dev/null)
    if grep -Eq "^-P INPUT (DROP|REJECT)|-j (DROP|REJECT)" <<<"$rl"; then echo iptables; return; fi
  fi
  echo none
}
fw_port_allowed() { # 只读检查端口是否已放行
  case "$1" in
    ufw) grep -Eq "^$CFG_PORT(/tcp)?[[:space:]].*ALLOW" <<<"$(ufw status 2>/dev/null)" ;;
    firewalld) [ "$(firewall-cmd --query-port="$CFG_PORT/tcp" 2>/dev/null)" = yes ] ;;
    *) return 1 ;;
  esac
}
cloud_reminder() {
  [ "$CFG_ADDR" = 127.0.0.1 ] && return 0
  warn "如果是云服务器（阿里云、腾讯云、AWS 等），还需要在控制台的「安全组 / 防火墙」中放行 TCP $CFG_PORT"
}
firewall_step() {
  local fw c=""
  fw=$(fw_detect)
  title "防火墙"
  case "$fw" in
    none)
      info "本机防火墙未启用（或未安装），不做任何修改"
      cloud_reminder; return 0 ;;
    nftables|iptables)
      info "检测到 $fw 规则正在生效。脚本不会修改 $fw 规则；如需放行，请手动添加 TCP $CFG_PORT 的放行规则"
      cloud_reminder; return 0 ;;
  esac
  info "检测到防火墙 $fw 已启用"
  if fw_port_allowed "$fw"; then info "端口 $CFG_PORT/tcp 已经放行，无需修改"; cloud_reminder; return 0; fi
  if [ "$OPEN_FW" = 1 ]; then c=2
  elif [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then
    info "非交互模式：不修改防火墙（如需放行请加 --open-firewall）"; c=1
  else
    echo "  [1] 不修改"
    echo "  [2] 放行端口 $CFG_PORT/tcp"
    read -r -p "请选择 [默认: 1]: " c || c=1
  fi
  if [ "${c:-1}" = 2 ]; then
    case "$fw" in
      ufw) ufw allow "$CFG_PORT/tcp" ;;
      firewalld) firewall-cmd --permanent --add-port="$CFG_PORT/tcp" && firewall-cmd --reload ;;
    esac && {
      mkdir -p "$ENV_DIR"; echo "$fw $CFG_PORT/tcp" >> "$FW_RECORD"
      info "已在 $fw 中放行 $CFG_PORT/tcp（记录在 $FW_RECORD，卸载时可以删除）"; }
  else
    info "未修改防火墙；如果客户端连不上，请手动放行 TCP $CFG_PORT"
  fi
  cloud_reminder
}
firewall_cleanup() { # 只删除脚本自己添加的规则，删除前询问（默认不删）
  [ -s "$FW_RECORD" ] || return 0
  local fw rule left=()
  while read -r fw rule <&3; do
    [ -n "$fw" ] || continue
    if ask_yn "删除本脚本之前在 $fw 中添加的放行规则 $rule ？" n; then
      local ok=0
      case "$fw" in
        ufw) ufw delete allow "$rule" && ok=1 ;;
        firewalld) firewall-cmd --permanent --remove-port="$rule" && firewall-cmd --reload && ok=1 ;;
      esac
      if [ "$ok" = 1 ]; then info "已删除 $fw 规则 $rule"; else warn "删除 $fw 规则 $rule 失败"; left+=("$fw $rule"); fi
    else left+=("$fw $rule"); fi
  done 3< "$FW_RECORD"
  if [ "${#left[@]}" -gt 0 ]; then printf '%s\n' "${left[@]}" > "$FW_RECORD"; else rm -f "$FW_RECORD"; fi
}

# ---------------------------------------------------------------- 运行
load_env_exports() { set -a; # shellcheck disable=SC1090
  . "$ENV_FILE"; set +a; }
as_user() { # 以服务用户执行
  if [ "$SVC_USER" = root ] || [ "$(id -u)" -ne 0 ]; then "$@"
  elif command -v setpriv >/dev/null 2>&1; then setpriv --reuid="$SVC_USER" --regid="$(id -g "$SVC_USER")" --init-groups -- "$@"
  elif command -v su-exec >/dev/null 2>&1; then su-exec "$SVC_USER" "$@"
  elif command -v runuser >/dev/null 2>&1; then runuser -u "$SVC_USER" -- "$@"
  else "$@"; fi
}
verify_running() { # 等待端口监听、进程存活
  local i
  for i in $(seq 1 30); do
    if [ -n "$(find_pids)" ] && port_listening "$CFG_PORT"; then info "运行正常：$(bind_value) 正在监听"; return 0; fi
    sleep 0.5
  done
  return 1
}
start_bg() {
  [ -n "$(find_pids)" ] && { warn "已有实例在运行，先停止"; stop_all; }
  prepare_dirs
  load_env_exports
  # 整个子 shell 都重定向，避免占住调用者的终端 / 管道
  ( cd "$CFG_DIR" && exec setsid nohup bash -c "$(declare -f as_user); SVC_USER=$SVC_USER; as_user \"\$0\"" "$BIN" ) >>"$LOGFILE" 2>&1 < /dev/null &
  sleep 1
  local pid; pid=$(find_pids | head -1)
  [ -n "$pid" ] && echo "$pid" > "$PIDFILE"
  if verify_running; then info "已在后台运行（PID $pid），日志：$LOGFILE"; return 0; fi
  err "启动失败，最近的日志："; tail -n 20 "$LOGFILE" >&2; return 1
}
write_unit() {
  mkdir -p "$UNIT_DIR"
  cat > "$UNIT_FILE.tmp" <<UNIT
# 由 syncnotes-server.sh 生成；配置在 $ENV_FILE
[Unit]
Description=SyncNotes 实时同步服务器
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$SVC_USER
WorkingDirectory=$CFG_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$BIN
Restart=always
RestartSec=3
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
UNIT
  mv -f "$UNIT_FILE.tmp" "$UNIT_FILE"
  info "已写入 $UNIT_FILE"
}
remove_other_units() { # 删除旧名字 / 旧位置的单元，避免两个服务抢端口
  local u n
  while IFS= read -r u; do
    if [ -z "$u" ] || [ "$u" = "$UNIT_FILE" ]; then continue; fi
    n=$(basename "$u")
    info "禁用并移除旧服务 $n（$u）"
    systemctl disable "$n" >/dev/null 2>&1 || true
    rm -f "$u"
  done < <(find_units)
}
start_service() {
  prepare_dirs
  write_unit
  remove_other_units
  systemctl daemon-reload
  systemctl enable "$UNIT_NAME" >/dev/null 2>&1 || warn "systemctl enable 失败"
  systemctl restart "$UNIT_NAME"
  verify_running
}

# ---------------------------------------------------------------- 命令
cmd_run() {
  load_config; [ -f "$ENV_FILE" ] || configure
  ensure_bin "${1-}"
  [ -n "$(find_pids)" ] && { warn "已有实例在运行，先停止它"; stop_all; }
  prepare_dirs; load_env_exports
  info "临时运行中：$(bind_value)，按 Ctrl+C 停止"
  cd "$CFG_DIR" && as_user "$BIN"
}
cmd_start() {
  load_config; [ -f "$ENV_FILE" ] || configure
  ensure_bin "${1-}"
  if has_systemd && [ -f "$UNIT_FILE" ] && systemctl is-active --quiet "$UNIT_NAME"; then
    info "系统服务已在运行；如需改为后台运行，请先执行 disable"; return 0
  fi
  local pid
  pid=$(cat "$PIDFILE" 2>/dev/null)
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && port_listening "$CFG_PORT"; then
    info "已经在后台运行（PID $pid）"; return 0
  fi
  start_bg
}
cmd_install() { # 安装 / 重新安装 / 升级为系统服务（可重复执行）
  local src=${1-}
  has_systemd || { explain_no_systemd; ask_yn "改为持久运行（后台）？" y || exit 1; }
  configure
  scan_old
  if ! resolve_new_bin "$src"; then
    [ -x "$BIN" ] || die "没有找到 $BIN_NAME。请把它和本脚本放在同一目录，或在命令后面写上程序 / .tar.gz 的路径"
    NEW_BIN=""
  fi
  # 把新程序复制到临时位置，避免它就在安装目录里时被覆盖
  if [ -n "$NEW_BIN" ] && [ "$NEW_BIN" = "$BIN" ]; then NEW_BIN=""; fi
  stop_all
  backup_db "$CFG_DB"
  migrate_old_data
  [ -n "$NEW_BIN" ] && install_bin "$NEW_BIN"
  local ok=0
  if has_systemd; then start_service && ok=1; else start_bg && ok=1; fi
  if [ "$ok" != 1 ]; then rollback; return 1; fi
  firewall_step
  print_summary
}
rollback() {
  err "新程序启动失败"
  if has_systemd; then journalctl -u "$UNIT_NAME" -n 20 --no-pager 2>/dev/null >&2 || true; else tail -n 20 "$LOGFILE" >&2; fi
  if [ -f "$BIN.old" ]; then
    warn "正在回滚到旧版本……"
    stop_all
    mv -f "$BIN.old" "$BIN"
    if has_systemd; then systemctl restart "$UNIT_NAME"; else start_bg >/dev/null; fi
    if verify_running; then warn "已回滚到旧版本（$(bin_version "$BIN")），服务已恢复"; else err "回滚后仍无法启动，请查看日志"; fi
  fi
  return 1
}
cmd_update() {
  load_config
  [ -x "$BIN" ] || [ -n "$(find_pids)" ] || [ -n "$(find_units)" ] || { warn "还没有安装，转为全新安装"; cmd_install "${1-}"; return; }
  resolve_new_bin "${1-}" || die "请指定新版程序或 .tar.gz 的路径，例如：$0 update ./syncnotes-server-v0.5.0-linux-x86_64.tar.gz"
  [ -f "$ENV_FILE" ] || configure
  scan_old
  local mode=bg
  if has_systemd && { [ -f "$UNIT_FILE" ] || [ -n "$(find_units)" ]; }; then mode=service; fi
  if [ -x "$BIN" ] && cmp -s "$NEW_BIN" "$BIN" && [ -n "$(find_pids)" ]; then info "已经是这个版本（$(bin_version "$BIN")），无需更新"; return 0; fi
  stop_all
  backup_db "$CFG_DB"
  migrate_old_data
  install_bin "$NEW_BIN"
  local ok=0
  if [ "$mode" = service ]; then start_service && ok=1; else start_bg && ok=1; fi
  [ "$ok" = 1 ] || { rollback; return 1; }
  rm -f "$BIN.old.keep"; info "更新完成（旧程序保留为 $BIN.old）"
}
cmd_enable() {
  has_systemd || { explain_no_systemd; return 1; }
  load_config; [ -f "$ENV_FILE" ] || configure
  ensure_bin "${1-}"
  stop_all
  if start_service; then info "已安装为系统服务并开机自启"; else rollback; fi
}
cmd_disable() {
  load_config
  if has_systemd; then
    local u n any=0
    while IFS= read -r u; do
      [ -n "$u" ] || continue; any=1; n=$(basename "$u")
      systemctl disable --now "$n" >/dev/null 2>&1 || true
      rm -f "$u"; info "已停止并删除 $n"
    done < <(find_units)
    systemctl daemon-reload 2>/dev/null || true
    [ "$any" = 1 ] || info "没有安装开机自启的服务"
  else explain_no_systemd; fi
  info "数据保留在 $CFG_DB 和 $CFG_FILES；需要时可以用「持久运行」或「临时运行」再次启动"
}
cmd_stop() { load_config; stop_all; }
cmd_status() {
  load_config
  title "状态"
  if [ -f "$ENV_FILE" ]; then
    printf '  配置文件：%s\n  监听：%s\n  程序：%s\n  数据库：%s\n  允许注册：%s\n' "$ENV_FILE" "$(bind_value)" "$BIN" "$CFG_DB" "$CFG_REGISTER"
    [ -x "$BIN" ] && printf '  版本：%s\n' "$(bin_version "$BIN")"
  else echo "  尚未安装（没有 $ENV_FILE）"; fi
  if has_systemd && [ -f "$UNIT_FILE" ]; then
    printf '  系统服务：%s，开机自启：%s\n' "$(systemctl is-active "$UNIT_NAME" 2>/dev/null)" "$(systemctl is-enabled "$UNIT_NAME" 2>/dev/null)"
  else echo "  系统服务：未安装"; fi
  local pid
  for pid in $(find_pids); do printf '  进程 PID %s：%s（工作目录 %s）\n' "$pid" "$(readlink "/proc/$pid/exe")" "$(readlink "/proc/$pid/cwd")"; done
  [ -z "$(find_pids)" ] && echo "  进程：未运行"
  if port_listening "$CFG_PORT"; then echo "  端口 $CFG_PORT：正在监听"; else echo "  端口 $CFG_PORT：未监听"; fi
}
cmd_logs() {
  load_config
  local follow=0; [ "${1-}" = -f ] && follow=1
  if has_systemd && [ -f "$UNIT_FILE" ]; then
    if [ "$follow" = 1 ]; then journalctl -u "$UNIT_NAME" -f; else journalctl -u "$UNIT_NAME" -n 100 --no-pager; fi
  elif [ -f "$LOGFILE" ]; then
    if [ "$follow" = 1 ]; then tail -f "$LOGFILE"; else tail -n 100 "$LOGFILE"; fi
  else info "还没有日志"; fi
}
cmd_uninstall() {
  load_config
  confirm_danger "将停止服务并删除程序和开机自启。" || die "已取消"
  stop_all
  if has_systemd; then cmd_disable >/dev/null; fi
  rm -f "$BIN" "$BIN.old" "$BIN.new" "$PIDFILE"
  firewall_cleanup
  if ask_yn "同时删除数据（数据库 $CFG_DB 和文件目录 $CFG_FILES）？此操作不可恢复" n; then
    backup_db "$CFG_DB" >/dev/null 2>&1 || true
    rm -rf "$CFG_FILES" "$CFG_DB" "$CFG_DB-wal" "$CFG_DB-shm" "$LOGFILE"
    rm -rf "$CFG_DIR"
    rm -f "$ENV_FILE"; rmdir "$ENV_DIR" 2>/dev/null || true
    info "已删除程序、数据和配置"
  else
    info "已卸载程序，数据保留在 $CFG_DB、$CFG_FILES，配置保留在 $ENV_FILE（重新安装时会自动使用）"
  fi
}
print_summary() {
  local ip; ip=$(hostname -I 2>/dev/null | awk '{print $1}')
  title "完成"
  echo "  客户端服务器地址填写：${ip:-服务器IP}:$CFG_PORT"
  echo "  查看状态：sudo $SCRIPT_PATH status"
  echo "  查看日志：sudo $SCRIPT_PATH logs -f"
  [ "$CFG_REGISTER" = true ] && echo "  创建好账号后建议关闭注册：再次运行 sudo $SCRIPT_PATH install，在「允许新用户注册」处选 n"
}

menu() {
  while true; do
    title "SyncNotes 服务器管理"
    cat <<MENU
  1) 临时运行（前台，Ctrl+C 停止）
  2) 持久运行（后台，关闭 SSH 也不停，不开机自启）
  3) 安装为系统服务并开机自启（也用于重新安装 / 修改配置）
  4) 删除开机自启
  5) 停止正在运行的服务
  6) 状态 / 日志
  7) 更新 / 替换为新版
  8) 卸载
  0) 退出
MENU
    local c=""; read -r -p "请选择 [0-8]: " c || exit 0
    case "$c" in
      1) cmd_run ;;
      2) cmd_start ;;
      3) cmd_install ;;
      4) cmd_disable ;;
      5) cmd_stop ;;
      6) cmd_status; ask_yn "查看最近日志？" y && cmd_logs ;;
      7) local p=""; read -r -p "新版程序或 .tar.gz 的路径（回车使用脚本旁边的 $BIN_NAME）: " p || true; cmd_update "$p" ;;
      8) cmd_uninstall ;;
      0|q) exit 0 ;;
      *) echo "无效选项" ;;
    esac
  done
}

main() {
  need_root "$@"
  local args=() a
  for a in "$@"; do case "$a" in -y|--yes) ASSUME_YES=1 ;; --open-firewall) OPEN_FW=1 ;; -h|--help) sed -n '2,21p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; exit 0 ;; *) args+=("$a") ;; esac; done
  set -- "${args[@]+"${args[@]}"}"
  local cmd=${1-menu}; shift || true
  case "$cmd" in
    menu) menu ;;
    run) cmd_run "$@" ;;
    start) cmd_start "$@" ;;
    stop) cmd_stop ;;
    install) cmd_install "$@" ;;
    enable) cmd_enable "$@" ;;
    disable) cmd_disable ;;
    status) cmd_status ;;
    logs) cmd_logs "$@" ;;
    update|upgrade) cmd_update "$@" ;;
    uninstall|remove) cmd_uninstall ;;
    *) err "未知命令：$cmd"; sed -n '2,21p' "$SCRIPT_PATH" | sed 's/^# \{0,1\}//'; exit 1 ;;
  esac
}
[ "${SYNCNOTES_SOURCE_ONLY:-0}" = 1 ] || main "$@"
