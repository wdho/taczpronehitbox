#requires -Version 5.1
<#
.SYNOPSIS
    Analyze a Minecraft / Forge client latest.log for the TaCZ Prone Hitbox (taczpronehitbox) mod.

.DESCRIPTION
    Reads a Minecraft client log (typically
    <instance>/versions/<version>/logs/latest.log) and reports PASS / FAIL / WARN / SKIP
    for the checks that matter when testing the mod on a real game instance:

      * mod loaded (taczpronehitbox appears in the log; version when discoverable)
      * TaCZ EntityUtil mixin applied (MixinAudit start-up line)
      * sprint lock initialised (1.1.0 integrated feature; migration from Seamless Sprint)
      * network channel / server-presence evidence (1.1.0 feature, not always logged)
      * no fatal mixin / injection error that involves taczpronehitbox
      * no crash markers and no fresh crash-reports file
      * reached the title screen (Backend library + Sound engine started / OpenAL / atlases)
      * warnings / conflicts of TaCZ addon mods (taczaddon, tacz-tweaks, taczlabs, gd656*)

    Exit code: 0 when no check FAILed, 1 otherwise. WARN / SKIP do not fail the run.

.PARAMETER LogPath
    latest.log to analyze. Defaults to the user's PCL instance
    D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\logs\latest.log.

.PARAMETER DebugLogPath
    Optional debug.log. Defaults to debug.log next to the given latest.log when present.

.PARAMETER Jar
    Optional mod jar. When given, its version is compared with the version found in the logs.

.PARAMETER OutFile
    Optional path: the whole report is also written there (UTF-8).

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\analyze_launch_log.ps1 -LogPath "D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\logs\latest.log"

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\analyze_launch_log.ps1 -LogPath evidence\latest.log -Jar build\libs\taczpronehitbox-1.20.1-1.1.0.jar -OutFile evidence\analyze.txt
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [string]$LogPath = '',
    [string]$DebugLogPath = '',
    [string]$Jar = '',
    [string]$OutFile = ''
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0
$script:SkipCount = 0
$script:Checks = New-Object System.Collections.ArrayList
$script:ReportLines = New-Object System.Collections.ArrayList

$script:DefaultLogPath = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7\logs\latest.log'
$script:Separator = ('=' * 78)

function Out-Line {
    param([Parameter(Position = 0)][string]$Text = '')
    [void]$script:ReportLines.Add($Text)
    Write-Output $Text
}

function Cut-Text {
    param([string]$Text, [int]$MaxLength = 260)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    if ($Text.Length -le $MaxLength) { return $Text }
    return $Text.Substring(0, $MaxLength) + '...'
}

function Add-Check {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ''
    )
    switch ($Status) {
        'PASS' { $script:PassCount = $script:PassCount + 1 }
        'FAIL' { $script:FailCount = $script:FailCount + 1 }
        'WARN' { $script:WarnCount = $script:WarnCount + 1 }
        'SKIP' { $script:SkipCount = $script:SkipCount + 1 }
        default { throw ('invalid check status: ' + $Status) }
    }
    [void]$script:Checks.Add([pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail })
    $line = ('[{0}] {1}' -f $Status, $Name)
    if (-not [string]::IsNullOrEmpty($Detail)) { $line = $line + ' -- ' + $Detail }
    Out-Line $line
}

function Find-Lines {
    param(
        [string[]]$Lines,
        [string]$Pattern
    )
    $hits = New-Object System.Collections.ArrayList
    if ($null -eq $Lines) { return ,([object[]]@()) }
    $regex = New-Object System.Text.RegularExpressions.Regex($Pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $m = $regex.Match($Lines[$i])
        if ($m.Success) {
            [void]$hits.Add([pscustomobject]@{ LineNumber = ($i + 1); Line = $Lines[$i] })
        }
    }
    return ,([object[]]$hits.ToArray())
}

function Find-FatalForMod {
    param(
        [string[]]$Lines,
        [string]$ErrorPattern,
        [string]$ModPattern
    )
    $found = New-Object System.Collections.ArrayList
    $errorRegex = New-Object System.Text.RegularExpressions.Regex($ErrorPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $modRegex = New-Object System.Text.RegularExpressions.Regex($ModPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if (-not $errorRegex.IsMatch($Lines[$i])) { continue }
        $last = [Math]::Min($Lines.Count - 1, $i + 25)
        $contextHit = $false
        for ($j = $i; $j -le $last; $j++) {
            if ($modRegex.IsMatch($Lines[$j])) { $contextHit = $true; break }
        }
        if ($contextHit) {
            [void]$found.Add([pscustomobject]@{ LineNumber = ($i + 1); Line = $Lines[$i] })
        }
    }
    return ,([object[]]$found.ToArray())
}

function Get-JarVersion {
    param([string]$JarPath)
    if ([string]::IsNullOrEmpty($JarPath)) { return '' }
    if (-not (Test-Path -LiteralPath $JarPath -PathType Leaf)) { return '' }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
        try {
            $entry = $zip.GetEntry('META-INF/mods.toml')
            if ($null -eq $entry) { return '' }
            $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8)
            try { $text = $reader.ReadToEnd() } finally { $reader.Close() }
            $m = [regex]::Match($text, '(?m)^\s*version\s*=\s*"([^"]+)"')
            if ($m.Success) { return $m.Groups[1].Value.Trim() }
        } finally {
            $zip.Dispose()
        }
    } catch {
        return ''
    }
    return ''
}

function Show-Hits {
    param(
        [object[]]$Hits,
        [int]$MaxLines = 8,
        [string]$Indent = '        '
    )
    $limit = [Math]::Min($MaxLines, $Hits.Count)
    for ($i = 0; $i -lt $limit; $i++) {
        $hit = $Hits[$i]
        Out-Line ($Indent + 'L' + $hit.LineNumber + ': ' + (Cut-Text $hit.Line 300))
    }
    if ($Hits.Count -gt $limit) {
        Out-Line ($Indent + '... 还有 ' + ($Hits.Count - $limit) + ' 行未显示')
    }
}

# ------------------------------------------------------------------ load log
Out-Line $script:Separator
Out-Line 'TaCZ Prone Hitbox - 客户端启动日志分析 (analyze_launch_log.ps1)'
Out-Line $script:Separator

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = $script:DefaultLogPath
}
if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) {
    Out-Line ('[FAIL] 日志文件不存在: ' + $LogPath)
    Out-Line ('       请先运行 launch_test.ps1，或用 -LogPath 指定 latest.log。')
    if (-not [string]::IsNullOrEmpty($OutFile)) { Write-ReportFile $OutFile }
    exit 1
}
$LogPath = (Resolve-Path -LiteralPath $LogPath).Path
$logFile = Get-Item -LiteralPath $LogPath
$lines = @(Get-Content -LiteralPath $LogPath -Encoding UTF8)
$raw = [System.IO.File]::ReadAllText($LogPath, [System.Text.Encoding]::UTF8)

Out-Line ('日志: ' + $LogPath)
Out-Line ('大小: ' + $logFile.Length + ' 字节, 行数: ' + $lines.Count + ', 最后写入: ' + $logFile.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))
if ($lines.Count -eq 0) {
    Out-Line '[FAIL] 日志文件为空，无法分析。'
    exit 1
}

# debug.log (optional, contains mod discovery / mixin config details)
if ([string]::IsNullOrWhiteSpace($DebugLogPath)) {
    $candidate = Join-Path (Split-Path -Parent $LogPath) 'debug.log'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { $DebugLogPath = $candidate }
}
$debugLines = $null
if ((-not [string]::IsNullOrWhiteSpace($DebugLogPath)) -and (Test-Path -LiteralPath $DebugLogPath -PathType Leaf)) {
    $DebugLogPath = (Resolve-Path -LiteralPath $DebugLogPath).Path
    $debugLines = @(Get-Content -LiteralPath $DebugLogPath -Encoding UTF8)
    Out-Line ('调试日志: ' + $DebugLogPath + ' (' + $debugLines.Count + ' 行)')
} else {
    Out-Line '调试日志: 未找到（部分证据只在 debug.log 里，例如 mod 版本号）'
}
Out-Line ''

# ------------------------------------------------------------- session info
Out-Line '--- 会话信息 ---------------------------------------------------------'
$headerLine = $lines[0]
$logVersionName = ''
$forgeVersion = ''
$mcVersion = ''
$javaVersion = ''
$modLauncherVersion = ''
$m = [regex]::Match($headerLine, '--version,\s*([^,\]]+)')
if ($m.Success) { $logVersionName = $m.Groups[1].Value.Trim() }
$m = [regex]::Match($headerLine, '--fml\.forgeVersion,\s*([^,\]]+)')
if ($m.Success) { $forgeVersion = $m.Groups[1].Value.Trim() }
$m = [regex]::Match($headerLine, '--fml\.mcVersion,\s*([^,\]]+)')
if ($m.Success) { $mcVersion = $m.Groups[1].Value.Trim() }
$m = [regex]::Match($headerLine, '--fml\.mcpVersion,\s*([^,\]]+)')
if ($m.Success) { $mcpVersion = $m.Groups[1].Value.Trim() } else { $mcpVersion = '' }
$headProbeCount = [Math]::Min(6, $lines.Count)
for ($hi = 0; $hi -lt $headProbeCount; $hi++) {
    $probe = $lines[$hi]
    if (-not $modLauncherVersion) {
        $ml = [regex]::Match($probe, 'ModLauncher ([0-9][0-9A-Za-z\.\+\-]*?)(?:\+| starting)')
        if ($ml.Success) { $modLauncherVersion = $ml.Groups[1].Value.Trim() }
    }
    if (-not $javaVersion) {
        $j = [regex]::Match($probe, 'starting:\s*java version\s*([^;]+)')
        if ($j.Success) { $javaVersion = $j.Groups[1].Value.Trim() }
    }
}
$timeRx = New-Object System.Text.RegularExpressions.Regex('^\[([^\]]+)\]')
$firstTime = ''
$lastTime = ''
$tm = $timeRx.Match($lines[0])
if ($tm.Success) { $firstTime = $tm.Groups[1].Value }
$tm = $timeRx.Match($lines[$lines.Count - 1])
if ($tm.Success) { $lastTime = $tm.Groups[1].Value }
Out-Line ('游戏版本 : ' + $(if ($logVersionName) { $logVersionName } else { '(未识别)' }))
Out-Line ('MC / Forge: ' + $(if ($mcVersion) { $mcVersion } else { '?' }) + ' / ' + $(if ($forgeVersion) { $forgeVersion } else { '?' }))
Out-Line ('ModLauncher: ' + $(if ($modLauncherVersion) { $modLauncherVersion } else { '?' }) + ', Java: ' + $(if ($javaVersion) { $javaVersion } else { '?' }))
Out-Line ('日志时间 : ' + $(if ($firstTime) { $firstTime } else { '?' }) + '  ->  ' + $(if ($lastTime) { $lastTime } else { '?' }))
Out-Line ''

Out-Line '--- 检查项 -----------------------------------------------------------'

# --------------------------------------------------------------- 1) mod loaded
$modLoadRx = '\[taczpronehitbox/\]|\[TACZProneHitbox\]|taczpronehitbox\.mixins\.json|Found valid mod file taczpronehitbox'
$modLoadHits = Find-Lines -Lines $lines -Pattern $modLoadRx
if ($null -ne $debugLines) {
    $modHitsDebug = Find-Lines -Lines $debugLines -Pattern 'Found valid mod file taczpronehitbox|taczpronehitbox\.mixins\.json'
} else {
    $modHitsDebug = @()
}
if ($modLoadHits.Count -gt 0) {
    Add-Check -Name 'mod 加载 (taczpronehitbox)' -Status 'PASS' -Detail ('发现 ' + $modLoadHits.Count + ' 行本 mod 日志，首条 L' + $modLoadHits[0].LineNumber)
} elseif ($modHitsDebug.Count -gt 0) {
    Add-Check -Name 'mod 加载 (taczpronehitbox)' -Status 'PASS' -Detail ('debug.log 中 mod 文件被发现（latest.log 无本 mod 日志）')
} else {
    Add-Check -Name 'mod 加载 (taczpronehitbox)' -Status 'FAIL' -Detail '日志里没有 taczpronehitbox 的任何痕迹，mod 未加载或未安装'
}

# ---------------------------------------------------------------- 2) mod version
$jarVersion = Get-JarVersion -JarPath $Jar
$versionHits = New-Object System.Collections.ArrayList
if ($null -ne $debugLines) {
    $vHits = Find-Lines -Lines $debugLines -Pattern 'Found valid mod file (taczpronehitbox[^\s]+\.jar).*versions \{([^}]+)\}'
    foreach ($hit in $vHits) { [void]$versionHits.Add($hit) }
}
$jarNameHits = Find-Lines -Lines $lines -Pattern 'taczpronehitbox-1\.20\.1-([0-9][0-9A-Za-z\.\-]*)\.jar'
$versionFromJarName = ''
if ($jarNameHits.Count -gt 0) {
    $vm = [regex]::Match($jarNameHits[0].Line, 'taczpronehitbox-1\.20\.1-([0-9][0-9A-Za-z\.\-]*)\.jar')
    if ($vm.Success) { $versionFromJarName = $vm.Groups[1].Value }
}
$versionFromDebug = ''
if ($versionHits.Count -gt 0) {
    $vm = [regex]::Match($versionHits[0].Line, 'versions \{([^}]+)\}')
    if ($vm.Success) { $versionFromDebug = $vm.Groups[1].Value.Trim() }
}
$versionFound = ''
if ($versionFromDebug) { $versionFound = $versionFromDebug }
elseif ($versionFromJarName) { $versionFound = $versionFromJarName }

if ($jarVersion -and $versionFound) {
    if ($versionFound -eq $jarVersion) {
        Add-Check -Name 'mod 版本一致性' -Status 'PASS' -Detail ('日志与 jar 均为 ' + $jarVersion)
    } else {
        Add-Check -Name 'mod 版本一致性' -Status 'FAIL' -Detail ('日志版本 ' + $versionFound + ' 与 jar 版本 ' + $jarVersion + ' 不一致（可能装了旧 jar）')
    }
} elseif ($versionFound) {
    Add-Check -Name 'mod 版本' -Status 'PASS' -Detail ('版本 ' + $versionFound + '（INFO 日志通常不含版本号，来自 debug.log / 文件名）')
} elseif ($jarVersion) {
    Add-Check -Name 'mod 版本' -Status 'WARN' -Detail ('日志中未找到版本证据；-Jar 的版本是 ' + $jarVersion + '，请人工核对安装是否成功')
} else {
    Add-Check -Name 'mod 版本' -Status 'WARN' -Detail '无法从日志确定版本（可用 -Jar 指定 jar 以读取真实版本）'
}

# --------------------------------------------------- 3) mixin applied (audit)
$appliedHits = Find-Lines -Lines $lines -Pattern 'TaCZ EntityUtil mixin applied'
$notAppliedHits = Find-Lines -Lines $lines -Pattern 'TaCZ EntityUtil mixin NOT applied|EntityUtil mixin NOT applied'
$taczMissingHits = Find-Lines -Lines $lines -Pattern 'TaCZ is not loaded'
if ($appliedHits.Count -gt 0) {
    Add-Check -Name 'EntityUtil mixin applied (MixinAudit)' -Status 'PASS' -Detail (Cut-Text $appliedHits[0].Line 200)
} elseif ($notAppliedHits.Count -gt 0) {
    Add-Check -Name 'EntityUtil mixin applied (MixinAudit)' -Status 'FAIL' -Detail ('MixinAudit 报告注入失败: ' + (Cut-Text $notAppliedHits[0].Line 200))
} elseif ($taczMissingHits.Count -gt 0) {
    Add-Check -Name 'EntityUtil mixin applied (MixinAudit)' -Status 'FAIL' -Detail 'TaCZ 未加载，趴下命中接管不会生效（检查 TaCZ 1.1.8+ 是否安装）'
} else {
    Add-Check -Name 'EntityUtil mixin applied (MixinAudit)' -Status 'WARN' -Detail '未找到 MixinAudit 输出（mod 未加载 / 旧版本 / 审计未运行）'
}

# --------------------------------------------------------- 4) sprint lock init
$sprintLoadedHits = Find-Lines -Lines $lines -Pattern 'sprint lock loaded'
$sprintMigratedHits = Find-Lines -Lines $lines -Pattern 'sprint config migrated'
$legacySprintHits = Find-Lines -Lines $lines -Pattern 'SeamlessSprint'
$sprintErrorHits = Find-Lines -Lines $lines -Pattern '(TACZProneHitbox|taczpronehitbox).*(sprint).*(error|fail|exception)'
if ($sprintErrorHits.Count -gt 0) {
    Add-Check -Name 'sprint 初始化' -Status 'FAIL' -Detail (Cut-Text $sprintErrorHits[0].Line 220)
} elseif ($sprintLoadedHits.Count -gt 0) {
    $detail = Cut-Text $sprintLoadedHits[0].Line 220
    if ($sprintMigratedHits.Count -gt 0) { $detail = $detail + ' | 已从 seamlesssprint.properties 迁移' }
    Add-Check -Name 'sprint 初始化' -Status 'PASS' -Detail $detail
} elseif ($sprintMigratedHits.Count -gt 0) {
    Add-Check -Name 'sprint 初始化' -Status 'PASS' -Detail (Cut-Text $sprintMigratedHits[0].Line 200)
} elseif ($legacySprintHits.Count -gt 0) {
    Add-Check -Name 'sprint 初始化' -Status 'WARN' -Detail '只看到旧 SeamlessSprint 日志（1.1.0 应输出 sprint lock loaded，旧 jar 可能没卸掉）'
} else {
    Add-Check -Name 'sprint 初始化' -Status 'WARN' -Detail '未找到 sprint 初始化日志（1.0.x 无此功能，或 SprintLockClient.init() 未接线）'
}

# ----------------------------------------------------------- 5) network channel
$netHits = Find-Lines -Lines $lines -Pattern 'taczpronehitbox.*(channel|network|handshake|presence|server.hello)|\[TACZProneHitbox\].*(channel|network|handshake|presence)'
$netDebugHits = @()
if ($null -ne $debugLines) {
    $netDebugHits = Find-Lines -Lines $debugLines -Pattern "Channel 'taczpronehitbox:|Registering.*taczpronehitbox.*channel"
}
$netErrorHits = Find-Lines -Lines $lines -Pattern 'taczpronehitbox.*(channel|network|handshake).*(fail|error|exception|refus|not registered)'
if ($netErrorHits.Count -gt 0) {
    Add-Check -Name '网络通道 (server-presence)' -Status 'FAIL' -Detail (Cut-Text $netErrorHits[0].Line 220)
} elseif ($netHits.Count -gt 0) {
    Add-Check -Name '网络通道 (server-presence)' -Status 'PASS' -Detail (Cut-Text $netHits[0].Line 200)
} elseif ($netDebugHits.Count -gt 0) {
    Add-Check -Name '网络通道 (server-presence)' -Status 'PASS' -Detail (Cut-Text $netDebugHits[0].Line 200)
} else {
    Add-Check -Name '网络通道 (server-presence)' -Status 'WARN' -Detail '未找到通道注册日志（只在启动、未连接服务器时可能不打印；1.1.0 若有意不写 INFO 日志可忽略此项）'
}

# ------------------------------------------- 6) no fatal mixin/injection (ours)
$fatalRx = 'MixinApplyError|InvalidInjectionException|MixinTransformerError|NoSuchMethodError|ExceptionInInitializerError|NoClassDefFoundError|InjectionError|MixinException|Mixin apply failed'
$modRx = 'taczpronehitbox|EntityUtilMixin|tph\$bodyHit|tph\$widenSearch|com\.li\.taczpronehitbox'
$modFatalHits = Find-FatalForMod -Lines $lines -ErrorPattern $fatalRx -ModPattern $modRx
if ($modFatalHits.Count -eq 0) {
    Add-Check -Name '无致命 mixin/注入错误（涉及 taczpronehitbox）' -Status 'PASS' -Detail '未发现与本 mod 相关的 MixinApplyError / InvalidInjectionException / MixinTransformerError / NoSuchMethodError / ExceptionInInitializerError'
} else {
    Add-Check -Name '无致命 mixin/注入错误（涉及 taczpronehitbox）' -Status 'FAIL' -Detail ('发现 ' + $modFatalHits.Count + ' 处与本 mod 相关的注入错误')
    Show-Hits -Hits $modFatalHits -MaxLines 6
}
$allFatalHits = Find-Lines -Lines $lines -Pattern $fatalRx
if ($allFatalHits.Count -gt $modFatalHits.Count) {
    $otherFatal = $allFatalHits.Count - $modFatalHits.Count
    if ($otherFatal -gt 0) {
        Out-Line ('       提示: 日志中另有 ' + $otherFatal + ' 行非本 mod 的加载/注入错误（不一定致命，供参考，首条 L' + $allFatalHits[0].LineNumber + '）')
    }
}

# ----------------------------------------------------------------- 7) crash check
$crashRx = '#{0,1}@!@# Game crashed|A fatal error has been detected|Minecraft Crash Report|The game crashed whilst|Watching Server thread crashed|Exception in thread "main"|Crash report saved to|Game crashed'
$crashHits = Find-Lines -Lines $lines -Pattern $crashRx
$crashReportDir = Join-Path (Split-Path -Parent (Split-Path -Parent $LogPath)) 'crash-reports'
$freshCrashReports = @()
if (Test-Path -LiteralPath $crashReportDir -PathType Container) {
    $sessionStart = $logFile.LastWriteTime.AddMinutes(-30)
    $freshCrashReports = @(Get-ChildItem -LiteralPath $crashReportDir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $sessionStart })
}
if ($crashHits.Count -gt 0) {
    Add-Check -Name '无 crash' -Status 'FAIL' -Detail ('日志包含 crash 标记 ' + $crashHits.Count + ' 行')
    Show-Hits -Hits $crashHits -MaxLines 5
} elseif ($freshCrashReports.Count -gt 0) {
    Add-Check -Name '无 crash' -Status 'FAIL' -Detail ('发现 ' + $freshCrashReports.Count + ' 个新的 crash-reports 文件: ' + (($freshCrashReports | ForEach-Object { $_.Name }) -join ', '))
} else {
    Add-Check -Name '无 crash' -Status 'PASS' -Detail '无 crash 标记、无新 crash-reports 文件'
}

# --------------------------------------------------------- 8) reached title
$renderHits = Find-Lines -Lines $lines -Pattern 'Backend library: LWJGL version'
$soundHits = Find-Lines -Lines $lines -Pattern 'Sound engine started'
$openalHits = Find-Lines -Lines $lines -Pattern 'OpenAL initialized'
$atlasHits = Find-Lines -Lines $lines -Pattern 'Created:\s+\d+x\d+.*atlas'
$settingUserHits = Find-Lines -Lines $lines -Pattern 'Setting user:'
$reloadHits = Find-Lines -Lines $lines -Pattern 'Reloading ResourceManager'
$titleReached = ($soundHits.Count -gt 0) -or ($openalHits.Count -gt 0) -or ($atlasHits.Count -ge 3)
$renderReady = ($renderHits.Count -gt 0)
if ($renderReady -and $titleReached) {
    $detail = '渲染初始化 + 标题界面特征齐备 (Backend=' + $renderHits.Count + ', Sound=' + $soundHits.Count + ', OpenAL=' + $openalHits.Count + ', atlas=' + $atlasHits.Count + ')'
    Add-Check -Name '到达主界面' -Status 'PASS' -Detail $detail
} else {
    $missing = New-Object System.Collections.ArrayList
    if (-not $renderReady) { [void]$missing.Add('Backend library') }
    if ($soundHits.Count -eq 0) { [void]$missing.Add('Sound engine started') }
    if ($openalHits.Count -eq 0 -and $atlasHits.Count -lt 3) { [void]$missing.Add('OpenAL/atlas') }
    Add-Check -Name '到达主界面' -Status 'FAIL' -Detail ('未到达标题界面，缺少: ' + (($missing.ToArray()) -join ', ') + ' (当前日志可能在加载/崩溃阶段被截断)')
}
if ($settingUserHits.Count -gt 0 -or $reloadHits.Count -gt 0) {
    Out-Line ('       辅助证据: Setting user=' + $settingUserHits.Count + ', Reloading ResourceManager=' + $reloadHits.Count)
}

# --------------------------------------------- 9) TaCZ dependency / version
$taczVersion = ''
$taczDetectedHits = Find-Lines -Lines $lines -Pattern 'TaCZ detected:\s*([0-9][0-9A-Za-z\.\-]*)'
if ($taczDetectedHits.Count -gt 0) {
    $tm2 = [regex]::Match($taczDetectedHits[0].Line, 'TaCZ detected:\s*([0-9][0-9A-Za-z\.\-]*)')
    if ($tm2.Success) { $taczVersion = $tm2.Groups[1].Value }
}
$taczJarHits = Find-Lines -Lines $lines -Pattern 'tacz-1\.20\.1-([0-9][0-9A-Za-z\.\-]*)\.jar'
if (-not $taczVersion -and $null -ne $debugLines) {
    $taczJarHits = Find-Lines -Lines $debugLines -Pattern 'tacz-1\.20\.1-([0-9][0-9A-Za-z\.\-]*)\.jar'
}
if (-not $taczVersion) {
    foreach ($hit in $taczJarHits) {
        $tm2 = [regex]::Match($hit.Line, 'tacz-1\.20\.1-([0-9][0-9A-Za-z\.\-]*)\.jar')
        if ($tm2.Success) { $taczVersion = $tm2.Groups[1].Value; break }
    }
}
$taczMixinHits = Find-Lines -Lines $lines -Pattern 'com\.tacz\.guns|TaCZ EntityUtil|tacz:handshake'
if ($taczVersion) {
    Add-Check -Name 'TaCZ 依赖' -Status 'PASS' -Detail ('检测到 TaCZ ' + $taczVersion + '（需 1.1.8+）')
} elseif ($taczMixinHits.Count -gt 0) {
    Add-Check -Name 'TaCZ 依赖' -Status 'PASS' -Detail '日志出现 TaCZ 相关类/通道，TaCZ 已加载（版本未直接识别）'
} else {
    Add-Check -Name 'TaCZ 依赖' -Status 'WARN' -Detail '未找到 TaCZ 证据（本 mod 强制依赖 TaCZ 1.1.8+，缺失会导致加载失败）'
}

# --------------------------------- 10) TaCZ addon warnings / conflict list
$relatedRx = 'taczaddon|tacz-tweaks|tacztweaks|taczlabs|gd656|tacz_optimization|taczaccel|tacz-leveling|taczgunssync'
$relatedAll = Find-Lines -Lines $lines -Pattern $relatedRx
$relatedInteresting = New-Object System.Collections.ArrayList
foreach ($hit in $relatedAll) {
    if ($hit.Line -match '(?i)\[[^\]]*/(WARN|ERROR)\]|conflict|incompatible|skipped|does not exist|does not belong|not found|failed|mixin.*(fail|error|conflict|priority)') {
        [void]$relatedInteresting.Add($hit)
    }
}
$hitboxConflictRaw = Find-Lines -Lines $lines -Pattern '(getHitResult|EntityUtil|m_82400_|AABB;m_82400_).*(mixin|conflict|WARN|ERROR|skip|priority)'
$hitboxConflictList = New-Object System.Collections.ArrayList
foreach ($hit in $hitboxConflictRaw) {
    if ($hit.Line -notmatch 'taczpronehitbox') { [void]$hitboxConflictList.Add($hit) }
}
$hitboxConflictHits = [object[]]$hitboxConflictList.ToArray()
if ($relatedInteresting.Count -gt 0 -or $hitboxConflictHits.Count -gt 0) {
    Add-Check -Name 'tacz 相关 mod 警告/冲突' -Status 'WARN' -Detail ('taczaddon/tacz-tweaks/taczlabs/gd656 等共 ' + $relatedInteresting.Count + ' 行告警/冲突线索（详见下方列表）')
    if ($relatedInteresting.Count -gt 0) {
        Out-Line '       TaCZ 相关 mod 的 WARN/ERROR/mixin 行:'
        Show-Hits -Hits ($relatedInteresting.ToArray()) -MaxLines 15
    }
    if ($hitboxConflictHits.Count -gt 0) {
        Out-Line '       可能影响 EntityUtil.getHitResult / AABB.inflate 的 mixin 行:'
        Show-Hits -Hits $hitboxConflictHits -MaxLines 10
    }
} else {
    Add-Check -Name 'tacz 相关 mod 警告/冲突' -Status 'PASS' -Detail '未发现 taczaddon/tacz-tweaks/taczlabs/gd656 相关告警'
}

# -------------------------------------------- 11) all ERROR lines (informational)
$errorHits = Find-Lines -Lines $lines -Pattern '\[[^\]]*/(ERROR|FATAL)\]'
if ($errorHits.Count -gt 0) {
    Out-Line ''
    Out-Line ('--- 日志 ERROR 行（' + $errorHits.Count + ' 行，供排查参考）---')
    Show-Hits -Hits $errorHits -MaxLines 12
} else {
    Out-Line ''
    Out-Line '--- 日志无 ERROR 行 ---'
}

# ------------------------------------------------------------------ summary
Out-Line ''
Out-Line $script:Separator
$overallPass = ($script:FailCount -eq 0)
$overallText = 'FAIL'
if ($overallPass) { $overallText = 'PASS' }
Out-Line ('检查汇总: PASS = ' + $script:PassCount + ', FAIL = ' + $script:FailCount + ', WARN = ' + $script:WarnCount + ', SKIP = ' + $script:SkipCount)
Out-Line ('总体结果: ' + $overallText)
if (-not $overallPass) {
    Out-Line '失败的检查项:'
    foreach ($check in $script:Checks) {
        if ($check.Status -eq 'FAIL') {
            Out-Line ('  - ' + $check.Name + ': ' + $check.Detail)
        }
    }
} else {
    Out-Line '所有阻断性检查项通过（WARN 不阻断，请人工确认）。'
}
Out-Line $script:Separator

if (-not [string]::IsNullOrEmpty($OutFile)) {
    $outDir = Split-Path -Parent $OutFile
    if ($outDir -and -not (Test-Path -LiteralPath $outDir -PathType Container)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($OutFile, [string[]]$script:ReportLines.ToArray(), $utf8)
    Write-Output ('报告已写入: ' + $OutFile)
}

if ($overallPass) { exit 0 } else { exit 1 }
