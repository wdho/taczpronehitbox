#requires -Version 5.1
<#
.SYNOPSIS
  修复“开无限制帧率导致整屏不刷新/像卡死”的问题（只改 options.txt，先备份）。
.DESCRIPTION
  把 Minecraft options.txt 改成：
    enableVsync:true      （垂直同步开）
    maxFps:<Fps 参数>     （默认 144；注意 260 = 无限制，会跳过限帧器）
  原文件备份到项目 install-backup/fps-fix-<时间戳>/options.txt。
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File fix_fps_freeze.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File fix_fps_freeze.ps1 -Fps 165
#>
[CmdletBinding()]
param(
    [string]$VersionDir = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7',
    [int]$Fps = 144
)

$ErrorActionPreference = 'Stop'
$distDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $distDir
$options = Join-Path $VersionDir 'options.txt'

if (-not (Test-Path -LiteralPath $VersionDir)) { throw "实例目录不存在: $VersionDir" }
if (-not (Test-Path -LiteralPath $options)) { throw "options.txt 不存在: $options" }
if ($Fps -lt 10 -or $Fps -ge 260) {
    throw "Fps 必须在 10~259 之间（260 = 无限制，会导致本问题）。推荐 120/144/165。"
}

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path (Join-Path $projectDir 'install-backup') ('fps-fix-' + $stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $options -Destination (Join-Path $backupDir 'options.txt') -Force
Write-Output ("backup: " + (Join-Path $backupDir 'options.txt'))

$lines = [System.IO.File]::ReadAllLines($options)
$hasVsync = $false
$hasMaxFps = $false
$out = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
    if ($line -match '^enableVsync:') { $out.Add('enableVsync:true'); $hasVsync = $true; continue }
    if ($line -match '^maxFps:')     { $out.Add('maxFps:' + $Fps);    $hasMaxFps = $true; continue }
    $out.Add($line)
}
if (-not $hasVsync) { $out.Add('enableVsync:true') }
if (-not $hasMaxFps) { $out.Add('maxFps:' + $Fps) }
[System.IO.File]::WriteAllLines($options, $out, (New-Object System.Text.UTF8Encoding($false)))

Write-Output ''
Write-Output 'FPS FREEZE FIX DONE.'
Write-Output ("  enableVsync = true, maxFps = " + $Fps)
Write-Output '  说明：Minecraft 里“最大帧率 260”= 无限制，会跳过限帧器；请不要再选“无限制”，也不要关垂直同步。'
Write-Output ('  回滚：把 ' + (Join-Path $backupDir 'options.txt') + ' 复制回 ' + $options)
