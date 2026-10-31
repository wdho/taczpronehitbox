#requires -Version 5.1
<#
.SYNOPSIS
  安装【分离版】两个模组到用户的 TACZ-先锋-0.7 实例：
    1) taczpronehitbox (趴下命中箱，客户端+服务端同一个 jar)
    2) seamlesssprint  (无缝疾跑/疾跑锁定，纯客户端独立 jar)
.DESCRIPTION
  会先把旧的 taczpronehitbox*.jar（包括之前合并版 1.1.0）、seamlesssprint*.jar、
  相关 config 备份到项目 install-backup/<时间戳>/，再安装 dist 里的两个新 jar。
  旧 seamlesssprint.properties 保留在原处（疾跑开关/按键状态继续沿用）。
  回滚：install_to_instance.ps1 -Rollback <备份目录>
#>
[CmdletBinding()]
param(
    [string]$VersionDir = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7',
    [string]$Rollback = ''
)

$ErrorActionPreference = 'Stop'
$distDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $distDir
$modsDir = Join-Path $VersionDir 'mods'
$configDir = Join-Path $VersionDir 'config'
if (-not (Test-Path -LiteralPath $VersionDir)) { throw "实例目录不存在: $VersionDir" }
if (-not (Test-Path -LiteralPath $modsDir)) { throw "mods 目录不存在: $modsDir" }

if ($Rollback -ne '') {
    $backup = $Rollback
    if (-not (Test-Path -LiteralPath $backup)) { throw "备份目录不存在: $backup" }
    Get-ChildItem -LiteralPath $backup -Filter 'taczpronehitbox-*.jar' -ErrorAction SilentlyContinue | ForEach-Object {
        $target = Join-Path $modsDir $_.Name
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Write-Output ("removed installed: " + $_.Name)
    }
    Get-ChildItem -LiteralPath $backup -Filter 'seamlesssprint-*.jar' -ErrorAction SilentlyContinue | ForEach-Object {
        $target = Join-Path $modsDir $_.Name
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
        Copy-Item -LiteralPath $_.FullName -Destination $target -Force
        Write-Output ("restored: " + $_.Name)
    }
    if (Test-Path -LiteralPath (Join-Path $backup 'taczpronehitbox-sprint.properties')) {
        Copy-Item -LiteralPath (Join-Path $backup 'taczpronehitbox-sprint.properties') -Destination (Join-Path $configDir 'taczpronehitbox-sprint.properties') -Force
    }
    Write-Output 'ROLLBACK DONE。请重启游戏。'
    exit 0
}

$hitboxJar = Get-ChildItem -LiteralPath $distDir -Filter 'taczpronehitbox-*.jar' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
$sprintJar = Get-ChildItem -LiteralPath $distDir -Filter 'seamlesssprint-*.jar' -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $hitboxJar -or -not (Test-Path -LiteralPath $hitboxJar)) { throw "dist 里找不到 taczpronehitbox-*.jar" }
if (-not $sprintJar -or -not (Test-Path -LiteralPath $sprintJar)) { throw "dist 里找不到 seamlesssprint-*.jar" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path (Join-Path $projectDir 'install-backup') $stamp
New-Item -ItemType Directory -Force -Path $backup | Out-Null
Get-ChildItem -LiteralPath $modsDir -Filter 'taczpronehitbox-*.jar' -ErrorAction SilentlyContinue | ForEach-Object {
    Move-Item -LiteralPath $_.FullName -Destination (Join-Path $backup $_.Name) -Force
    Write-Output ("backed up old mod: " + $_.Name)
}
Get-ChildItem -LiteralPath $modsDir -Filter 'seamlesssprint-*.jar' -ErrorAction SilentlyContinue | ForEach-Object {
    Move-Item -LiteralPath $_.FullName -Destination (Join-Path $backup $_.Name) -Force
    Write-Output ("backed up old mod: " + $_.Name)
}
foreach ($c in @('seamlesssprint.properties','taczpronehitbox-common.toml','taczpronehitbox-client.toml','taczpronehitbox-sprint.properties')) {
    $src = Join-Path $configDir $c
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $backup $c) -Force }
}
Get-ChildItem -LiteralPath $modsDir -Filter '*.jar' | Select-Object -ExpandProperty Name |
    Set-Content -LiteralPath (Join-Path $backup 'mods-before.txt') -Encoding UTF8
Write-Output ("backup dir: " + $backup)
Copy-Item -LiteralPath $hitboxJar -Destination (Join-Path $modsDir (Split-Path -Leaf $hitboxJar)) -Force
Write-Output ("installed: " + (Split-Path -Leaf $hitboxJar))
Copy-Item -LiteralPath $sprintJar -Destination (Join-Path $modsDir (Split-Path -Leaf $sprintJar)) -Force
Write-Output ("installed: " + (Split-Path -Leaf $sprintJar))
Write-Output ''
Write-Output 'INSTALL DONE（分离版）。'
Write-Output '  - 两个模组互相独立：taczpronehitbox（趴下命中箱，客户端+服务端）+ seamlesssprint（疾跑锁定，纯客户端）。'
Write-Output '  - 之前合并版 1.1.0 和旧 seamlesssprint 已移到备份目录，避免同一个 modId 重复/双 R 键。'
Write-Output '  - 疾跑开关/按键状态沿用 config/seamlesssprint.properties（默认键 I）。'
Write-Output '  - 进游戏后：F5 + F3+B 看趴下判定框；/pronehitbox status 可诊断趴下/枪械状态。'
Write-Output ('  - 回滚：powershell -NoProfile -ExecutionPolicy Bypass -File "' + (Join-Path $distDir 'install_to_instance.ps1') + '" -Rollback "' + $backup + '"')
