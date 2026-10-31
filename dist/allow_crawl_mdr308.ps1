#requires -Version 5.1
<#
.SYNOPSIS
  把指定枪械数据里的 can_crawl 改成 true，让 TaCZ 允许这把枪趴下。
.DESCRIPTION
  TaCZ 每把枪是否允许趴下由枪包 data/*/data/guns/<gun>_data.json 里的 "can_crawl" 决定
  （缺省是 true；显式 false 时按 C 直接不响应）。LRadD 包里 mdr_308 等枪被作者设成了 false。
  本脚本只改本地枪包文件，先备份；改完重启游戏生效（单人有效；联机需要服务端同样修改）。
.PARAMETER DataFile
  要修改的 *_data.json 路径。默认是 lradd 的 mdr_308_data.json。
.PARAMETER AllInPack
  指定枪包文件夹，把其中所有 *_data.json 里 "can_crawl": false 全部改成 true。
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File allow_crawl_mdr308.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File allow_crawl_mdr308.ps1 -AllInPack "D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\tacz\lradd_default_gun完成"
#>
[CmdletBinding()]
param(
    [string]$DataFile = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\tacz\lradd_default_gun完成\data\lradd\data\guns\mdr_308_data.json',
    [string]$AllInPack = ''
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path (Join-Path $projectDir 'install-backup') ('gun-crawl-fix-' + $stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

$targets = @()
if ($AllInPack -ne '') {
    if (-not (Test-Path -LiteralPath $AllInPack)) { throw "枪包目录不存在: $AllInPack" }
    $targets = Get-ChildItem -LiteralPath $AllInPack -Recurse -File -Filter '*_data.json' -ErrorAction SilentlyContinue
} else {
    if (-not (Test-Path -LiteralPath $DataFile)) { throw "枪械数据文件不存在: $DataFile" }
    $targets = @(Get-Item -LiteralPath $DataFile)
}

$changed = 0
$checked = 0
foreach ($file in $targets) {
    $text = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    if ($text -notmatch '"can_crawl"\s*:\s*false') { continue }
    $checked++
    $newText = [regex]::Replace($text, '"can_crawl"\s*:\s*false', '"can_crawl": true')
    if ($newText -eq $text) { continue }
    $bak = Join-Path $backupDir ($file.Name + '.bak')
    Copy-Item -LiteralPath $file.FullName -Destination $bak -Force
    [System.IO.File]::WriteAllText($file.FullName, $newText, (New-Object System.Text.UTF8Encoding($false)))
    $changed++
    Write-Output ("patched: " + $file.FullName)
}

Write-Output ''
if ($changed -eq 0) {
    Write-Output '没有找到 "can_crawl": false 需要修改（文件不存在/已是 true/字段缺失=默认允许）。'
} else {
    Write-Output ("DONE: " + $changed + " 个枪械数据已从 can_crawl=false 改成 true。")
    Write-Output ("备份目录: " + $backupDir)
    Write-Output '请重启游戏（TaCZ 枪包在启动时加载），然后手持该枪按 C；/pronehitbox status 可确认 isCanCrawl=true。'
    Write-Output '注意：这只是本地枪包；如果联机，服务器端也要改成 true，否则服务端会取消趴下。'
}
