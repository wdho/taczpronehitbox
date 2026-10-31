#requires -Version 5.1
<#
.SYNOPSIS
    Dedicated-server smoke test for the TaCZ Prone Hitbox mod (ForgeGradle dev run).

.DESCRIPTION
    Prepares run-server/ (eula.txt, server.properties, mods/TaCZ jar), launches
    'cmd /c build-offline.bat runServer' in the background, waits for the server to
    finish starting, then stops it and scans run-server/logs/latest.log for:

      * the server reached "Done (...)" (normal startup)
      * the mod id taczpronehitbox was loaded (ForgeGradle dev classpath)
      * the mod's common config file was generated
      * no Mixin apply failure / no fatal startup exception

    Notes:
      * The mod itself is loaded from the ForgeGradle dev classpath (build.gradle
        'runs.server.mods' block), so only the TaCZ jar is copied into
        run-server/mods/ - copying our own jar there would register the mod twice.
      * A production TaCZ jar is used as-is. If the dev environment cannot load a
        production mod, or Mixin reports SRG/named mapping problems, the failure is
        recorded as an environment limitation (this is not a release validation).
      * This script is destructive ONLY inside run-server/ (its own test directory):
        it rewrites eula.txt / server.properties, rotates logs/latest.log and, with
        -CleanWorld, removes run-server/world* . It never touches .minecraft or src.

    Exit code: 0 = server started and no fatal/mixin error found, 1 otherwise.

.PARAMETER StartupTimeoutSec
    Maximum wait for "Done (" in the server log (default 300).

.PARAMETER Jar
    Mod jar to record/validate as the build artifact (not copied into mods/).
    Defaults to the newest non-sources jar in build/libs.

.PARAMETER TaczJar
    TaCZ jar copied into run-server/mods/. Defaults to
    libs/tacz-1.20.1-1.1.8-hotfix2.jar (falls back to libs/tacz*.jar).

.PARAMETER ServerPort
    Port written to run-server/server.properties (default 25575, avoids clashing with
    a normal 25565 server).

.PARAMETER CleanWorld
    Remove run-server/world, world_nether and world_the_end before starting.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\run_server_smoke.ps1
#>
[CmdletBinding()]
param(
    [int]$StartupTimeoutSec = 300,
    [string]$Jar = '',
    [string]$TaczJar = '',
    [int]$ServerPort = 25575,
    [switch]$CleanWorld
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:NewLine = [string][char]10
$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0
$script:SkipCount = 0
$script:Failures = New-Object System.Collections.ArrayList

function Join-Lines {
    param([string[]]$Lines)
    if ($null -eq $Lines) { return '' }
    return ([string]::Join($script:NewLine, $Lines))
}

function Add-Result {
    param([string]$Kind, [string]$CheckName, [string]$Detail = '')
    $line = '[' + $Kind + '] ' + $CheckName
    if ($Detail -ne '') { $line += ' -- ' + $Detail }
    switch ($Kind) {
        'PASS' { $script:PassCount++ }
        'FAIL' {
            $script:FailCount++
            $entry = $CheckName
            if ($Detail -ne '') { $entry += ' (' + $Detail + ')' }
            [void]$script:Failures.Add($entry)
        }
        'WARN' { $script:WarnCount++ }
        'SKIP' { $script:SkipCount++ }
    }
    Write-Host $line
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host ('=== ' + $Title + ' ===')
}

function Resolve-FirstExistingPath {
    param([string[]]$Candidates)
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        try {
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        } catch { }
    }
    return $null
}

function Read-TextSafe {
    param([string]$Path)
    if ([string]::IsNullOrEmpty($Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { return (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) } catch { return $null }
}

function Test-PathInsideProject {
    param([string]$Path, [string]$ProjectRoot)
    $full = [System.IO.Path]::GetFullPath($Path)
    $rootFull = [System.IO.Path]::GetFullPath($ProjectRoot).TrimEnd('\') + '\'
    return $full.StartsWith($rootFull, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-ProjectJavaProcesses {
    param([string]$ProjectRoot)
    $found = @()
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction Stop
    } catch {
        return $found
    }
    foreach ($proc in $procs) {
        $cmd = [string]$proc.CommandLine
        if ($cmd -eq '') { continue }
        if ($cmd -like ('*' + $ProjectRoot + '*') -and $cmd -like '*run-server*') {
            $found += $proc
        }
    }
    return $found
}

function Stop-ServerTree {
    param([int]$LauncherPid, [string]$ProjectRoot)
    if ($LauncherPid -gt 0) {
        try { & taskkill.exe /PID $LauncherPid /T /F 2>&1 | Out-Null } catch { }
    }
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        $left = @(Get-ProjectJavaProcesses -ProjectRoot $ProjectRoot)
        if ($left.Count -eq 0) { break }
        foreach ($proc in $left) {
            try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 500
    }
}

# ================================================================ main
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($projectRoot)) { $projectRoot = (Get-Location).Path }
$projectRoot = (Resolve-Path -LiteralPath $projectRoot).Path

Write-Host 'TaCZ Prone Hitbox - dedicated server smoke test'
Write-Host ('Project: ' + $projectRoot)

# ------------------------------------------------ resolve artifacts
$modJarPath = $Jar
if ([string]::IsNullOrWhiteSpace($modJarPath)) {
    $libsDir = Join-Path $projectRoot 'build\libs'
    if (Test-Path -LiteralPath $libsDir -PathType Container) {
        $cands = @(Get-ChildItem -LiteralPath $libsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '-(sources|javadoc)\.jar$' } |
            Sort-Object LastWriteTime -Descending)
        if ($cands.Count -gt 0) { $modJarPath = $cands[0].FullName }
    }
}

$taczJarPath = $TaczJar
if ([string]::IsNullOrWhiteSpace($taczJarPath)) {
    $preferred = Join-Path $projectRoot 'libs\tacz-1.20.1-1.1.8-hotfix2.jar'
    $taczJarPath = Resolve-FirstExistingPath -Candidates @($preferred)
    if ([string]::IsNullOrEmpty($taczJarPath)) {
        $libsDir = Join-Path $projectRoot 'libs'
        if (Test-Path -LiteralPath $libsDir -PathType Container) {
            $cands = @(Get-ChildItem -LiteralPath $libsDir -Filter 'tacz*.jar' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
            if ($cands.Count -gt 0) { $taczJarPath = $cands[0].FullName }
        }
    }
}

Write-Section 'Preconditions'
if ($modJarPath) {
    Add-Result 'INFO' 'mod.jar' $modJarPath
} else {
    Add-Result 'WARN' 'mod.jar' 'no built jar found (dev run loads classes from sourceSet); build first for a full smoke'
}
if ($taczJarPath) {
    Add-Result 'INFO' 'tacz.jar' $taczJarPath
} else {
    Add-Result 'FAIL' 'tacz.jar' 'TaCZ jar not found in libs\'
}
$buildBat = Join-Path $projectRoot 'build-offline.bat'
if (Test-Path -LiteralPath $buildBat -PathType Leaf) {
    Add-Result 'PASS' 'gradle.launcher' 'build-offline.bat'
} else {
    Add-Result 'FAIL' 'gradle.launcher' 'build-offline.bat not found'
}
if ($script:FailCount -gt 0) {
    Write-Section 'Summary'
    Write-Host ("PASS {0} | FAIL {1} | WARN {2} | SKIP {3}" -f $script:PassCount, $script:FailCount, $script:WarnCount, $script:SkipCount)
    Write-Host 'RESULT: FAILED (preconditions)'
    exit 1
}

# ------------------------------------------------ prepare run-server
Write-Section 'Prepare run-server'
$serverDir = Join-Path $projectRoot 'run-server'
$logsDir = Join-Path $serverDir 'logs'
$modsDir = Join-Path $serverDir 'mods'
foreach ($dir in @($serverDir, $logsDir, $modsDir)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
}
if (-not (Test-PathInsideProject -Path $serverDir -ProjectRoot $projectRoot)) {
    Add-Result 'FAIL' 'run-server.dir' 'refusing to work outside the project directory'
    exit 1
}

if ($CleanWorld) {
    foreach ($worldName in @('world', 'world_nether', 'world_the_end')) {
        $worldPath = Join-Path $serverDir $worldName
        if ((Test-Path -LiteralPath $worldPath -PathType Container) -and (Test-PathInsideProject -Path $worldPath -ProjectRoot $projectRoot)) {
            Remove-Item -LiteralPath $worldPath -Recurse -Force
            Add-Result 'INFO' 'world.cleaned' $worldName
        }
    }
}

$eulaPath = Join-Path $serverDir 'eula.txt'
Set-Content -LiteralPath $eulaPath -Value 'eula=true' -Encoding ASCII
Add-Result 'PASS' 'run-server.eula' 'eula.txt written'

$propertiesPath = Join-Path $serverDir 'server.properties'
$propertiesLines = @(
    'online-mode=false',
    ('server-port=' + $ServerPort),
    'level-name=smoketest',
    'max-tick-time=-1',
    'spawn-protection=0',
    'enable-status=false',
    'motd=taczpronehitbox smoke test',
    'gamemode=creative'
)
Set-Content -LiteralPath $propertiesPath -Value $propertiesLines -Encoding ASCII
Add-Result 'PASS' 'run-server.properties' ('server-port=' + $ServerPort + ', level-name=smoketest')

$taczTarget = Join-Path $modsDir (Split-Path -Leaf $taczJarPath)
Copy-Item -LiteralPath $taczJarPath -Destination $taczTarget -Force
Add-Result 'PASS' 'run-server.mods.tacz' (Split-Path -Leaf $taczJarPath)

$latestLog = Join-Path $logsDir 'latest.log'
if (Test-Path -LiteralPath $latestLog -PathType Leaf) {
    $previousLog = Join-Path $logsDir 'latest.previous.log'
    Move-Item -LiteralPath $latestLog -Destination $previousLog -Force
    Add-Result 'INFO' 'log.rotated' (Split-Path -Leaf $previousLog)
}

$gradleOut = Join-Path $serverDir 'smoke-gradle-stdout.log'
$gradleErr = Join-Path $serverDir 'smoke-gradle-stderr.log'
if (Test-Path -LiteralPath $gradleOut) { Remove-Item -LiteralPath $gradleOut -Force }
if (Test-Path -LiteralPath $gradleErr) { Remove-Item -LiteralPath $gradleErr -Force }

# ------------------------------------------------ launch
Write-Section 'Launch runServer'
$startArgs = @{
    FilePath = 'cmd.exe'
    ArgumentList = @('/c', 'build-offline.bat', 'runServer')
    WorkingDirectory = $projectRoot
    RedirectStandardOutput = $gradleOut
    RedirectStandardError = $gradleErr
    WindowStyle = 'Hidden'
    PassThru = $true
}
$launcher = Start-Process @startArgs
Add-Result 'PASS' 'runServer.launched' ('pid ' + $launcher.Id + '; log ' + (Split-Path -Leaf $latestLog))

$fatalPattern = 'Failed to start the minecraft server|Exception in thread "main"|A fatal error has been detected|Could not find or load main class|BUILD FAILED|FAILURE: Build failed'
$started = $false
$fatal = $null
$exited = $false
$deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
Write-Host ('Waiting up to ' + $StartupTimeoutSec + 's for "Done (" ...')
while ($true) {
    if ($launcher.HasExited) { $exited = $true; break }
    Start-Sleep -Seconds 2
    $text = Read-TextSafe -Path $latestLog
    if ($text) {
        if ($text -match 'Done \(') { $started = $true; break }
        if ($text -match $fatalPattern) { $fatal = 'fatal startup message in latest.log'; break }
    }
    $gradleText = Read-TextSafe -Path $gradleOut
    if ($gradleText -and $gradleText -match $fatalPattern) { $fatal = 'fatal message in gradle output'; break }
    if ((Get-Date) -gt $deadline) { break }
}
if ($started) {
    Add-Result 'PASS' 'server.started' 'Done ( seen in latest.log'
    Start-Sleep -Seconds 3
} elseif ($fatal) {
    Add-Result 'FAIL' 'server.started' $fatal
} elseif ($exited) {
    Add-Result 'FAIL' 'server.started' ('launcher exited before startup; see ' + (Split-Path -Leaf $gradleOut))
} else {
    Add-Result 'FAIL' 'server.started' ('timeout after ' + $StartupTimeoutSec + 's')
}

# ------------------------------------------------ stop server
Write-Section 'Stop server'
Stop-ServerTree -LauncherPid $launcher.Id -ProjectRoot $projectRoot
$left = @(Get-ProjectJavaProcesses -ProjectRoot $projectRoot)
if ($left.Count -eq 0) {
    Add-Result 'PASS' 'server.stopped' 'no project java process left'
} else {
    Add-Result 'FAIL' 'server.stopped' ($left.Count.ToString() + ' project java process(es) still running')
}

# ------------------------------------------------ scan logs
Write-Section 'Log checks'
$serverText = Read-TextSafe -Path $latestLog
$gradleText = Read-TextSafe -Path $gradleOut
$combined = Join-Lines -Lines @([string]$serverText, [string]$gradleText)

if ($null -eq $serverText) {
    Add-Result 'FAIL' 'server.log' 'run-server/logs/latest.log was not created'
} else {
    Add-Result 'PASS' 'server.log' ('latest.log ' + (Get-Item -LiteralPath $latestLog).Length.ToString() + ' bytes')
}

if ($combined -match 'taczpronehitbox') {
    Add-Result 'PASS' 'mod.loaded' 'taczpronehitbox mentioned in server/gradle log'
} else {
    Add-Result 'FAIL' 'mod.loaded' 'taczpronehitbox not mentioned in server/gradle log'
}

$mixinErrorPattern = 'Mixin apply (for )?.*(failed|error)|MixinApplyError|MixinTransformerError|mixin.*failed to apply'
if ($combined -match $mixinErrorPattern) {
    $line = ([regex]::Match($combined, '(?im)^.*(Mixin apply (for )?.*(failed|error)|MixinApplyError|MixinTransformerError).*$')).Value
    Add-Result 'FAIL' 'mixin.apply.clean' ('mixin error: ' + $line.Trim())
} else {
    Add-Result 'PASS' 'mixin.apply.clean' 'no mixin apply failure in log'
}

if ($combined -match 'taczpronehitbox\.mixins\.json') {
    Add-Result 'PASS' 'mixin.config.loaded' 'mixin config name appears in log'
} else {
    Add-Result 'WARN' 'mixin.config.loaded' 'mixin config name not logged (normal: Mixin is quiet without debug flags)'
}

$configPath = Join-Path $serverDir 'config\taczpronehitbox-common.toml'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Add-Result 'PASS' 'config.generated' 'run-server/config/taczpronehitbox-common.toml'
} else {
    Add-Result 'FAIL' 'config.generated' 'run-server/config/taczpronehitbox-common.toml missing'
}

if ($combined -match $fatalPattern) {
    $line = ([regex]::Match($combined, '(?im)^.*(Failed to start the minecraft server|Exception in thread "main"|BUILD FAILED|FAILURE: Build failed).*$')).Value
    Add-Result 'FAIL' 'server.no.fatal' ('fatal: ' + $line.Trim())
} else {
    Add-Result 'PASS' 'server.no.fatal' 'no fatal startup failure in log'
}

if ($combined -match '(?i)\btacz\b') {
    Add-Result 'PASS' 'tacz.present' 'tacz mentioned in server/gradle log'
} else {
    Add-Result 'WARN' 'tacz.present' 'tacz not mentioned in log'
}

$errorLines = @([regex]::Matches($combined, '(?im)^.*\b(ERROR|FATAL)\b.*$') | ForEach-Object { $_.Value.Trim() } | Select-Object -First 12)
if ($errorLines.Count -gt 0) {
    Write-Host '[INFO] first ERROR/FATAL lines:'
    foreach ($line in $errorLines) { Write-Host ('       ' + $line) }
}

# ------------------------------------------------ summary
Write-Section 'Result'
Write-Host ('Server log:    ' + $latestLog)
Write-Host ('Gradle stdout: ' + $gradleOut)
Write-Host ("PASS {0} | FAIL {1} | WARN {2} | SKIP {3}" -f $script:PassCount, $script:FailCount, $script:WarnCount, $script:SkipCount)
if ($script:FailCount -gt 0) {
    foreach ($failure in $script:Failures) { Write-Host ('  FAILED: ' + $failure) }
    Write-Host 'RESULT: FAILED'
    exit 1
}
Write-Host 'RESULT: OK'
exit 0
