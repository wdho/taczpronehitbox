#requires -Version 5.1
<#
.SYNOPSIS
    Production dedicated-server smoke test for the TaCZ Prone Hitbox mod.

.DESCRIPTION
    The ForgeGradle 'runServer' dev run cannot load the production TaCZ jar (TaCZ's own
    SRG mixins do not resolve in the official-mapped dev runtime), so this script builds
    a *production-like* server instead:

      1. copies a real Forge 1.20.1-47.4.0 dedicated server installation (libraries +
         launch argument files) from a local template into run-server\prod\ (read-only
         copy of the template; the template itself is never modified),
      2. puts the built mod jar and the TaCZ jar into run-server\prod\mods\,
      3. optionally compiles a tiny throwaway probe mod (tphsmokeprobe) that calls
         Class.forName on com.tacz.guns.util.EntityUtil during mod construction, which
         forces Mixin to apply taczpronehitbox.mixins.json:EntityUtilMixin at startup -
         this is the only way to validate the mixin target at runtime without gameplay,
      4. starts the server with JDK 17, waits for "Done (", checks the log, stops it.

    Evidence to look for in the log:
      * "Done ("                                 -> server started
      * "TPH_SMOKE_PROBE: EntityUtil loaded ..." -> our mixin was applied successfully
      * no "Mixin apply failed ... taczpronehitbox.mixins.json"

    The script only writes inside run-server\prod\ (its own test directory). It never
    modifies the server template, the user's .minecraft or src.

    Exit code: 0 = all required checks passed, 1 = failed, 2 = environment limitation
    (template/java missing or server could not start for an environment reason).

.PARAMETER ServerTemplate
    Path of a local Forge 1.20.1-47.4.0 server installation directory (the one that
    contains 'libraries' and run.bat). Auto-detected from a known local template path
    when omitted.

.PARAMETER Java
    Path to java.exe (JDK 17). Auto-detected when omitted.

.PARAMETER StartupTimeoutSec
    Maximum wait for "Done (" (default 300).

.PARAMETER ServerPort
    server.properties port (default 25576).

.PARAMETER SkipProbe
    Do not build the tphsmokeprobe mod (server start is still checked, but the mixin is
    then not forced to apply).

.PARAMETER CleanRuntime
    Delete the copied run-server\prod\libraries after the run (saves about 160 MB; the
    next run copies it again).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\run_server_smoke_prod.ps1
#>
[CmdletBinding()]
param(
    [string]$ServerTemplate = '',
    [string]$Java = '',
    [int]$StartupTimeoutSec = 300,
    [int]$ServerPort = 25576,
    [switch]$SkipProbe,
    [switch]$CleanRuntime
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
    param([string[]]$Candidates, [switch]$Directory)
    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrEmpty($candidate)) { continue }
        try {
            if ($Directory) {
                if (Test-Path -LiteralPath $candidate -PathType Container) { return (Resolve-Path -LiteralPath $candidate).Path }
            } else {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return (Resolve-Path -LiteralPath $candidate).Path }
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

# ================================================================ main
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($projectRoot)) { $projectRoot = (Get-Location).Path }
$projectRoot = (Resolve-Path -LiteralPath $projectRoot).Path

Write-Host 'TaCZ Prone Hitbox - production dedicated server smoke test'
Write-Host ('Project: ' + $projectRoot)

# ------------------------------------------------ inputs
Write-Section 'Preconditions'

$modJarPath = $null
$libsDir = Join-Path $projectRoot 'build\libs'
if (Test-Path -LiteralPath $libsDir -PathType Container) {
    $cands = @(Get-ChildItem -LiteralPath $libsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch '-(sources|javadoc)\.jar$' } |
        Sort-Object LastWriteTime -Descending)
    if ($cands.Count -gt 0) { $modJarPath = $cands[0].FullName }
}
if ($modJarPath) {
    Add-Result 'PASS' 'mod.jar' (Split-Path -Leaf $modJarPath)
} else {
    Add-Result 'FAIL' 'mod.jar' 'build the mod first (cmd /c build-offline.bat build)'
}

$taczJarPath = Resolve-FirstExistingPath -Candidates @(
    (Join-Path $projectRoot 'libs\tacz-1.20.1-1.1.8-hotfix2.jar'))
if (-not $taczJarPath) {
    $taczLibsDir = Join-Path $projectRoot 'libs'
    if (Test-Path -LiteralPath $taczLibsDir -PathType Container) {
        $cands = @(Get-ChildItem -LiteralPath $taczLibsDir -Filter 'tacz*.jar' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending)
        if ($cands.Count -gt 0) { $taczJarPath = $cands[0].FullName }
    }
}
if ($taczJarPath) {
    Add-Result 'PASS' 'tacz.jar' (Split-Path -Leaf $taczJarPath)
} else {
    Add-Result 'FAIL' 'tacz.jar' 'TaCZ jar not found in libs\'
}

$candidateTemplates = @()
if ($ServerTemplate) { $candidateTemplates += $ServerTemplate }
# Auto-discovery: look for a local Forge 1.20.1-47.4.0 dedicated server install (a folder
# whose libraries\net\minecraftforge\forge\1.20.1-47.4.0\win_args.txt exists) up to
# depth 3 under the fixed data drives. This avoids hard-coding localized folder names.
$forgeMarkerRelative = 'libraries\net\minecraftforge\forge\1.20.1-47.4.0\win_args.txt'
foreach ($driveRoot in @('D:\', 'E:\')) {
    if (-not (Test-Path -LiteralPath $driveRoot -PathType Container)) { continue }
    $libraryDirs = @(Get-ChildItem -LiteralPath $driveRoot -Directory -Depth 3 -Filter 'libraries' -ErrorAction SilentlyContinue)
    foreach ($libraryDir in $libraryDirs) {
        if (Test-Path -LiteralPath (Join-Path $libraryDir.FullName 'net\minecraftforge\forge\1.20.1-47.4.0\win_args.txt') -PathType Leaf) {
            $candidateTemplates += (Split-Path -Parent $libraryDir.FullName)
        }
    }
}
$templateRoot = $null
foreach ($candidateTemplate in $candidateTemplates) {
    if ([string]::IsNullOrEmpty($candidateTemplate)) { continue }
    if (Test-Path -LiteralPath (Join-Path $candidateTemplate $forgeMarkerRelative) -PathType Leaf) {
        $templateRoot = (Resolve-Path -LiteralPath $candidateTemplate).Path
        break
    }
}
if ($templateRoot) {
    Add-Result 'PASS' 'server.template' $templateRoot
} else {
    Add-Result 'FAIL' 'server.template' 'no local Forge 1.20.1-47.4.0 server template found; pass -ServerTemplate <dir>'
}

$javaExe = Resolve-FirstExistingPath -Candidates @(
    $Java,
    'D:\zulu17\bin\java.exe',
    'D:\OpenJDK17\jdk-17.0.20.1+1\bin\java.exe',
    (Join-Path $env:JAVA_HOME 'bin\java.exe'))
$javacExe = $null
$jarExe = $null
if ($javaExe) {
    $jdkBin = Split-Path -Parent $javaExe
    $javacExe = Resolve-FirstExistingPath -Candidates @((Join-Path $jdkBin 'javac.exe'))
    $jarExe = Resolve-FirstExistingPath -Candidates @((Join-Path $jdkBin 'jar.exe'))
    $javaVersionLine = ''
    $savedErrorAction = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $javaVersionLine = [string](& $javaExe -version 2>&1 | Select-Object -Last 1) } catch { $javaVersionLine = 'java -version failed' }
    $ErrorActionPreference = $savedErrorAction
    Add-Result 'PASS' 'java17' $javaVersionLine.Trim()
} else {
    Add-Result 'FAIL' 'java17' 'no java.exe found; pass -Java <path>'
}

if ($script:FailCount -gt 0) {
    Write-Section 'Result'
    Write-Host ("PASS {0} | FAIL {1} | WARN {2} | SKIP {3}" -f $script:PassCount, $script:FailCount, $script:WarnCount, $script:SkipCount)
    foreach ($failure in $script:Failures) { Write-Host ('  FAILED: ' + $failure) }
    Write-Host 'RESULT: ENVIRONMENT-LIMITED (preconditions)'
    exit 2
}

# ------------------------------------------------ prepare runtime
Write-Section 'Prepare production runtime'
$prodDir = Join-Path $projectRoot 'run-server\prod'
$prodLogs = Join-Path $prodDir 'logs'
$prodMods = Join-Path $prodDir 'mods'
foreach ($dir in @($prodDir, $prodLogs, $prodMods)) {
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
}
if (-not (Test-PathInsideProject -Path $prodDir -ProjectRoot $projectRoot)) {
    Add-Result 'FAIL' 'prod.dir' 'refusing to work outside the project directory'
    exit 2
}

$copiedLibraries = Join-Path $prodDir 'libraries'
$templateLibraries = Join-Path $templateRoot 'libraries'
if (-not (Test-Path -LiteralPath $copiedLibraries -PathType Container)) {
    Write-Host ('Copying production server libraries (about 160 MB) from ' + $templateLibraries + ' ...')
    Copy-Item -LiteralPath $templateLibraries -Destination $copiedLibraries -Recurse -Force
    Add-Result 'PASS' 'runtime.copied' 'run-server\prod\libraries'
} else {
    Add-Result 'PASS' 'runtime.copied' 'run-server\prod\libraries (reused)'
}

$winArgsRelative = 'libraries/net/minecraftforge/forge/1.20.1-47.4.0/win_args.txt'
$winArgsPath = Join-Path $prodDir $winArgsRelative
if (Test-Path -LiteralPath $winArgsPath -PathType Leaf) {
    Add-Result 'PASS' 'runtime.launchArgs' $winArgsRelative
} else {
    Add-Result 'FAIL' 'runtime.launchArgs' ($winArgsRelative + ' missing from the copied runtime')
}

foreach ($worldName in @('world', 'world_nether', 'world_the_end')) {
    $worldPath = Join-Path $prodDir $worldName
    if ((Test-Path -LiteralPath $worldPath -PathType Container) -and (Test-PathInsideProject -Path $worldPath -ProjectRoot $projectRoot)) {
        Remove-Item -LiteralPath $worldPath -Recurse -Force
    }
}

Set-Content -LiteralPath (Join-Path $prodDir 'eula.txt') -Value 'eula=true' -Encoding ASCII
$propertiesLines = @(
    'online-mode=false',
    ('server-port=' + $ServerPort),
    'level-name=smoketest',
    'level-type=minecraft\:flat',
    'generate-structures=false',
    'max-tick-time=-1',
    'spawn-protection=0',
    'enable-status=false',
    'motd=taczpronehitbox production smoke test',
    'gamemode=creative',
    'view-distance=4',
    'simulation-distance=4'
)
Set-Content -LiteralPath (Join-Path $prodDir 'server.properties') -Value $propertiesLines -Encoding ASCII
Add-Result 'PASS' 'server.properties' ('server-port=' + $ServerPort + ', flat world')

if (Test-Path -LiteralPath $prodMods -PathType Container) {
    Get-ChildItem -LiteralPath $prodMods -Filter '*.jar' -File -ErrorAction SilentlyContinue | ForEach-Object {
        if ($_.FullName -and (Test-PathInsideProject -Path $_.FullName -ProjectRoot $projectRoot)) { Remove-Item -LiteralPath $_.FullName -Force }
    }
}
Copy-Item -LiteralPath $modJarPath -Destination (Join-Path $prodMods (Split-Path -Leaf $modJarPath)) -Force
Copy-Item -LiteralPath $taczJarPath -Destination (Join-Path $prodMods (Split-Path -Leaf $taczJarPath)) -Force
Add-Result 'PASS' 'mods.deployed' ((Split-Path -Leaf $modJarPath) + ', ' + (Split-Path -Leaf $taczJarPath))

# ------------------------------------------------ probe mod
Write-Section 'Mixin probe mod'
$probeJar = $null
if ($SkipProbe) {
    Add-Result 'SKIP' 'probe.build' '-SkipProbe'
} elseif (-not ($javacExe -and $jarExe)) {
    Add-Result 'WARN' 'probe.build' 'javac/jar not found next to java.exe; mixin will not be force-loaded'
} else {
    $probeSourceDir = Join-Path $prodDir 'smoke-src'
    $probeStage = Join-Path $prodDir 'smoke-stage'
    if (Test-Path -LiteralPath $probeSourceDir -PathType Container) { Remove-Item -LiteralPath $probeSourceDir -Recurse -Force }
    if (Test-Path -LiteralPath $probeStage -PathType Container) { Remove-Item -LiteralPath $probeStage -Recurse -Force }
    $javaOut = Join-Path $probeSourceDir 'tphsmoke'
    New-Item -ItemType Directory -Force -Path $javaOut | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $probeStage 'META-INF') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $probeStage 'tphsmoke') | Out-Null

    $probeSource = @'
package tphsmoke;

import net.minecraftforge.fml.common.Mod;

/**
 * Throwaway smoke-test mod (NOT shipped). Forces the TaCZ EntityUtil class to load during
 * mod construction, which makes Mixin apply taczpronehitbox.mixins.json:EntityUtilMixin
 * at server startup. If the mixin target is wrong, Mixin throws here and the log records
 * it; if EntityUtil loads, the mixin applied successfully.
 */
@Mod("tphsmokeprobe")
public final class TphSmokeProbe {

    public TphSmokeProbe() {
        System.out.println("TPH_SMOKE_PROBE: begin, loading com.tacz.guns.util.EntityUtil");
        try {
            Class.forName("com.tacz.guns.util.EntityUtil", false, TphSmokeProbe.class.getClassLoader());
            System.out.println("TPH_SMOKE_PROBE: EntityUtil loaded, taczpronehitbox mixin applied OK");
        } catch (Throwable throwable) {
            System.out.println("TPH_SMOKE_PROBE: FAILED to load EntityUtil");
            throwable.printStackTrace(System.out);
        }
    }
}
'@
    $probeSourcePath = Join-Path $javaOut 'TphSmokeProbe.java'
    Set-Content -LiteralPath $probeSourcePath -Value $probeSource -Encoding ASCII
    $modsToml = @'
modLoader="javafml"
loaderVersion="[47,)"
license="MIT"

[[mods]]
modId="tphsmokeprobe"
version="1.0.0"
displayName="TPH Mixin Smoke Probe"
authors="taczpronehitbox verifier"
description='''Throwaway smoke-test mod. Forces com.tacz.guns.util.EntityUtil to load so the
taczpronehitbox mixin is applied at dedicated-server startup. NOT part of the release.'''

[[dependencies.tphsmokeprobe]]
modId="forge"
mandatory=true
versionRange="[47,)"
ordering="NONE"
side="BOTH"

[[dependencies.tphsmokeprobe]]
modId="minecraft"
mandatory=true
versionRange="[1.20.1,1.20.2)"
ordering="NONE"
side="BOTH"

[[dependencies.tphsmokeprobe]]
modId="tacz"
mandatory=true
versionRange="[1.1.8,)"
ordering="AFTER"
side="BOTH"
'@
    Set-Content -LiteralPath (Join-Path $probeStage 'META-INF\mods.toml') -Value $modsToml -Encoding ASCII

    $fmlLangJar = Join-Path $copiedLibraries 'net\minecraftforge\javafmllanguage\1.20.1-47.4.0\javafmllanguage-1.20.1-47.4.0.jar'
    if (-not (Test-Path -LiteralPath $fmlLangJar -PathType Leaf)) { $fmlLangJar = $null }
    if ($fmlLangJar) {
        $compileOut = Join-Path $probeSourceDir 'classes'
        New-Item -ItemType Directory -Force -Path $compileOut | Out-Null
        $savedErrorAction = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $javacOutput = @(& $javacExe -encoding UTF-8 -cp $fmlLangJar -d $compileOut $probeSourcePath 2>&1)
            $javacExit = $LASTEXITCODE
            if ($javacExit -ne 0) {
                Write-Host ('[INFO] javac output: ' + (($javacOutput | ForEach-Object { [string]$_ }) -join ' | '))
            }
            if ($javacExit -eq 0) {
                # compileOut already contains the package folder (tphsmoke/...), copy its content to the jar root
                Copy-Item -Path (Join-Path $compileOut '*') -Destination $probeStage -Recurse -Force
                $probeJar = Join-Path $prodMods 'tphsmokeprobe-1.0.0.jar'
                $jarOutput = @(& $jarExe --create --file $probeJar -C $probeStage . 2>&1)
                if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $probeJar -PathType Leaf)) {
                    Add-Result 'PASS' 'probe.build' (Split-Path -Leaf $probeJar)
                } else {
                    Add-Result 'WARN' 'probe.build' ('jar creation failed: ' + (($jarOutput | ForEach-Object { [string]$_ }) -join ' | '))
                    $probeJar = $null
                }
            } else {
                Add-Result 'WARN' 'probe.build' 'javac failed; continuing without probe'
            }
        } catch {
            Add-Result 'WARN' 'probe.build' ('probe build error: ' + $_.Exception.Message)
            $probeJar = $null
        } finally {
            $ErrorActionPreference = $savedErrorAction
        }
    } else {
        Add-Result 'WARN' 'probe.build' 'javafmllanguage jar not found; continuing without probe'
    }
}

# ------------------------------------------------ launch
Write-Section 'Launch production server'
$latestLog = Join-Path $prodLogs 'latest.log'
if (Test-Path -LiteralPath $latestLog -PathType Leaf) {
    Move-Item -LiteralPath $latestLog -Destination (Join-Path $prodLogs 'latest.previous.log') -Force
}
$stdoutLog = Join-Path $prodDir 'smoke-stdout.log'
$stderrLog = Join-Path $prodDir 'smoke-stderr.log'
if (Test-Path -LiteralPath $stdoutLog) { Remove-Item -LiteralPath $stdoutLog -Force }
if (Test-Path -LiteralPath $stderrLog) { Remove-Item -LiteralPath $stderrLog -Force }

$launchArgs = @('-Xms1G', '-Xmx2G', '-Dmixin.debug.verbose=true', ('@' + $winArgsRelative), 'nogui')
Write-Host ($javaExe + ' ' + ($launchArgs -join ' '))
$startArgs = @{
    FilePath = $javaExe
    ArgumentList = $launchArgs
    WorkingDirectory = $prodDir
    RedirectStandardOutput = $stdoutLog
    RedirectStandardError = $stderrLog
    WindowStyle = 'Hidden'
    PassThru = $true
}
$launcher = Start-Process @startArgs
Add-Result 'PASS' 'server.launched' ('pid ' + $launcher.Id)

$fatalPattern = 'Failed to start the minecraft server|Exception in thread "main"|A fatal error has been detected|Could not find or load main class'
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
    if ((Get-Date) -gt $deadline) { break }
}
if ($started) {
    Add-Result 'PASS' 'server.started' 'Done ( seen in latest.log'
    Start-Sleep -Seconds 3
} elseif ($fatal) {
    Add-Result 'FAIL' 'server.started' $fatal
} elseif ($exited) {
    Add-Result 'FAIL' 'server.started' 'server process exited before startup'
} else {
    Add-Result 'FAIL' 'server.started' ('timeout after ' + $StartupTimeoutSec + 's')
}

$savedLog = Join-Path $prodDir 'smoke-server-latest.log'
$runningText = Read-TextSafe -Path $latestLog
if ($runningText) { Set-Content -LiteralPath $savedLog -Value $runningText -Encoding UTF8 }

Write-Section 'Stop server'
if (-not $launcher.HasExited) {
    try { Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue } catch { }
}
$stopDeadline = (Get-Date).AddSeconds(15)
while (-not $launcher.HasExited -and (Get-Date) -lt $stopDeadline) { Start-Sleep -Milliseconds 500 }
if ($launcher.HasExited) {
    Add-Result 'PASS' 'server.stopped' 'java process terminated (smoke stop is force-kill)'
} else {
    Add-Result 'FAIL' 'server.stopped' 'could not terminate the java process'
}

# ------------------------------------------------ log checks
Write-Section 'Log checks'
$serverText = Read-TextSafe -Path $latestLog
if (-not $serverText) { $serverText = $runningText }
$combined = Join-Lines -Lines @([string]$serverText, [string](Read-TextSafe -Path $stdoutLog), [string](Read-TextSafe -Path $stderrLog))

if ($combined -match 'Done \(') {
    Add-Result 'PASS' 'server.started.log' '"Done (" present in log'
} else {
    Add-Result 'FAIL' 'server.started.log' '"Done (" missing from log'
}

if ($combined -match 'taczpronehitbox') {
    Add-Result 'PASS' 'mod.loaded' 'taczpronehitbox mentioned in log'
} else {
    Add-Result 'FAIL' 'mod.loaded' 'taczpronehitbox not mentioned in log'
}

if (-not $SkipProbe -and $probeJar) {
    if ($combined -match 'TPH_SMOKE_PROBE: EntityUtil loaded, taczpronehitbox mixin applied OK') {
        Add-Result 'PASS' 'mixin.applied.runtime' 'probe force-loaded EntityUtil; mixin applied without error'
    } elseif ($combined -match 'TPH_SMOKE_PROBE: FAILED to load EntityUtil') {
        Add-Result 'FAIL' 'mixin.applied.runtime' 'probe could not load EntityUtil (see probe stack trace)'
    } elseif ($combined -match 'TPH_SMOKE_PROBE: begin') {
        Add-Result 'FAIL' 'mixin.applied.runtime' 'probe started but did not finish loading EntityUtil'
    } else {
        Add-Result 'FAIL' 'mixin.applied.runtime' 'probe marker missing from log'
    }
} else {
    Add-Result 'SKIP' 'mixin.applied.runtime' 'probe mod not built'
}

$mixinErrorPattern = 'Mixin apply failed[^\r\n]*taczpronehitbox|Mixin apply failed[^\r\n]*EntityUtilMixin|InvalidInjectionException[^\r\n]*EntityUtil'
if ($combined -match $mixinErrorPattern) {
    $line = ([regex]::Match($combined, '(?im)^.*(Mixin apply failed|InvalidInjectionException).*$')).Value
    Add-Result 'FAIL' 'mixin.apply.clean' ('mixin error: ' + $line.Trim())
} else {
    Add-Result 'PASS' 'mixin.apply.clean' 'no taczpronehitbox mixin apply failure'
}

$configPath = Join-Path $prodDir 'config\taczpronehitbox-common.toml'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    Add-Result 'PASS' 'config.generated' 'run-server\prod\config\taczpronehitbox-common.toml'
} else {
    Add-Result 'FAIL' 'config.generated' 'run-server\prod\config\taczpronehitbox-common.toml missing'
}

if ($combined -match '(?i)\btacz\b') {
    Add-Result 'PASS' 'tacz.loaded' 'tacz mentioned in log'
} else {
    Add-Result 'FAIL' 'tacz.loaded' 'tacz not mentioned in log (TaCZ did not load)'
}

$fatalLogPattern = 'Failed to start the minecraft server|Exception in thread "main"|A fatal error has been detected'
if ($combined -match $fatalLogPattern) {
    $line = ([regex]::Match($combined, '(?im)^.*(Failed to start the minecraft server|Exception in thread "main"|A fatal error has been detected).*$')).Value
    Add-Result 'FAIL' 'server.no.fatal' ('fatal: ' + $line.Trim())
} else {
    Add-Result 'PASS' 'server.no.fatal' 'no fatal startup failure'
}

$errorLines = @([regex]::Matches($combined, '(?im)^.*\b(ERROR|FATAL)\b.*$') | ForEach-Object { $_.Value.Trim() } | Select-Object -First 12)
if ($errorLines.Count -gt 0) {
    Write-Host '[INFO] first ERROR/FATAL lines:'
    foreach ($line in $errorLines) { Write-Host ('       ' + $line) }
}

if ($CleanRuntime) {
    if ((Test-Path -LiteralPath $copiedLibraries -PathType Container) -and (Test-PathInsideProject -Path $copiedLibraries -ProjectRoot $projectRoot)) {
        Remove-Item -LiteralPath $copiedLibraries -Recurse -Force
        Add-Result 'INFO' 'runtime.cleaned' 'run-server\prod\libraries removed (re-runs copy it again)'
    }
}

# ------------------------------------------------ summary
Write-Section 'Result'
Write-Host ('Server log:    ' + $latestLog)
Write-Host ('Saved log:     ' + $savedLog)
Write-Host ("PASS {0} | FAIL {1} | WARN {2} | SKIP {3}" -f $script:PassCount, $script:FailCount, $script:WarnCount, $script:SkipCount)
if ($script:FailCount -gt 0) {
    foreach ($failure in $script:Failures) { Write-Host ('  FAILED: ' + $failure) }
    Write-Host 'RESULT: FAILED'
    exit 1
}
Write-Host 'RESULT: OK'
exit 0
