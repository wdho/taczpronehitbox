param([int]$TimeoutSeconds = 300)
$ErrorActionPreference = 'Stop'
$root = 'C:\Users\li\Desktop\deepseek玩游戏\taczpronehitbox-1.20.1-forge'
$copy = Join-Path $root 'test-instance\TACZ-先锋-0.7'
$ev = Join-Path $root 'evidence\crawl-repro'
$saveSrc = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\saves\新的世界'
New-Item -ItemType Directory -Force -Path $ev | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $ev 'removed-mods') | Out-Null

# --- separated jar set: hitbox 1.2.0 + standalone sprint 1.0.1, no merged jar ---
$mods = Join-Path $copy 'mods'
Get-ChildItem $mods -Filter 'taczpronehitbox-*.jar' -ErrorAction SilentlyContinue | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination (Join-Path $ev ('removed-mods\' + $_.Name)) -Force; Write-Output ('moved out ' + $_.Name) }
Get-ChildItem $mods -Filter 'seamlesssprint-*.jar' -ErrorAction SilentlyContinue | ForEach-Object { Move-Item -LiteralPath $_.FullName -Destination (Join-Path $ev ('removed-mods\' + $_.Name)) -Force; Write-Output ('moved out ' + $_.Name) }
Copy-Item -LiteralPath (Join-Path $root 'build\libs\taczpronehitbox-1.20.1-1.2.0.jar') -Destination (Join-Path $mods 'taczpronehitbox-1.20.1-1.2.0.jar') -Force
Copy-Item -LiteralPath 'C:\Users\li\Desktop\deepseek玩游戏\seamlesssprint-1.20.1-forge\build\libs\seamlesssprint-1.20.1-1.0.1.jar' -Destination (Join-Path $mods 'seamlesssprint-1.20.1-1.0.1.jar') -Force
Write-Output 'installed separated jars'

# --- copy a test world (only if not present) ---
$saveDst = Join-Path $copy 'saves\新的世界'
if ((-not (Test-Path -LiteralPath $saveDst)) -and (Test-Path -LiteralPath $saveSrc)) {
    cmd /c robocopy "$saveSrc" "$saveDst" /E /MT:8 /NFL /NDL /NJH /NJS /R:1 /W:1 > $null 2>&1
    Write-Output ('world copied, robocopy exit=' + $LASTEXITCODE)
} else {
    Write-Output 'world already present or source missing'
}

# --- launch bat with quick play singleplayer ---
$orig = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7'
$srcBat = 'D:\我的世界\先锋\PCL\LatestLaunch.bat'
$lines = Get-Content -LiteralPath $srcBat -Encoding UTF8
$lines = $lines | ForEach-Object { $_.Replace($orig, $copy) } | Where-Object { $_ -notmatch '^\s*pause\s*$' }
$lines = $lines | ForEach-Object { $_ -replace '--launchTarget forgeclient', '--quickPlaySingleplayer "新的世界" --launchTarget forgeclient' }
$bat = Join-Path $ev 'launch_quickplay.bat'
[System.IO.File]::WriteAllLines($bat, $lines, (New-Object System.Text.UTF8Encoding($false)))
Write-Output ('bat: ' + $bat)

$out = Join-Path $ev 'launch-stdout.log'
$err = Join-Path $ev 'launch-stderr.log'
$started = Get-Date
$p = Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', ('"' + $bat + '"') -WorkingDirectory $copy -RedirectStandardOutput $out -RedirectStandardError $err -PassThru -NoNewWindow
Write-Output ('launcher pid=' + $p.Id)

# --- wait for world ready ---
$log = Join-Path $copy 'logs\latest.log'
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$ready = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if ($p.HasExited) { Write-Output 'launcher exited early'; break }
    if (Test-Path $log) {
        $txt = Get-Content -LiteralPath $log -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($txt -match 'Time elapsed:') { $ready = $true; break }
    }
}
Write-Output ('world ready=' + $ready)
if (-not $ready) {
    Copy-Item -LiteralPath $log -Destination (Join-Path $ev 'latest-notready.log') -Force -ErrorAction SilentlyContinue
    if (-not $p.HasExited) { & taskkill /T /F /PID $p.Id 2>$null | Out-Null }
    exit 2
}
Start-Sleep -Seconds 12

# --- locate java pid and focus ---
$java = Get-Process java -ErrorAction SilentlyContinue | Where-Object { $_.StartTime -gt $started } | Sort-Object StartTime -Descending | Select-Object -First 1
$javaPid = if ($java) { $java.Id } else { 0 }
Write-Output ('java pid=' + $javaPid)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$ws = New-Object -ComObject WScript.Shell
try { [void]$ws.AppActivate($javaPid) } catch { Write-Output ('AppActivate pid failed: ' + $_.Exception.Message) }
Start-Sleep -Seconds 1

function Capture([string]$name) {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $path = Join-Path $ev ($name + '.png')
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
    Write-Output ('captured ' + $path)
}

Start-Sleep -Seconds 2
Capture '01-world'
try { $ws.SendKeys('{F5}') } catch { Write-Output ('F5 send failed: ' + $_.Exception.Message) }
Start-Sleep -Seconds 2
Capture '02-third-person'
try { $ws.SendKeys('c') } catch { Write-Output ('c send failed: ' + $_.Exception.Message) }
Start-Sleep -Seconds 2
Capture '03-after-crawl-key'
try { $ws.SendKeys('{F2}') } catch {}
Start-Sleep -Seconds 1
try { $ws.SendKeys('c') } catch {}
Start-Sleep -Seconds 1
Capture '04-after-crawl-key-2'
try { $ws.SendKeys('{F2}') } catch {}

Start-Sleep -Seconds 2
try { $ws.SendKeys('%{F4}') } catch { Write-Output ('alt-f4 failed: ' + $_.Exception.Message) }
Start-Sleep -Seconds 6
if (-not $p.HasExited) { & taskkill /T /F /PID $p.Id 2>$null | Out-Null }
Start-Sleep -Seconds 2
# collect in-game F2 screenshots
$shots = Join-Path $copy 'screenshots'
if (Test-Path $shots) {
    Get-ChildItem $shots -Filter '*.png' | Sort-Object LastWriteTime -Descending | Select-Object -First 6 | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $ev ('f2-' + $_.Name)) -Force
    }
}
Copy-Item -LiteralPath $log -Destination (Join-Path $ev 'latest.log') -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $copy 'logs\debug.log') -Destination (Join-Path $ev 'debug.log') -Force -ErrorAction SilentlyContinue
Write-Output 'DONE'
