param([int]$TimeoutSeconds = 300)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\li\Desktop\deepseek玩游戏\taczpronehitbox-1.20.1-forge'
$copy = Join-Path $root 'test-instance\TACZ-先锋-0.7'
$jar = Get-ChildItem (Join-Path $root 'build\libs') -Filter 'taczpronehitbox-*.jar' | Sort-Object LastWriteTime -Descending | Select-Object -First 1 | ForEach-Object { $_.FullName }
if (-not $jar) { throw 'no taczpronehitbox jar in build/libs' }
$evidence = Join-Path $root 'evidence'
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
if (-not (Test-Path $copy)) { throw "copy instance missing: $copy" }
if (-not (Test-Path $jar)) { throw "jar missing: $jar" }

$ts = Get-Date -Format 'yyyyMMdd-HHmmss'
$backup = Join-Path $root "install-backup\copy-$ts"
New-Item -ItemType Directory -Force -Path $backup | Out-Null
$mods = Join-Path $copy 'mods'
Get-ChildItem $mods -Filter 'seamlesssprint*.jar' -ErrorAction SilentlyContinue | ForEach-Object {
    Move-Item -LiteralPath $_.FullName -Destination (Join-Path $backup $_.Name) -Force
    Write-Output ("moved old sprint mod: " + $_.Name)
}
Get-ChildItem $mods -Filter 'taczpronehitbox*.jar' -ErrorAction SilentlyContinue | ForEach-Object {
    Move-Item -LiteralPath $_.FullName -Destination (Join-Path $backup $_.Name) -Force
    Write-Output ("moved old hitbox mod: " + $_.Name)
}
$dest = Join-Path $mods (Split-Path -Leaf $jar)
Copy-Item -LiteralPath $jar -Destination $dest -Force
Write-Output ("installed into copy: " + $dest)

# Generate launch script from PCL's last launch command, redirecting gameDir/natives to the workspace copy.
$orig = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7'
$srcBat = 'D:\我的世界\先锋\PCL\LatestLaunch.bat'
$lines = Get-Content -LiteralPath $srcBat -Encoding UTF8
$lines = $lines | ForEach-Object { $_.Replace($orig, $copy) } | Where-Object { $_ -notmatch '^\s*pause\s*$' }
$bat = Join-Path $evidence 'launch_copy.bat'
[System.IO.File]::WriteAllLines($bat, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ("launch bat written: " + $bat)

$out = Join-Path $evidence 'launch-stdout.log'
$err = Join-Path $evidence 'launch-stderr.log'
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"' + $bat + '"') -WorkingDirectory $copy -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
Write-Output ("launcher pid=" + $p.Id)

$log = Join-Path $copy 'logs\latest.log'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$reached = $false
$reason = 'timeout'
$marker = ''
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if ($p.HasExited) { $reason = 'process-exited'; break }
    if (Test-Path $log) {
        $txt = Get-Content -LiteralPath $log -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($txt -match 'Sound engine started|OpenAL initialized|Loaded [0-9]+ recipes') {
            $reached = $true
            $reason = 'startup-marker'
            break
        }
    }
}
Start-Sleep -Seconds 15
& taskkill /T /F /PID $p.Id 2>$null | Out-Null
Start-Sleep -Seconds 2
Copy-Item -LiteralPath $log -Destination (Join-Path $evidence 'copy-latest.log') -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $copy 'logs\debug.log') -Destination (Join-Path $evidence 'copy-debug.log') -Force -ErrorAction SilentlyContinue
Write-Output ("RESULT reached=" + $reached + " reason=" + $reason)
if (Test-Path $log) {
    Write-Output '=== latest.log tail ==='
    Get-Content -LiteralPath $log -Encoding UTF8 -Tail 30
}