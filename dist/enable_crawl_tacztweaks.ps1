#requires -Version 5.1
<#
.SYNOPSIS
  启用/禁用 TaCZ Tweaks 的 crawl 功能（这是 TaCZ 趴下的总开关之一）。
.DESCRIPTION
  tacz-tweaks（muksc 的 TaCZ Tweaks）会用 @WrapWithCondition 包住 TaCZ 的
  LocalPlayerCrawl.crawl / tickCrawl（以及服务端 LivingEntityCrawl.crawl / tickCrawling），
  只有 config/tacztweaks.json 里 crawl.enabled = true 时才执行原方法。
  当它为 false 时，按 C 和直接调用 crawl() 都不会趴下（方法被整个跳过），
  表现为"连趴下都没法做到"，和命中箱模组无关。
  本脚本先备份再把它改成 true；改完重启游戏生效。
.PARAMETER ConfigFile
  tacztweaks.json 路径，默认当前 0.7 客户端。
.PARAMETER Disable
  改成 false（恢复禁用）。
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File enable_crawl_tacztweaks.ps1
#>
[CmdletBinding()]
param(
    [string]$ConfigFile = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\config\tacztweaks.json',
    [switch]$Disable
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
if (-not (Test-Path -LiteralPath $ConfigFile)) { throw "找不到配置文件: $ConfigFile" }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path (Join-Path $projectDir 'install-backup') ('tacztweaks-' + $stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Copy-Item -LiteralPath $ConfigFile -Destination (Join-Path $backupDir 'tacztweaks.json') -Force
Write-Output ("backup: " + (Join-Path $backupDir 'tacztweaks.json'))

$json = Get-Content -LiteralPath $ConfigFile -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $json.crawl) {
    $json | Add-Member -NotePropertyName 'crawl' -NotePropertyValue ([pscustomobject]@{ enabled = $true })
} else {
    $json.crawl.enabled = (-not $Disable.IsPresent)
}
$text = $json | ConvertTo-Json -Depth 50
[System.IO.File]::WriteAllText($ConfigFile, $text, (New-Object System.Text.UTF8Encoding($false)))

Write-Output ''
$state = if ($Disable.IsPresent) { 'false（禁用趴下）' } else { 'true（启用趴下）' }
Write-Output ("DONE: tacztweaks.json -> crawl.enabled = " + $state)
Write-Output '重启游戏后生效。手持 isCanCrawl=true 的枪（例如 nmw3:bal27）按 C，角色应该能趴下。'
Write-Output '如果仍不行：/pronehitbox status 看 isCanCrawl / EnableCrawl；/pronehitbox crawl 测试绕过按键。'
