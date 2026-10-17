# 把 flutter build windows --release 的输出打包成 SyncNotes-windows-x64.zip
# 目录结构与 CI（.github/workflows/build.yml 的 App Windows 作业）完全一致：
#   SyncNotes\syncnotes.exe、*.dll、data\（app.so、icudtl.dat、flutter_assets\ 含着色器）
#   以及 VC++ 运行库 msvcp140.dll / vcruntime140.dll / vcruntime140_1.dll
#
# 用法（在仓库根目录）：
#   powershell -ExecutionPolicy Bypass -File scripts\package-windows.ps1
#   可选参数：-Build    先运行 flutter pub get 和 flutter build windows --release
param(
  [switch]$Build
)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

if ($Build) {
  Push-Location app
  flutter pub get
  if ($LASTEXITCODE -ne 0) { throw "flutter pub get 失败" }
  flutter build windows --release
  if ($LASTEXITCODE -ne 0) { throw "flutter build windows 失败" }
  Pop-Location
}

$release = "app\build\windows\x64\runner\Release"
if (-not (Test-Path "$release\syncnotes.exe")) { throw "找不到 $release\syncnotes.exe，请先运行 flutter build windows --release（或加 -Build 参数）" }

# 清理上一次的结果
if (Test-Path SyncNotes) { Remove-Item -Recurse -Force SyncNotes }
New-Item -ItemType Directory -Force dist | Out-Null
if (Test-Path dist\SyncNotes-windows-x64.zip) { Remove-Item -Force dist\SyncNotes-windows-x64.zip }

Copy-Item -Recurse $release SyncNotes
# 附带 VC++ 运行库，干净的 Windows 上无需另装 VC++ Redistributable 也能启动
foreach ($dll in @("msvcp140.dll", "vcruntime140.dll", "vcruntime140_1.dll")) {
  $src = "$env:WINDIR\System32\$dll"
  if (-not (Test-Path $src)) { throw "系统中没有 $src，请先安装 Visual Studio 2022 或 VC++ Redistributable (x64)" }
  Copy-Item $src SyncNotes\
}
if (-not (Test-Path SyncNotes\syncnotes.exe)) { throw "syncnotes.exe missing" }
if (-not (Test-Path SyncNotes\data\app.so)) { throw "data\app.so missing" }
if (-not (Test-Path SyncNotes\data\flutter_assets)) { throw "data\flutter_assets missing" }
Compress-Archive -Path SyncNotes -DestinationPath dist\SyncNotes-windows-x64.zip
Get-ChildItem -Recurse SyncNotes | Select-Object -ExpandProperty FullName

$hash = (Get-FileHash -Algorithm SHA256 dist\SyncNotes-windows-x64.zip).Hash.ToLower()
Write-Host ""
Write-Host "已生成 dist\SyncNotes-windows-x64.zip"
Write-Host "SHA256: $hash"
