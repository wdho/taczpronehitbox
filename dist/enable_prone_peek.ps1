#requires -Version 5.1
<#
  允许在趴下（Pose.SWIMMING）时使用 GD656Peek 的侧头按键 Q/E。
  GD656Peek 默认 disablePeekInSwimPose = true，趴下时按 Q/E 会被忽略；
  改成 false 后，趴下按 Q/E 摄像机会滚转 30°，画面/身体/我们的判定箱都会左右倾斜。
  默认不开启 betterPeekModelEnabled（避免 GD656 自己的站立侧头调试箱和趴下模型冲突）。
  需要身体模型也明显侧倾时，加参数 -BetterModel。
  改前自动备份到项目 install-backup/peek-crawl-<时间>/。
#>
[CmdletBinding()]
param(
    [string]$WorldConfig = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\saves\合并地图档\serverconfig\gd656peek-server.toml',
    [switch]$BetterModel
)
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$projectDir = Split-Path -Parent $scriptDir
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupDir = Join-Path (Join-Path $projectDir 'install-backup') ('peek-crawl-' + $stamp)
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

function Set-TomlKey([string]$path, [string]$key, [string]$value) {
    if (-not (Test-Path -LiteralPath $path)) { Write-Output ('missing: ' + $path); return }
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ($text -match ('(?m)^\s*' + [regex]::Escape($key) + '\s*=')) {
        $newText = [regex]::Replace($text, ('(?m)^\s*' + [regex]::Escape($key) + '\s*=.*$'), ($key + ' = ' + $value))
    } else {
        $newText = $text.TrimEnd() + "`r`n" + $key + ' = ' + $value + "`r`n"
    }
    [System.IO.File]::WriteAllText($path, $newText, (New-Object System.Text.UTF8Encoding($false)))
    Write-Output ('patched: ' + $path + ' -> ' + $key + ' = ' + $value)
}

foreach ($path in @($WorldConfig, 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\config\gd656peek-server.toml')) {
    if (Test-Path -LiteralPath $path) {
        $safe = ($path -replace '[:\\]', '_')
        Copy-Item -LiteralPath $path -Destination (Join-Path $backupDir ($safe + '.bak')) -Force -ErrorAction SilentlyContinue
    }
}

Set-TomlKey $WorldConfig 'disablePeekInSwimPose' 'false'
if ($BetterModel.IsPresent) { Set-TomlKey $WorldConfig 'betterPeekModelEnabled' 'true' }
try {
    $globalCfg = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\config\gd656peek-server.toml'
    if (Test-Path -LiteralPath $globalCfg) {
        Set-TomlKey $globalCfg 'disablePeekInSwimPose' 'false'
        if ($BetterModel.IsPresent) { Set-TomlKey $globalCfg 'betterPeekModelEnabled' 'true' }
    }
} catch {
    Write-Output ('warning: global config not patched (' + $_.Exception.Message + ') - 以当前存档的 serverconfig 为准。')
}

Write-Output ''
Write-Output ('备份目录: ' + $backupDir)
Write-Output '重启游戏后：1) 按当前趴下键（现在是 B）趴下；2) 按住 Q 或 E 侧头，摄像机/画面会左右滚转；3) F3+B 时我们的绿箱也会随画面倾斜。'
Write-Output '想要身体模型也侧倾：重新运行本脚本并加 -BetterModel。'
Write-Output '撤销：把备份目录里的 gd656peek-server.toml 覆盖回原路径并重启。'
