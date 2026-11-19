# SyncNotes 服务器一键管理与救援脚本（Windows PowerShell）
#
# 用法（在管理员或普通 PowerShell 中运行）：
#   powershell -ExecutionPolicy Bypass -File .\syncnotes-server.ps1 [命令] [参数]
#
# 子命令：
#   run              临时前台运行（Ctrl+C 停止）
#   start            后台持久运行（写入日志与 PID）
#   stop             停止正在运行的 syncnotes-server.exe
#   install          注册为 Windows 开机计划任务并后台启动
#   uninstall        移除开机计划任务并停止服务（数据默认保留）
#   status           查看运行状态、端口与数据目录
#   list-users       列出所有用户
#   reset-password   重置用户密码（如：reset-password bill）
#   export           导出用户全部数据为 zip（如：export bill .\bill.zip）
#   backup           在线备份 SQLite 数据库
param(
  [Parameter(Position = 0)]
  [string]$Command = "menu",
  [Parameter(Position = 1)]
  [string]$Arg1 = "",
  [Parameter(Position = 2)]
  [string]$Arg2 = ""
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BinPath = Join-Path $ScriptDir "syncnotes-server.exe"
$DataDir = if ($env:SYNCNOTES_DATA) { $env:SYNCNOTES_DATA } elseif ($env:ProgramData) { Join-Path $env:ProgramData "SyncNotes" } else { Join-Path $env:LOCALAPPDATA "SyncNotes" }
$DbPath = if ($env:SYNCNOTES_DB) { $env:SYNCNOTES_DB } else { Join-Path $DataDir "syncnotes.db" }
$FilesDir = if ($env:SYNCNOTES_FILES) { $env:SYNCNOTES_FILES } else { Join-Path $DataDir "syncnotes-files" }
$BindAddr = if ($env:SYNCNOTES_BIND) { $env:SYNCNOTES_BIND } else { "0.0.0.0:7700" }
$LogFile = Join-Path $DataDir "syncnotes-server.log"
$TaskName = "SyncNotesServer"

function Ensure-Bin {
  if (-not (Test-Path $BinPath)) {
    throw "未找到 $BinPath，请将本脚本与 syncnotes-server.exe 放在同一目录。"
  }
  New-Item -ItemType Directory -Force $DataDir | Out-Null
  New-Item -ItemType Directory -Force $FilesDir | Out-Null
}

function Stop-All {
  Get-Process -Name "syncnotes-server" -ErrorAction SilentlyContinue | Stop-Process -Force
  Write-Host "[信息] 已停止所有 syncnotes-server.exe 进程" -ForegroundColor Green
}

function Start-Bg {
  Ensure-Bin
  Stop-All
  $proc = Start-Process -FilePath $BinPath -ArgumentList @("--bind", $BindAddr, "--db", $DbPath, "--files-dir", $FilesDir) -WorkingDirectory $ScriptDir -WindowStyle Hidden -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err" -PassThru
  Start-Sleep -Seconds 1
  Write-Host "[信息] SyncNotes 服务器已在后台启动 (PID: $($proc.Id))，监听: $BindAddr" -ForegroundColor Green
  Write-Host "       数据目录: $DataDir"
}

function Show-Status {
  $procs = Get-Process -Name "syncnotes-server" -ErrorAction SilentlyContinue
  Write-Host "== SyncNotes Windows 服务器状态 ==" -ForegroundColor Cyan
  Write-Host "  程序路径: $BinPath"
  Write-Host "  监听地址: $BindAddr"
  Write-Host "  数据库:   $DbPath"
  Write-Host "  文件目录: $FilesDir"
  if ($procs) {
    Write-Host "  运行状态: 运行中 (PID: $(($procs | Select-Object -ExpandProperty Id) -join ', '))" -ForegroundColor Green
  } else {
    Write-Host "  运行状态: 未运行" -ForegroundColor Yellow
  }
}

switch ($Command) {
  "run" {
    Ensure-Bin
    Stop-All
    Write-Host "[信息] 前台运行 SyncNotes 服务器 ($BindAddr)，按 Ctrl+C 停止..." -ForegroundColor Green
    & $BinPath --bind $BindAddr --db $DbPath --files-dir $FilesDir
  }
  "start" { Start-Bg }
  "stop" { Stop-All }
  "status" { Show-Status }
  "install" {
    Ensure-Bin
    $action = New-ScheduledTaskAction -Execute $BinPath -Argument "--bind $BindAddr --db `"$DbPath`" --files-dir `"$FilesDir`"" -WorkingDirectory $ScriptDir
    $trigger = New-ScheduledTaskTrigger -AtStartup
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Description "SyncNotes Real-Time Sync Server" -Force | Out-Null
    Write-Host "[信息] 已注册 Windows 开机自启计划任务: $TaskName" -ForegroundColor Green
    Start-Bg
  }
  "uninstall" {
    Stop-All
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Host "[信息] 已移除计划任务 $TaskName；数据保留在 $DataDir" -ForegroundColor Green
  }
  "list-users" {
    Ensure-Bin
    & $BinPath admin list-users --db $DbPath --files-dir $FilesDir
  }
  "reset-password" {
    Ensure-Bin
    if (-not $Arg1) { $Arg1 = Read-Host "请输入要重置密码的用户名" }
    $pw = if ($Arg2) { $Arg2 } else { "syncnotes123456" }
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    & $BinPath admin backup "$DbPath.bak-$ts" --db $DbPath --files-dir $FilesDir
    & $BinPath admin reset-password $Arg1 --password $pw --db $DbPath --files-dir $FilesDir
  }
  "export" {
    Ensure-Bin
    if (-not $Arg1) { $Arg1 = Read-Host "请输入要导出的用户名" }
    $out = if ($Arg2) { $Arg2 } else { Join-Path (Get-Location) "syncnotes-export-$Arg1.zip" }
    & $BinPath admin export $Arg1 $out --db $DbPath --files-dir $FilesDir
  }
  "backup" {
    Ensure-Bin
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $out = if ($Arg1) { $Arg1 } else { "$DbPath.bak-$ts" }
    & $BinPath admin backup $out --db $DbPath --files-dir $FilesDir
  }
  default {
    Show-Status
    Write-Host ""
    Write-Host "可用命令: run | start | stop | status | install | uninstall | list-users | reset-password | export | backup"
  }
}
