#!/usr/bin/env bash
# 把 flutter build apk --release 的输出打包成 dist/SyncNotes-android.apk
# 与 .github/workflows/build.yml 的 App Android 作业保持完全一致，校验 arm64 native 库与 v1/v2/v3 签名。
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "${1-}" = "--build" ]; then
  (cd app && flutter pub get && flutter build apk --release)
fi

APK="app/build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$APK" ]; then
  echo "找不到 $APK，请先运行 flutter build apk --release（或传入 --build）" >&2
  exit 1
fi

mkdir -p dist
cp "$APK" dist/SyncNotes-android.apk
unzip -l dist/SyncNotes-android.apk | grep -q 'lib/arm64-v8a/libapp.so' || {
  echo "APK missing arm64 code" >&2
  exit 1
}
unzip -l dist/SyncNotes-android.apk | grep -E 'META-INF/.*\.(SF|RSA|EC|DSA)$' >/dev/null || {
  echo "APK missing v1 signature" >&2
  exit 1
}
echo "已生成 dist/SyncNotes-android.apk"
sha256sum dist/SyncNotes-android.apk
