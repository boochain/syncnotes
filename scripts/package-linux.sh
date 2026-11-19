#!/usr/bin/env bash
# 把 flutter build linux --release 的输出打包成 dist/SyncNotes-linux-x64.tar.gz
# 与 .github/workflows/build.yml 的 App Linux 作业保持完全一致，校验启动器可执行权限与着色器资源。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "${1-}" = "--build" ]; then
  (cd app && flutter pub get && flutter build linux --release)
fi

BUNDLE="app/build/linux/x64/release/bundle"
if [ ! -f "$BUNDLE/syncnotes" ]; then
  echo "找不到 $BUNDLE/syncnotes，请先运行 flutter build linux --release（或传入 --build）" >&2
  exit 1
fi

chmod +x "$BUNDLE/syncnotes"
mkdir -p dist
tar -C app/build/linux/x64/release -czf dist/SyncNotes-linux-x64.tar.gz --transform 's/^bundle/SyncNotes/' bundle
tar -tvzf dist/SyncNotes-linux-x64.tar.gz | grep -E ' SyncNotes/syncnotes$' | grep -q '^-rwx' || {
  echo "launcher not executable" >&2
  exit 1
}
echo "已生成 dist/SyncNotes-linux-x64.tar.gz"
sha256sum dist/SyncNotes-linux-x64.tar.gz
