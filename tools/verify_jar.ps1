#requires -Version 5.1
<#
.SYNOPSIS
    Static verification for the TaCZ Prone Hitbox mod jar and its TaCZ mixin targets.

.DESCRIPTION
    Checks the built mod jar (entries, MANIFEST MixinConfigs, expanded mods.toml,
    mixin config JSON, mixin class annotation targets) and cross-checks every mixin
    target against the TaCZ jar with javap:

      * com.tacz.guns.util.EntityUtil has
          - findEntityOnPath(Projectile, Vec3, Vec3)
          - findEntitiesOnPath(Projectile, Vec3, Vec3)
          - getHitResult(Projectile, Entity, Vec3, Vec3)   (TaCZ 1.1.8+ signature)
      * com.tacz.guns.entity.EntityKineticBullet$EntityResult has a public
        (Entity, Vec3, boolean) constructor
      * EntityUtil constant pool still references AABB.inflate -> m_82400_
      * every class / method / @At target declared by the mixin annotations exists

    Exit code: 0 when no check FAILed, 1 otherwise. WARN/SKIP do not fail the run.
    This script is read-only: it never writes to the project.

.PARAMETER Jar
    Mod jar to check. Defaults to the newest non-sources jar in build/libs.

.PARAMETER TaczJar
    TaCZ jar used as the mixin target baseline. Defaults to
    libs/tacz-1.20.1-1.1.8-hotfix2.jar, then falls back to libs/tacz*.jar.

.PARAMETER Javap
    Path to javap.exe. Auto-detected (prefers JDK 17) when omitted.

.PARAMETER SkipTacz
    Skip every check that needs the TaCZ jar.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\verify_jar.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File tools\verify_jar.ps1 -Jar build\libs\taczpronehitbox-1.20.1-1.0.0.jar
#>
[CmdletBinding()]
param(
    [string]$Jar = '',
    [string]$TaczJar = '',
    [string]$Javap = '',
    [switch]$SkipTacz
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:NewLine = [string][char]10

# ---------------------------------------------------------------- state
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

# ---------------------------------------------------------------- generic helpers
function Get-JsonProperty {
    param($Object, [string]$PropertyName, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($null -eq $prop) { return $Default }
    return $prop.Value
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

function Read-ZipEntryText {
    param($Zip, [string]$EntryName)
    $entry = $Zip.GetEntry($EntryName)
    if ($null -eq $entry) { return $null }
    $stream = $entry.Open()
    $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose(); $stream.Dispose() }
}

function Read-ManifestMap {
    param($Zip)
    $text = Read-ZipEntryText -Zip $Zip -EntryName 'META-INF/MANIFEST.MF'
    $map = @{}
    if ($null -eq $text) { return $map }
    $currentKey = $null
    foreach ($line in [regex]::Split($text, "\r?\n")) {
        if ($line -match '^[ \t]') {
            if ($currentKey) { $map[$currentKey] = [string]$map[$currentKey] + $line.Substring(1) }
            continue
        }
        if ($line -match '^([^:]+):[ ]?(.*)$') {
            $currentKey = $Matches[1]
            $map[$currentKey] = $Matches[2]
        } elseif ($line.Trim() -eq '') {
            $currentKey = $null
        }
    }
    return $map
}

function Get-ManifestValue {
    param($Map, [string]$Key)
    if ($null -eq $Map) { return $null }
    if ($Map.ContainsKey($Key)) { return $Map[$Key] }
    foreach ($k in $Map.Keys) { if ($k -ieq $Key) { return $Map[$k] } }
    return $null
}

function Test-ZipClassEntry {
    param($Zip, [string]$ClassName)
    if ($null -eq $Zip) { return $false }
    $entryPath = $ClassName.Replace('.', '/') + '.class'
    return ($null -ne $Zip.GetEntry($entryPath))
}

# ---------------------------------------------------------------- javap helpers
function Resolve-JavapExe {
    param([string]$Requested)
    $candidates = New-Object System.Collections.ArrayList
    if ($Requested) { [void]$candidates.Add($Requested) }
    [void]$candidates.Add('D:\OpenJDK17\jdk-17.0.20.1+1\bin\javap.exe')
    [void]$candidates.Add('D:\zulu17\bin\javap.exe')
    if ($env:JAVA_HOME) { [void]$candidates.Add((Join-Path $env:JAVA_HOME 'bin\javap.exe')) }
    $cmd = Get-Command javap.exe -ErrorAction SilentlyContinue
    if ($cmd) { [void]$candidates.Add($cmd.Source) }
    return (Resolve-FirstExistingPath -Candidates ($candidates.ToArray()))
}

function Invoke-JavapLines {
    param([string[]]$Arguments)
    $raw = & $script:JavapExe @Arguments 2>&1
    $lines = New-Object System.Collections.ArrayList
    foreach ($item in $raw) { [void]$lines.Add([string]$item) }
    return ,$lines.ToArray()
}

function Get-JavapLines {
    param([string]$ClassPath, [string]$ClassName, [switch]$VerboseOutput)
    $javapArgs = @('-classpath', $ClassPath, '-p')
    if ($VerboseOutput) { $javapArgs += '-v' }
    $javapArgs += $ClassName
    return ,(Invoke-JavapLines -Arguments $javapArgs)
}

function Get-JavapText {
    param([string]$ClassPath, [string]$ClassName, [switch]$VerboseOutput)
    $lines = Get-JavapLines -ClassPath $ClassPath -ClassName $ClassName -VerboseOutput:$VerboseOutput
    return (Join-Lines -Lines $lines)
}

function Get-JavapErrorText {
    param([string[]]$Lines, [string]$Text)
    if ($null -eq $Lines -or $Lines.Count -eq 0) { return 'javap produced no output' }
    if ([string]::IsNullOrEmpty($Text)) { $Text = Join-Lines -Lines $Lines }
    foreach ($line in $Lines) {
        if ($line -match '^(Error|Exception): ') { return $line }
    }
    return $null
}

# ---------------------------------------------------------------- annotation parsing
function Get-AnnotationBlocks {
    param([string[]]$Lines, [string]$StartPattern)
    $blocks = New-Object System.Collections.ArrayList
    if ($null -eq $Lines) { return ,$blocks.ToArray() }
    $count = $Lines.Count
    for ($i = 0; $i -lt $count; $i++) {
        if ($Lines[$i] -match $StartPattern) {
            $builder = New-Object System.Text.StringBuilder
            [void]$builder.AppendLine($Lines[$i])
            for ($j = $i + 1; $j -lt $count; $j++) {
                [void]$builder.AppendLine($Lines[$j])
                if ($Lines[$j] -match '^\s*\)\s*$') { break }
            }
            [void]$blocks.Add($builder.ToString())
        }
    }
    return ,$blocks.ToArray()
}

function Get-QuotedStrings {
    param([string]$Value)
    $result = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Value, '"([^"]*)"')) { [void]$result.Add($m.Groups[1].Value) }
    return ,$result.ToArray()
}

function Get-MixinTargets {
    param([string]$Block)
    $targets = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Block, 'class L([^;\s]+);')) {
        [void]$targets.Add($m.Groups[1].Value.Replace('/', '.'))
    }
    foreach ($m in [regex]::Matches($Block, '"([A-Za-z_$][A-Za-z0-9_$]*(\.[A-Za-z_$][A-Za-z0-9_$]*)+)"')) {
        [void]$targets.Add($m.Groups[1].Value)
    }
    $unique = @()
    foreach ($t in $targets) { if ($unique -notcontains $t) { $unique += $t } }
    return ,$unique
}

function Get-InjectionMethodTargets {
    param([string]$Block)
    $methods = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Block, 'method\s*=\s*(\[[^\]]*\]|"[^"]*")')) {
        foreach ($s in (Get-QuotedStrings -Value $m.Groups[1].Value)) { [void]$methods.Add($s) }
    }
    return ,$methods.ToArray()
}

function Get-InjectionAtTargets {
    param([string]$Block)
    $targets = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($Block, '(?<![\w$])target\s*=\s*"([^"]+)"')) {
        [void]$targets.Add($m.Groups[1].Value)
    }
    return ,$targets.ToArray()
}

function ConvertFrom-MemberRef {
    param([string]$Descriptor)
    if ($Descriptor -match '^L([^;]+);([^\(\:]+)\(') {
        return [pscustomobject]@{ Owner = $Matches[1]; MemberName = $Matches[2]; Kind = 'method' }
    }
    if ($Descriptor -match '^L([^;]+);([^\:]+):') {
        return [pscustomobject]@{ Owner = $Matches[1]; MemberName = $Matches[2]; Kind = 'field' }
    }
    return $null
}

# ================================================================ main
$projectRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($projectRoot)) { $projectRoot = (Get-Location).Path }

Write-Host 'TaCZ Prone Hitbox - static jar verification'
Write-Host ('Project: ' + $projectRoot)

try { Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop } catch { }
try { Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop } catch { }

# ------------------------------------------------ resolve inputs
$modJarPath = $Jar
if ([string]::IsNullOrWhiteSpace($modJarPath)) {
    $libsDir = Join-Path $projectRoot 'build\libs'
    if (Test-Path -LiteralPath $libsDir -PathType Container) {
        $candidates = @(Get-ChildItem -LiteralPath $libsDir -Filter '*.jar' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notmatch '-(sources|javadoc)\.jar$' } |
            Sort-Object LastWriteTime -Descending)
        if ($candidates.Count -gt 0) { $modJarPath = $candidates[0].FullName }
    }
}
if (-not [string]::IsNullOrWhiteSpace($modJarPath) -and -not (Test-Path -LiteralPath $modJarPath -PathType Leaf)) {
    Write-Host ('[FAIL] jar.found -- file does not exist: ' + $modJarPath)
    Write-Host ''
    Write-Host 'RESULT: FAILED (jar missing)'
    exit 1
}

$taczJarPath = $TaczJar
if (-not $SkipTacz -and [string]::IsNullOrWhiteSpace($taczJarPath)) {
    $preferred = Join-Path $projectRoot 'libs\tacz-1.20.1-1.1.8-hotfix2.jar'
    $taczJarPath = Resolve-FirstExistingPath -Candidates @($preferred)
    if ([string]::IsNullOrEmpty($taczJarPath)) {
        $taczLibsDir = Join-Path $projectRoot 'libs'
        if (Test-Path -LiteralPath $taczLibsDir -PathType Container) {
            $cands = @(Get-ChildItem -LiteralPath $taczLibsDir -Filter 'tacz*.jar' -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending)
            if ($cands.Count -gt 0) { $taczJarPath = $cands[0].FullName }
        }
    }
}

$script:JavapExe = Resolve-JavapExe -Requested $Javap

Write-Section 'Environment'
if ($modJarPath) {
    Add-Result 'INFO' 'jar.selected' $modJarPath
} else {
    Add-Result 'FAIL' 'jar.selected' 'no jar found; build the mod first (cmd /c build-offline.bat build)'
}
if ($SkipTacz) {
    Add-Result 'SKIP' 'tacz.jar.selected' 'SkipTacz set'
} elseif ($taczJarPath) {
    Add-Result 'INFO' 'tacz.jar.selected' $taczJarPath
} else {
    Add-Result 'FAIL' 'tacz.jar.selected' 'TaCZ jar not found; put tacz-1.20.1-1.1.8-hotfix2.jar into libs\'
}
if ($script:JavapExe) {
    Add-Result 'INFO' 'javap.selected' $script:JavapExe
} else {
    Add-Result 'FAIL' 'javap.selected' 'javap.exe not found; install a JDK 17 or pass -Javap'
}

if (-not $modJarPath) {
    Write-Section 'Summary'
    Write-Host ("PASS {0} | FAIL {1} | WARN {2} | SKIP {3}" -f $script:PassCount, $script:FailCount, $script:WarnCount, $script:SkipCount)
    exit 1
}

# ------------------------------------------------ open jars
$modZip = $null
$taczZip = $null
try {
    try {
        $modZip = [System.IO.Compression.ZipFile]::OpenRead($modJarPath)
        Add-Result 'PASS' 'jar.readable' (Split-Path -Leaf $modJarPath)
    } catch {
        Add-Result 'FAIL' 'jar.readable' $_.Exception.Message
    }

    if ($modZip) {
        Write-Section 'Mod jar structure'

        $requiredEntries = @(
            'taczpronehitbox.mixins.json',
            'META-INF/mods.toml',
            'META-INF/MANIFEST.MF',
            'pack.mcmeta'
        )
        foreach ($entryName in $requiredEntries) {
            if ($null -ne $modZip.GetEntry($entryName)) {
                Add-Result 'PASS' ('jar.entry.' + $entryName)
            } else {
                Add-Result 'FAIL' ('jar.entry.' + $entryName) 'missing from jar'
            }
        }

        $hardMixinEntry = 'com/li/taczpronehitbox/mixin/tacz/EntityUtilMixin.class'
        if ($null -ne $modZip.GetEntry($hardMixinEntry)) {
            Add-Result 'PASS' 'jar.entry.EntityUtilMixin' $hardMixinEntry
        } else {
            Add-Result 'FAIL' 'jar.entry.EntityUtilMixin' ($hardMixinEntry + ' missing (hit-engine mixin not built?)')
        }

        # ---- MANIFEST
        $manifest = Read-ManifestMap -Zip $modZip
        $mixinConfigsValue = Get-ManifestValue -Map $manifest -Key 'MixinConfigs'
        if ($mixinConfigsValue) {
            if ($mixinConfigsValue -match 'taczpronehitbox\.mixins\.json') {
                Add-Result 'PASS' 'manifest.MixinConfigs' $mixinConfigsValue
            } else {
                Add-Result 'FAIL' 'manifest.MixinConfigs' ('unexpected value: ' + $mixinConfigsValue)
            }
        } else {
            Add-Result 'FAIL' 'manifest.MixinConfigs' 'attribute missing from META-INF/MANIFEST.MF'
        }
        $implVersion = Get-ManifestValue -Map $manifest -Key 'Implementation-Version'
        if ($implVersion) { Add-Result 'INFO' 'manifest.Implementation-Version' $implVersion }

        # ---- mods.toml
        $modsToml = Read-ZipEntryText -Zip $modZip -EntryName 'META-INF/mods.toml'
        if ($null -eq $modsToml) {
            Add-Result 'FAIL' 'mods.toml.content' 'META-INF/mods.toml missing'
        } else {
            if ($modsToml -match 'modLoader\s*=\s*"javafml"') {
                Add-Result 'PASS' 'mods.toml.modLoader'
            } else {
                Add-Result 'FAIL' 'mods.toml.modLoader' 'modLoader = "javafml" not found'
            }
            if ($modsToml -match 'modId\s*=\s*"taczpronehitbox"') {
                Add-Result 'PASS' 'mods.toml.modId'
            } else {
                Add-Result 'FAIL' 'mods.toml.modId' 'modId="taczpronehitbox" not found (processResources expansion?)'
            }
            if ($modsToml -match '\$\{') {
                Add-Result 'FAIL' 'mods.toml.expanded' 'unresolved build placeholder left in mods.toml'
            } else {
                Add-Result 'PASS' 'mods.toml.expanded'
            }
            if ($modsToml -match 'modId\s*=\s*"tacz"') {
                Add-Result 'PASS' 'mods.toml.depends.tacz'
            } else {
                Add-Result 'FAIL' 'mods.toml.depends.tacz' 'mandatory TaCZ dependency not found'
            }
            if ($modsToml -match 'versionRange\s*=\s*"\[1\.1\.8\s*,[^"]*\)"') {
                Add-Result 'PASS' 'mods.toml.depends.tacz.range' '1.1.8+'
            } else {
                Add-Result 'FAIL' 'mods.toml.depends.tacz.range' 'expected versionRange="[1.1.8,)"'
            }
        }

        # ---- mixin config json
        $mixinJsonText = Read-ZipEntryText -Zip $modZip -EntryName 'taczpronehitbox.mixins.json'
        $mixinConfig = $null
        if ($null -eq $mixinJsonText) {
            Add-Result 'FAIL' 'mixins.json.parse' 'taczpronehitbox.mixins.json missing'
        } else {
            try {
                $mixinConfig = $mixinJsonText | ConvertFrom-Json
                Add-Result 'PASS' 'mixins.json.parse'
            } catch {
                Add-Result 'FAIL' 'mixins.json.parse' ('invalid JSON: ' + $_.Exception.Message)
            }
        }

        $mixinEntries = New-Object System.Collections.ArrayList
        if ($mixinConfig) {
            $mixinPackage = [string](Get-JsonProperty -Object $mixinConfig -PropertyName 'package' -Default '')
            if ($mixinPackage -ne '') {
                Add-Result 'PASS' 'mixins.json.package' $mixinPackage
            } else {
                Add-Result 'FAIL' 'mixins.json.package' '"package" missing'
            }

            $requiredFlag = Get-JsonProperty -Object $mixinConfig -PropertyName 'required' -Default $null
            if ($requiredFlag -eq $true) {
                Add-Result 'PASS' 'mixins.json.required' 'true'
            } else {
                Add-Result 'WARN' 'mixins.json.required' ('expected true, got: ' + [string]$requiredFlag)
            }

            $pluginName = Get-JsonProperty -Object $mixinConfig -PropertyName 'plugin' -Default $null
            if ($pluginName) {
                if (Test-ZipClassEntry -Zip $modZip -ClassName ([string]$pluginName)) {
                    Add-Result 'PASS' 'mixins.json.plugin' ([string]$pluginName)
                } else {
                    Add-Result 'FAIL' 'mixins.json.plugin' ('plugin class not in jar: ' + [string]$pluginName)
                }
            } else {
                Add-Result 'SKIP' 'mixins.json.plugin' 'no plugin declared (supported)'
            }

            foreach ($listName in @('mixins', 'client', 'server')) {
                $listValue = Get-JsonProperty -Object $mixinConfig -PropertyName $listName -Default $null
                foreach ($mixinName in @($listValue)) {
                    if ($null -eq $mixinName -or [string]::IsNullOrWhiteSpace([string]$mixinName)) { continue }
                    $fullClass = [string]$mixinName
                    if ($mixinPackage -ne '') { $fullClass = $mixinPackage + '.' + $fullClass }
                    $checkName = 'mixins.json.' + $listName + '.' + $fullClass
                    if (Test-ZipClassEntry -Zip $modZip -ClassName $fullClass) {
                        Add-Result 'PASS' $checkName
                    } else {
                        Add-Result 'FAIL' $checkName 'declared mixin class missing from jar'
                    }
                    [void]$mixinEntries.Add($fullClass)
                }
            }
        }
    } else {
        $mixinEntries = New-Object System.Collections.ArrayList
    }

    # ------------------------------------------------ TaCZ baseline
    Write-Section 'TaCZ baseline'
    if ($SkipTacz) {
        Add-Result 'SKIP' 'tacz.jar.readable' 'SkipTacz set'
    } elseif (-not $taczJarPath) {
        Add-Result 'FAIL' 'tacz.jar.readable' 'TaCZ jar not found (see Environment)'
    } else {
        try {
            $taczZip = [System.IO.Compression.ZipFile]::OpenRead($taczJarPath)
            Add-Result 'PASS' 'tacz.jar.readable' (Split-Path -Leaf $taczJarPath)
        } catch {
            Add-Result 'FAIL' 'tacz.jar.readable' $_.Exception.Message
        }
    }

    $entityUtilClass = 'com.tacz.guns.util.EntityUtil'
    $entityResultClass = 'com.tacz.guns.entity.EntityKineticBullet$EntityResult'

    if ($taczZip) {
        foreach ($requiredClass in @($entityUtilClass, $entityResultClass)) {
            if (Test-ZipClassEntry -Zip $taczZip -ClassName $requiredClass) {
                Add-Result 'PASS' ('tacz.class.' + $requiredClass)
            } else {
                Add-Result 'FAIL' ('tacz.class.' + $requiredClass) 'class missing from TaCZ jar'
            }
        }
    }

    $entityUtilDump = $null
    $entityUtilVerboseDump = $null
    $entityResultDump = $null
    if ($taczZip -and $script:JavapExe) {
        try {
            $entityUtilDump = Get-JavapText -ClassPath $taczJarPath -ClassName $entityUtilClass
            $entityUtilError = Get-JavapErrorText -Lines ([regex]::Split($entityUtilDump, "\r?\n")) -Text $entityUtilDump
            if ($entityUtilError) { Add-Result 'FAIL' 'tacz.javap.EntityUtil' $entityUtilError; $entityUtilDump = $null }
        } catch {
            Add-Result 'FAIL' 'tacz.javap.EntityUtil' $_.Exception.Message
        }
        if ($entityUtilDump) {
            $requiredMethods = @(
                @{ Label = 'findEntityOnPath'; Pattern = '\bfindEntityOnPath\s*\(' },
                @{ Label = 'findEntitiesOnPath'; Pattern = '\bfindEntitiesOnPath\s*\(' },
                @{ Label = 'getHitResult'; Pattern = '\bgetHitResult\s*\(\s*net\.minecraft\.world\.entity\.projectile\.Projectile\s*,\s*net\.minecraft\.world\.entity\.Entity\s*,' }
            )
            foreach ($methodSpec in $requiredMethods) {
                if ($entityUtilDump -match $methodSpec.Pattern) {
                    Add-Result 'PASS' ('tacz.EntityUtil.method.' + $methodSpec.Label)
                } else {
                    Add-Result 'FAIL' ('tacz.EntityUtil.method.' + $methodSpec.Label) 'method/signature not found (TaCZ 1.1.8+ expected)'
                }
            }
        }

        try {
            $entityUtilVerboseDump = Get-JavapText -ClassPath $taczJarPath -ClassName $entityUtilClass -VerboseOutput
        } catch {
            Add-Result 'FAIL' 'tacz.javap.EntityUtil.verbose' $_.Exception.Message
        }
        if ($entityUtilVerboseDump) {
            if ($entityUtilVerboseDump -match 'm_82400_') {
                Add-Result 'PASS' 'tacz.EntityUtil.constantpool.m_82400_' 'AABB.inflate SRG target present'
            } else {
                Add-Result 'FAIL' 'tacz.EntityUtil.constantpool.m_82400_' '@Redirect target missing from EntityUtil constant pool'
            }
            if ($entityUtilVerboseDump -match 'net/minecraft/world/phys/AABB\.m_82400_:') {
                Add-Result 'PASS' 'tacz.EntityUtil.constantpool.m_82400_.methodref'
            } else {
                Add-Result 'WARN' 'tacz.EntityUtil.constantpool.m_82400_.methodref' 'no AABB.m_82400_ Methodref comment found'
            }
        }

        try {
            $entityResultDump = Get-JavapText -ClassPath $taczJarPath -ClassName $entityResultClass
            $entityResultError = Get-JavapErrorText -Lines ([regex]::Split($entityResultDump, "\r?\n")) -Text $entityResultDump
            if ($entityResultError) { Add-Result 'FAIL' 'tacz.javap.EntityResult' $entityResultError; $entityResultDump = $null }
        } catch {
            Add-Result 'FAIL' 'tacz.javap.EntityResult' $_.Exception.Message
        }
        if ($entityResultDump) {
            $ctorPattern = 'public\s+com\.tacz\.guns\.entity\.EntityKineticBullet\$EntityResult\s*\(\s*net\.minecraft\.world\.entity\.Entity\s*,\s*net\.minecraft\.world\.phys\.Vec3\s*,\s*boolean\s*\)'
            if ($entityResultDump -match $ctorPattern) {
                Add-Result 'PASS' 'tacz.EntityResult.publicCtor' '(Entity, Vec3, boolean)'
            } else {
                Add-Result 'FAIL' 'tacz.EntityResult.publicCtor' 'public (Entity, Vec3, boolean) constructor not found'
            }
        }
    } elseif ($script:JavapExe -and -not $SkipTacz) {
        Add-Result 'SKIP' 'tacz.javap' 'TaCZ jar not readable'
    }

    # ------------------------------------------------ mixin target consistency
    Write-Section 'Mixin target consistency'
    $canCheckMixins = ($modZip -and $taczZip -and $script:JavapExe -and $mixinEntries.Count -gt 0)
    if (-not $canCheckMixins) {
        Add-Result 'SKIP' 'mixin.targets' 'need mod jar + TaCZ jar + javap + at least one mixin in mixins.json'
    } else {
        foreach ($mixinClass in $mixinEntries) {
            $dumpLines = $null
            try {
                $dumpLines = Get-JavapLines -ClassPath $modJarPath -ClassName $mixinClass -VerboseOutput
            } catch {
                Add-Result 'FAIL' ('mixin.' + $mixinClass + '.javap') $_.Exception.Message
                continue
            }
            $dumpText = Join-Lines -Lines $dumpLines
            $dumpError = Get-JavapErrorText -Lines $dumpLines -Text $dumpText
            if ($dumpError) {
                Add-Result 'FAIL' ('mixin.' + $mixinClass + '.javap') $dumpError
                continue
            }

            $mixinBlocks = Get-AnnotationBlocks -Lines $dumpLines -StartPattern '^\s*org\.spongepowered\.asm\.mixin\.Mixin\($'
            if ($mixinBlocks.Count -eq 0) {
                Add-Result 'FAIL' ('mixin.' + $mixinClass + '.annotation') 'no @Mixin annotation found'
                continue
            }
            $targets = @()
            foreach ($block in $mixinBlocks) {
                foreach ($t in (Get-MixinTargets -Block $block)) {
                    if ($targets -notcontains $t) { $targets += $t }
                }
            }
            if ($targets.Count -eq 0) {
                Add-Result 'FAIL' ('mixin.' + $mixinClass + '.targets') 'could not extract @Mixin target class'
                continue
            }

            $existingTargets = @()
            $targetTexts = @()
            foreach ($targetClass in $targets) {
                if (Test-ZipClassEntry -Zip $taczZip -ClassName $targetClass) {
                    Add-Result 'PASS' ('mixin.' + $mixinClass + '.target.' + $targetClass)
                    $existingTargets += $targetClass
                    try {
                        $targetText = Get-JavapText -ClassPath $taczJarPath -ClassName $targetClass -VerboseOutput
                        $targetError = Get-JavapErrorText -Lines ([regex]::Split($targetText, "\r?\n")) -Text $targetText
                        if (-not $targetError) { $targetTexts += $targetText }
                    } catch { }
                } elseif ($targetClass -like 'net.minecraft*') {
                    Add-Result 'WARN' ('mixin.' + $mixinClass + '.target.' + $targetClass) 'vanilla class target cannot be verified against the TaCZ jar'
                } else {
                    Add-Result 'FAIL' ('mixin.' + $mixinClass + '.target.' + $targetClass) 'target class not found in TaCZ jar'
                }
            }
            if ($existingTargets.Count -eq 0) { continue }
            $targetTextJoined = Join-Lines -Lines $targetTexts

            $injectionBlocks = Get-AnnotationBlocks -Lines $dumpLines -StartPattern '^\s*org\.spongepowered\.asm\.mixin\.injection\.[A-Za-z0-9_]+\($'
            if ($injectionBlocks.Count -eq 0) {
                Add-Result 'WARN' ('mixin.' + $mixinClass + '.injections') 'no @Inject/@Redirect annotation parsed (nothing to verify)'
            }
            foreach ($block in $injectionBlocks) {
                foreach ($methodName in (Get-InjectionMethodTargets -Block $block)) {
                    if ([string]::IsNullOrWhiteSpace($methodName)) { continue }
                    if ($methodName.Contains('*')) { continue }
                    $pattern = '(?m)\b' + [regex]::Escape($methodName) + '\s*\('
                    if ($targetTextJoined -match $pattern) {
                        Add-Result 'PASS' ('mixin.' + $mixinClass + '.method.' + $methodName)
                    } else {
                        Add-Result 'FAIL' ('mixin.' + $mixinClass + '.method.' + $methodName) 'method target not found in @Mixin target class'
                    }
                }
                foreach ($atTarget in (Get-InjectionAtTargets -Block $block)) {
                    $memberRef = ConvertFrom-MemberRef -Descriptor $atTarget
                    if ($null -eq $memberRef) { continue }
                    $needle = $memberRef.Owner + '.' + $memberRef.MemberName
                    $needleDotted = $memberRef.Owner.Replace('/', '.') + '.' + $memberRef.MemberName
                    if (($targetTextJoined -match [regex]::Escape($needle)) -or ($targetTextJoined -match [regex]::Escape($needleDotted))) {
                        Add-Result 'PASS' ('mixin.' + $mixinClass + '.at.' + $needle)
                    } else {
                        Add-Result 'FAIL' ('mixin.' + $mixinClass + '.at.' + $needle) 'call target not referenced by @Mixin target class'
                    }
                }
            }
        }
    }
} finally {
    if ($modZip) { $modZip.Dispose() }
    if ($taczZip) { $taczZip.Dispose() }
}

# ------------------------------------------------ summary
Write-Section 'Summary'
Write-Host ("PASS {0} | FAIL {1} | WARN {2} | SKIP {3}" -f $script:PassCount, $script:FailCount, $script:WarnCount, $script:SkipCount)
if ($script:FailCount -gt 0) {
    foreach ($failure in $script:Failures) { Write-Host ('  FAILED: ' + $failure) }
    Write-Host 'RESULT: FAILED'
    exit 1
}
Write-Host 'RESULT: OK'
exit 0
