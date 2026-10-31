#requires -Version 5.1
<#
.SYNOPSIS
    在用户的 PCL Forge 客户端实例里安装 TaCZ Prone Hitbox，启动一次真实游戏并在标题界面自动取证。

.DESCRIPTION
    完整流程（默认）：
      1. 校验参数与路径（版本目录 / 启动脚本 / 新 jar / TaCZ 是否已安装）；
      2. 备份到项目内 install-backup\<时间戳>\：
           - 旧 seamlesssprint*.jar（移到备份目录，不是删除）
           - config\seamlesssprint.properties
           - 当前 mods 文件清单 mods-list-before.txt
           - 旧 taczpronehitbox*.jar（若存在）
      3. 复制新 jar 到 版本目录\mods\；
      4. 用 cmd /c 启动 PCL 生成的 LatestLaunch.bat，stdout/stderr 重定向到
         evidence\launch-stdout.log；
      5. 每 2 秒轮询 版本目录\logs\latest.log，等待标题界面特征
         （Backend library: LWJGL / OpenAL initialized / Sound engine started / 图集 Created:）；
      6. 到达标题界面后再稳定 10 秒（期间检查崩溃/注入错误）；
      7. 只 kill 命令行里包含该版本目录的 java.exe（Get-CimInstance Win32_Process 精确匹配），
         无法枚举进程时退回"只结束本脚本启动的 cmd 进程树"，不会碰其他 java 进程；
      8. 复制 latest.log / debug.log 关键片段与 stdout 到 evidence\；
         自动调用 tools\analyze_launch_log.ps1 做日志 PASS/FAIL 分析；
      9. 打印 PASS/FAIL 与退出码。

    本脚本不删除任何用户文件：旧 jar / 配置只会"移动"到项目内的 install-backup 目录，
    可用 -Rollback 一键恢复。

.PARAMETER Jar
    要安装的 mod jar。默认取 build\libs 或 dist 下最新的 taczpronehitbox-*.jar。

.PARAMETER VersionDir
    客户端版本目录（含 mods、config、logs 的实例目录），默认用户当前的 TACZ-先锋-0.7。

.PARAMETER LauncherBat
    PCL 生成的启动脚本。默认根据 VersionDir 推导：<.minecraft 上层>\PCL\LatestLaunch.bat。

.PARAMETER TimeoutSeconds
    等待标题界面的超时时间，默认 180 秒。

.PARAMETER StabilitySeconds
    到达标题界面后的稳定观察时间，默认 10 秒。

.PARAMETER NoInstall
    跳过安装/备份步骤，直接启动游戏（用于已经手动装好 jar 的情况）。不会写用户实例。

.PARAMETER Rollback
    回滚模式：从最近的 install-backup 恢复（移走新 jar、放回旧 seamlesssprint jar 与配置）。
    -Rollback 可与 -BackupDir 搭配指定某一次备份。

.PARAMETER BackupDir
    配合 -Rollback：指定要恢复的备份目录（默认 install-backup 下最新一份）。

.PARAMETER BackupRoot
    备份根目录，默认 项目根\install-backup（自测时可指向项目内临时目录）。

.PARAMETER EvidenceRoot
    证据根目录，默认 项目根\evidence。

.PARAMETER DryRun
    只做校验并打印计划，不复制/移动/启动任何东西。

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\launch_test.ps1

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\launch_test.ps1 -Jar build\libs\taczpronehitbox-1.20.1-1.1.0.jar

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\launch_test.ps1 -DryRun

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File tools\launch_test.ps1 -Rollback

.NOTES
    退出码：0 = PASS；1 = FAIL（启动/分析未通过）；2 = 参数/环境错误；3 = 该版本游戏已在运行。
    需要以有权限写入 D:\我的世界 的会话运行（Lead 用 danger-full-access 执行）。
#>
[CmdletBinding()]
param(
    [string]$Jar = '',
    [string]$VersionDir = 'D:\我的世界\先锋\.minecraft\versions\TACZ-先锋-0.7',
    [string]$LauncherBat = '',
    [int]$TimeoutSeconds = 180,
    [int]$StabilitySeconds = 10,
    [switch]$NoInstall,
    [switch]$Rollback,
    [string]$BackupDir = '',
    [string]$BackupRoot = '',
    [string]$EvidenceRoot = '',
    [switch]$DryRun
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = Split-Path -Parent $PSScriptRoot
$script:Timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:ReportLines = New-Object System.Collections.ArrayList
$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0

$script:CrashRx = '#{0,1}@!@# Game crashed|A fatal error has been detected|Minecraft Crash Report|The game crashed whilst|Watching Server thread crashed|Exception in thread "main"|Crash report saved to'
$script:OurMixinErrRx = '(MixinApplyError|InvalidInjectionException|MixinTransformerError|InjectionError|MixinException).*(taczpronehitbox|EntityUtilMixin|tph)|(taczpronehitbox|EntityUtilMixin).*(MixinApplyError|InvalidInjectionException|MixinTransformerError)'
$script:TitleRx = 'Sound engine started|OpenAL initialized|Created:\s+\d+x\d+.*atlas'
$script:RenderRx = 'Backend library: LWJGL version'

function Say {
    param([Parameter(Position = 0)][string]$Text = '')
    [void]$script:ReportLines.Add($Text)
    Write-Host $Text
}

function Say-Sep {
    Say ('=' * 78)
}

function Say-Section {
    param([string]$Title)
    $dashCount = 72 - $Title.Length
    if ($dashCount -lt 2) { $dashCount = 2 }
    Say ''
    Say ('--- ' + $Title + ' ' + ('-' * $dashCount))
}

function Add-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Detail = ''
    )
    switch ($Status) {
        'PASS' { $script:PassCount = $script:PassCount + 1 }
        'FAIL' { $script:FailCount = $script:FailCount + 1 }
        'WARN' { $script:WarnCount = $script:WarnCount + 1 }
        'SKIP' { }
        default { throw ('invalid status: ' + $Status) }
    }
    $line = ('[{0}] {1}' -f $Status, $Name)
    if (-not [string]::IsNullOrEmpty($Detail)) { $line = $line + ' -- ' + $Detail }
    Say $line
}

function Get-NormalizedPath {
    param([string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        $full = $Path
    } else {
        $full = Join-Path (Get-Location).Path $Path
    }
    $full = [System.IO.Path]::GetFullPath($full)
    $sep = [string][System.IO.Path]::DirectorySeparatorChar
    if ($full.Length -gt $sep.Length -and $full.EndsWith($sep)) {
        $root = [System.IO.Path]::GetPathRoot($full)
        if ($full.Length -gt $root.Length) { $full = $full.Substring(0, $full.Length - 1) }
    }
    return $full
}

function Write-TextFile {
    param([string]$Path, [string[]]$Lines)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $utf8 = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllLines($Path, [string[]]$Lines, $utf8)
}

function Get-FileSha256 {
    param([string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash.ToUpperInvariant()
}

function Copy-FileVerified {
    param([string]$SourcePath, [string]$DestinationPath)
    $dir = Split-Path -Parent $DestinationPath
    if ($dir -and -not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    Copy-Item -LiteralPath $SourcePath -Destination $DestinationPath -Force -ErrorAction Stop
    $srcHash = Get-FileSha256 -Path $SourcePath
    $dstHash = Get-FileSha256 -Path $DestinationPath
    if ($srcHash -ne $dstHash) { throw ('复制后哈希不一致: ' + $DestinationPath) }
    return $dstHash
}

function Move-FileToBackup {
    param([string]$OriginalPath, [string]$BackupModsDir, [string]$Reason)
    $name = Split-Path -Leaf $OriginalPath
    if (-not (Test-Path -LiteralPath $BackupModsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $BackupModsDir -Force | Out-Null
    }
    $destPath = Join-Path $BackupModsDir $name
    if (Test-Path -LiteralPath $destPath -PathType Leaf) {
        $existingHash = Get-FileSha256 -Path $destPath
        $origHash = Get-FileSha256 -Path $OriginalPath
        if ($existingHash -eq $origHash) {
            Remove-Item -LiteralPath $OriginalPath -Force -ErrorAction Stop
            return [pscustomobject]@{ OriginalPath = $OriginalPath; BackupPath = $destPath; Sha256 = $origHash; Size = (Get-Item -LiteralPath $destPath).Length; Reason = $Reason }
        }
        $suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
        $destPath = Join-Path $BackupModsDir ($name + '.' + $suffix)
    }
    $hash = Copy-FileVerified -SourcePath $OriginalPath -DestinationPath $destPath
    $size = (Get-Item -LiteralPath $destPath).Length
    Remove-Item -LiteralPath $OriginalPath -Force -ErrorAction Stop
    return [pscustomobject]@{ OriginalPath = $OriginalPath; BackupPath = $destPath; Sha256 = $hash; Size = $size; Reason = $Reason }
}

function Get-JarInfo {
    param([string]$JarPath)
    $info = [pscustomobject]@{
        Valid = $false
        Version = ''
        HasManifest = $false
        HasModsToml = $false
        HasMixinsJson = $false
        MixinConfigs = ''
        ModIdFound = $false
        EntryCount = 0
        Error = ''
    }
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
        try {
            $info.EntryCount = $zip.Entries.Count
            $manifestEntry = $zip.GetEntry('META-INF/MANIFEST.MF')
            $modsEntry = $zip.GetEntry('META-INF/mods.toml')
            $mixinsEntry = $zip.GetEntry('taczpronehitbox.mixins.json')
            $info.HasManifest = ($null -ne $manifestEntry)
            $info.HasModsToml = ($null -ne $modsEntry)
            $info.HasMixinsJson = ($null -ne $mixinsEntry)
            if ($null -ne $manifestEntry) {
                $reader = New-Object System.IO.StreamReader($manifestEntry.Open(), [System.Text.Encoding]::UTF8)
                try { $manifestText = $reader.ReadToEnd() } finally { $reader.Close() }
                if ($manifestText -match 'MixinConfigs:\s*([^\r\n]+)') {
                    $info.MixinConfigs = $Matches[1].Trim()
                }
            }
            if ($null -ne $modsEntry) {
                $reader2 = New-Object System.IO.StreamReader($modsEntry.Open(), [System.Text.Encoding]::UTF8)
                try { $modsText = $reader2.ReadToEnd() } finally { $reader2.Close() }
                $mv = [regex]::Match($modsText, '(?m)^\s*version\s*=\s*"([^"]+)"')
                if ($mv.Success) { $info.Version = $mv.Groups[1].Value.Trim() }
                if ($modsText -match 'modId\s*=\s*"taczpronehitbox"') { $info.ModIdFound = $true }
            }
            $info.Valid = ($info.HasManifest -and $info.HasModsToml -and $info.HasMixinsJson -and $info.ModIdFound -and ($info.MixinConfigs -like '*taczpronehitbox.mixins.json*'))
        } finally {
            $zip.Dispose()
        }
    } catch {
        $info.Error = $_.Exception.Message
    }
    return $info
}

function Get-DefaultJar {
    $candidates = New-Object System.Collections.ArrayList
    $dirs = @((Join-Path $script:ProjectRoot 'build\libs'), (Join-Path $script:ProjectRoot 'dist'))
    foreach ($dir in $dirs) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -Filter 'taczpronehitbox-*.jar' -File -ErrorAction SilentlyContinue)) {
            if ($f.Name -notlike '*-sources.jar') { [void]$candidates.Add($f) }
        }
    }
    if ($candidates.Count -eq 0) { return '' }
    $sorted = @($candidates.ToArray() | Sort-Object -Property LastWriteTime -Descending)
    return $sorted[0].FullName
}

function Get-DefaultLauncherBat {
    param([string]$VersionDirPath)
    $versionsDir = Split-Path -Parent $VersionDirPath
    $mcDir = Split-Path -Parent $versionsDir
    $baseDir = Split-Path -Parent $mcDir
    return (Join-Path $baseDir 'PCL\LatestLaunch.bat')
}

function Get-LauncherJavaExe {
    param([string]$LauncherBatPath)
    try {
        $text = [System.IO.File]::ReadAllText($LauncherBatPath, [System.Text.Encoding]::UTF8)
        $m = [regex]::Match($text, '"([^"\r\n]*[jJ]ava[wW]?\.exe)"')
        if ($m.Success) { return $m.Groups[1].Value }
    } catch {
    }
    return ''
}

function Get-GameJavaInfo {
    param([string]$VersionDirToMatch)
    $result = [pscustomobject]@{
        Available = $false
        Matches = @()
        Error = ''
    }
    $procs = $null
    try {
        $procs = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='java.exe'" -ErrorAction Stop)
        $result.Available = $true
    } catch {
        $result.Error = $_.Exception.Message
        try {
            $procs = @(Get-WmiObject -Class Win32_Process -Filter "Name='java.exe'" -ErrorAction Stop)
            $result.Available = $true
            $result.Error = ''
        } catch {
            $result.Error = $_.Exception.Message
            return $result
        }
    }
    $matched = New-Object System.Collections.ArrayList
    foreach ($proc in $procs) {
        $cmdLine = ''
        try { $cmdLine = [string]$proc.CommandLine } catch { $cmdLine = '' }
        if ([string]::IsNullOrEmpty($cmdLine)) { continue }
        if (Test-GameCommandLine -CommandLine $cmdLine -VersionDirToMatch $VersionDirToMatch) {
            [void]$matched.Add([pscustomobject]@{ ProcessId = [int]$proc.ProcessId; CommandLine = $cmdLine })
        }
    }
    $result.Matches = [object[]]$matched.ToArray()
    return $result
}

function Test-GameCommandLine {
    param([string]$CommandLine, [string]$VersionDirToMatch)
    $escaped = [regex]::Escape($VersionDirToMatch)
    if ($CommandLine -match ('--gameDir\s+"?' + $escaped)) { return $true }
    if (($CommandLine -match 'BootstrapLauncher|--launchTarget\s+forgeclient') -and
        ($CommandLine.IndexOf($VersionDirToMatch, [System.StringComparison]::OrdinalIgnoreCase) -ge 0)) {
        return $true
    }
    return $false
}

function Read-LogTail {
    param([string]$Path, [int]$Count = 500)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        try {
            $lines = @(Get-Content -LiteralPath $Path -Tail $Count -Encoding UTF8 -ErrorAction Stop)
            return ,([string[]]$lines)
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    return ,([string[]]@())
}

function Get-FreshLogLines {
    param([string]$Path, [int]$TailCount, [int]$SkipFirstLines)
    if ($SkipFirstLines -le 0) {
        return ,(Read-LogTail -Path $Path -Count $TailCount)
    }
    $all = @()
    try { $all = @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction Stop) } catch { return ,([string[]]@()) }
    if ($all.Count -le $SkipFirstLines) { return ,([string[]]@()) }
    $fresh = New-Object System.Collections.ArrayList
    for ($i = $SkipFirstLines; $i -lt $all.Count; $i++) { [void]$fresh.Add($all[$i]) }
    $arr = @($fresh.ToArray())
    if ($arr.Count -gt $TailCount) { $arr = @($arr[($arr.Count - $TailCount)..($arr.Count - 1)]) }
    return ,([string[]]$arr)
}

function Find-FatalLines {
    param([string[]]$Lines)
    $hits = New-Object System.Collections.ArrayList
    if ($null -eq $Lines) { return ,([object[]]@()) }
    foreach ($line in $Lines) {
        if ($line -match $script:CrashRx) {
            [void]$hits.Add($line)
        } elseif ($line -match $script:OurMixinErrRx) {
            [void]$hits.Add($line)
        }
    }
    return ,([object[]]$hits.ToArray())
}

function Test-TitleScreen {
    param([string[]]$Lines)
    $sound = 0
    $openal = 0
    $atlas = 0
    foreach ($line in $Lines) {
        if ($line -match 'Sound engine started') { $sound = $sound + 1 }
        elseif ($line -match 'OpenAL initialized') { $openal = $openal + 1 }
        elseif ($line -match 'Created:\s+\d+x\d+.*atlas') { $atlas = $atlas + 1 }
    }
    if ($sound -gt 0) { return $true }
    if ($openal -gt 0) { return $true }
    if ($atlas -ge 3) { return $true }
    return $false
}

function Stop-StartedGame {
    param([string]$VersionDirToMatch, [int]$CmdProcessId)
    $out = [pscustomobject]@{
        Method = ''
        KilledPids = @()
        Warnings = @()
        Errors = @()
        Remaining = @()
        TreeKillAttempted = $false
        TreeKillExitCode = -1
    }
    $killed = New-Object System.Collections.ArrayList
    $warnings = New-Object System.Collections.ArrayList
    $errors = New-Object System.Collections.ArrayList
    $info = Get-GameJavaInfo -VersionDirToMatch $VersionDirToMatch
    if ($info.Available) {
        $out.Method = 'Get-CimInstance Win32_Process + CommandLine 精确匹配'
        foreach ($match in @($info.Matches)) {
            try {
                Stop-Process -Id $match.ProcessId -Force -ErrorAction Stop
                [void]$killed.Add($match.ProcessId)
            } catch {
                [void]$errors.Add('PID ' + $match.ProcessId + ': ' + $_.Exception.Message)
            }
        }
    } else {
        [void]$warnings.Add('无法枚举 Win32_Process（' + $info.Error + '），跳过按命令行精确匹配，改用进程树兜底')
    }
    Start-Sleep -Milliseconds 1000
    $info2 = Get-GameJavaInfo -VersionDirToMatch $VersionDirToMatch
    if ($info2.Available -and $info2.Matches.Count -gt 0) {
        foreach ($match in @($info2.Matches)) {
            if ($killed -contains $match.ProcessId) { continue }
            try {
                Stop-Process -Id $match.ProcessId -Force -ErrorAction Stop
                [void]$killed.Add($match.ProcessId)
            } catch {
                [void]$warnings.Add('第二次尝试结束 PID ' + $match.ProcessId + ' 失败: ' + $_.Exception.Message)
            }
        }
    }
    if ($CmdProcessId -gt 0) {
        $out.TreeKillAttempted = $true
        $treeText = ''
        try {
            $treeText = (& taskkill.exe /PID $CmdProcessId /T /F 2>&1 | Out-String)
            $out.TreeKillExitCode = $LASTEXITCODE
        } catch {
            $treeText = $_.Exception.Message
        }
        if (-not [string]::IsNullOrWhiteSpace($treeText)) {
            [void]$warnings.Add('taskkill 进程树输出: ' + $treeText.Trim())
        }
    }
    Start-Sleep -Milliseconds 800
    $info3 = Get-GameJavaInfo -VersionDirToMatch $VersionDirToMatch
    if ($info3.Available) {
        $out.Remaining = @($info3.Matches)
    } else {
        [void]$warnings.Add('结束清理后仍无法枚举进程，无法确认游戏是否已退出')
    }
    $out.KilledPids = [object[]]$killed.ToArray()
    $out.Warnings = [object[]]$warnings.ToArray()
    $out.Errors = [object[]]$errors.ToArray()
    return $out
}

function Install-ModJar {
    param(
        [string]$JarPath,
        [string]$JarVersion,
        [string]$VersionDirPath,
        [string]$ModsDir,
        [string]$ConfigDir,
        [string]$BackupRootPath
    )
    $newJarName = Split-Path -Leaf $JarPath
    $newJarHash = Get-FileSha256 -Path $JarPath
    $newJarSize = (Get-Item -LiteralPath $JarPath).Length
    $backupPath = Join-Path $BackupRootPath $script:Timestamp
    if (Test-Path -LiteralPath $backupPath) {
        $backupPath = $backupPath + '-' + [guid]::NewGuid().ToString('N').Substring(0, 4)
    }
    $removedModsDir = Join-Path $backupPath 'removed-mods'
    $configBackupDir = Join-Path $backupPath 'config'
    New-Item -ItemType Directory -Path $removedModsDir -Force | Out-Null
    New-Item -ItemType Directory -Path $configBackupDir -Force | Out-Null
    Say ('备份目录: ' + $backupPath)

    $modsFiles = @(Get-ChildItem -LiteralPath $ModsDir -File -ErrorAction Stop | Sort-Object -Property Name)
    $modsListLines = New-Object System.Collections.ArrayList
    [void]$modsListLines.Add('# mods list before install - generated by launch_test.ps1 at ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    [void]$modsListLines.Add('# count: ' + $modsFiles.Count)
    [void]$modsListLines.Add('# name | size bytes')
    foreach ($f in $modsFiles) { [void]$modsListLines.Add($f.Name + ' | ' + $f.Length) }
    Write-TextFile -Path (Join-Path $backupPath 'mods-list-before.txt') -Lines ([string[]]$modsListLines.ToArray())
    Say ('mods 清单已备份: ' + $modsFiles.Count + ' 个文件 -> mods-list-before.txt')

    $backedUpConfigs = New-Object System.Collections.ArrayList
    $configCandidates = New-Object System.Collections.ArrayList
    [void]$configCandidates.Add('seamlesssprint.properties')
    foreach ($f in @(Get-ChildItem -LiteralPath $ConfigDir -File -Filter 'taczpronehitbox*.toml' -ErrorAction SilentlyContinue)) {
        [void]$configCandidates.Add($f.Name)
    }
    foreach ($name in @($configCandidates.ToArray())) {
        $src = Join-Path $ConfigDir $name
        if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
        $dst = Join-Path $configBackupDir $name
        $hash = Copy-FileVerified -SourcePath $src -DestinationPath $dst
        [void]$backedUpConfigs.Add([pscustomobject]@{ OriginalPath = $src; BackupPath = $dst; Sha256 = $hash })
        Say ('已备份配置: config\' + $name)
    }

    $removedMods = New-Object System.Collections.ArrayList
    $removeCandidates = New-Object System.Collections.ArrayList
    foreach ($f in @(Get-ChildItem -LiteralPath $ModsDir -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -match '(?i)^seamlesssprint.*\.jar$') {
            [void]$removeCandidates.Add($f)
        } elseif (($f.Name -match '(?i)^taczpronehitbox.*\.jar$') -and ($f.Name -ne $newJarName)) {
            [void]$removeCandidates.Add($f)
        }
    }
    foreach ($f in @($removeCandidates.ToArray())) {
        $reason = 'legacy sprint mod replaced by integrated sprint feature'
        if ($f.Name -match '(?i)^taczpronehitbox') { $reason = 'old version of this mod' }
        $rec = Move-FileToBackup -OriginalPath $f.FullName -BackupModsDir $removedModsDir -Reason $reason
        [void]$removedMods.Add($rec)
        Say ('已移出 mods 并备份: ' + $f.Name + ' (' + $reason + ')')
    }

    $destJar = Join-Path $ModsDir $newJarName
    $alreadyInstalled = $false
    if (Test-Path -LiteralPath $destJar -PathType Leaf) {
        $existingHash = Get-FileSha256 -Path $destJar
        if ($existingHash -eq $newJarHash) {
            $alreadyInstalled = $true
            Say ('目标 jar 已存在且 SHA256 一致，跳过复制: ' + $newJarName)
        } else {
            $rec = Move-FileToBackup -OriginalPath $destJar -BackupModsDir $removedModsDir -Reason 'replaced by newly built jar'
            [void]$removedMods.Add($rec)
            Say ('已备份同名旧 jar: ' + $newJarName)
        }
    }
    if (-not $alreadyInstalled) {
        $null = Copy-FileVerified -SourcePath $JarPath -DestinationPath $destJar
        Say ('已复制新 jar: ' + $newJarName + ' (' + $newJarSize + ' 字节)')
    }

    $manifest = [pscustomobject]@{
        Tool = 'launch_test.ps1'
        Timestamp = $script:Timestamp
        VersionDir = $VersionDirPath
        ModsDir = $ModsDir
        ConfigDir = $ConfigDir
        JarSource = $JarPath
        JarVersion = $JarVersion
        InstalledJarName = $newJarName
        InstalledJarSha256 = $newJarHash
        AlreadyInstalled = $alreadyInstalled
        RemovedMods = [object[]]$removedMods.ToArray()
        BackedUpConfigs = [object[]]$backedUpConfigs.ToArray()
        ModsListFile = 'mods-list-before.txt'
    }
    $json = $manifest | ConvertTo-Json -Depth 10
    Write-TextFile -Path (Join-Path $backupPath 'backup-manifest.json') -Lines @([string]$json)
    $readme = @(
        'TaCZ Prone Hitbox - 实机安装备份',
        ('时间: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')),
        ('版本目录: ' + $VersionDirPath),
        ('新 jar: ' + $newJarName + ' (版本 ' + $JarVersion + ')'),
        '',
        '回滚方法（把新 jar 移走、旧 seamlesssprint jar 与配置放回）:',
        '  powershell -NoProfile -ExecutionPolicy Bypass -File tools\launch_test.ps1 -Rollback',
        '指定本次备份:',
        '  powershell -NoProfile -ExecutionPolicy Bypass -File tools\launch_test.ps1 -Rollback -BackupDir "' + $backupPath + '"',
        '',
        '本目录内容:',
        '  removed-mods\    从 mods 移出的旧 jar（原始文件仍在，可直接拷回）',
        '  config\          安装前备份的 config 文件',
        '  mods-list-before.txt  安装前 mods 全量清单',
        '  backup-manifest.json  机器可读的恢复清单'
    )
    Write-TextFile -Path (Join-Path $backupPath 'backup-readme.txt') -Lines $readme
    return [pscustomobject]@{
        BackupPath = $backupPath
        RemovedMods = [object[]]$removedMods.ToArray()
        BackedUpConfigs = [object[]]$backedUpConfigs.ToArray()
        InstalledJarName = $newJarName
        InstalledJarPath = $destJar
        InstalledJarSha256 = $newJarHash
        AlreadyInstalled = $alreadyInstalled
        ModsListFile = (Join-Path $backupPath 'mods-list-before.txt')
    }
}

function Get-LatestBackup {
    param([string]$RootPath)
    if (-not (Test-Path -LiteralPath $RootPath -PathType Container)) { return '' }
    $dirs = @(Get-ChildItem -LiteralPath $RootPath -Directory -ErrorAction SilentlyContinue | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'backup-manifest.json') } | Sort-Object -Property Name -Descending)
    if ($dirs.Count -eq 0) { return '' }
    return $dirs[0].FullName
}

function Invoke-Rollback {
    param(
        [string]$VersionDirPath,
        [string]$ModsDir,
        [string]$ConfigDir,
        [string]$BackupRootPath,
        [string]$ExplicitBackupDir,
        [string]$EvidenceDirPath,
        [bool]$PreviewOnly
    )
    Say-Sep
    if ($PreviewOnly) {
        Say '  回滚预览 ([-Rollback -DryRun]，不会改动任何文件)'
    } else {
        Say '  回滚模式 (-Rollback)'
    }
    Say-Sep
    $backupPath = $ExplicitBackupDir
    if ([string]::IsNullOrEmpty($backupPath)) { $backupPath = Get-LatestBackup -RootPath $BackupRootPath }
    if ([string]::IsNullOrEmpty($backupPath)) {
        Say '[FAIL] 找不到可用的备份目录（install-backup\<时间戳>\backup-manifest.json）'
        return 1
    }
    $backupPath = Get-NormalizedPath -Path $backupPath
    $manifestPath = Join-Path $backupPath 'backup-manifest.json'
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        Say ('[FAIL] 备份缺少 manifest: ' + $manifestPath)
        return 1
    }
    Say ('使用备份: ' + $backupPath)
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $rollbackDir = Join-Path $backupPath 'rollback'
    $actionCount = 0
    $failCount = 0
    $installedName = [string]$manifest.InstalledJarName
    if (-not [string]::IsNullOrEmpty($installedName)) {
        $installedPath = Join-Path $ModsDir $installedName
        if (Test-Path -LiteralPath $installedPath -PathType Leaf) {
            if ($PreviewOnly) {
                Say ('[预览] 将移走新 jar: ' + $installedPath)
                $actionCount = $actionCount + 1
            } else {
                $null = Move-FileToBackup -OriginalPath $installedPath -BackupModsDir (Join-Path $rollbackDir 'installed-jar') -Reason 'rollback: remove installed jar'
                Say ('已移走新 jar: ' + $installedName)
                $actionCount = $actionCount + 1
            }
        } else {
            Say ('新 jar 不在 mods 中（可能已手动移除）: ' + $installedName)
        }
    }
    foreach ($rec in @($manifest.RemovedMods)) {
        if ($null -eq $rec) { continue }
        $orig = [string]$rec.OriginalPath
        $bkp = [string]$rec.BackupPath
        if (-not (Test-Path -LiteralPath $bkp -PathType Leaf)) {
            Say ('[WARN] 备份文件缺失，跳过恢复: ' + $bkp)
            continue
        }
        if (-not $orig.StartsWith($VersionDirPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Say ('[WARN] 原路径不在版本目录内，跳过: ' + $orig)
            continue
        }
        if ($PreviewOnly) {
            Say ('[预览] 将恢复 mod jar: ' + $orig)
            $actionCount = $actionCount + 1
            continue
        }
        if (Test-Path -LiteralPath $orig -PathType Leaf) {
            $null = Move-FileToBackup -OriginalPath $orig -BackupModsDir (Join-Path $rollbackDir 'current-mods') -Reason 'rollback: keep current file'
        }
        try {
            $null = Copy-FileVerified -SourcePath $bkp -DestinationPath $orig
            Say ('已恢复 mod jar: ' + (Split-Path -Leaf $orig))
            $actionCount = $actionCount + 1
        } catch {
            Say ('[FAIL] 恢复失败: ' + $orig + ' -> ' + $_.Exception.Message)
            $failCount = $failCount + 1
        }
    }
    foreach ($rec in @($manifest.BackedUpConfigs)) {
        if ($null -eq $rec) { continue }
        $orig = [string]$rec.OriginalPath
        $bkp = [string]$rec.BackupPath
        if (-not (Test-Path -LiteralPath $bkp -PathType Leaf)) {
            Say ('[WARN] 配置备份缺失，跳过恢复: ' + $bkp)
            continue
        }
        if (-not $orig.StartsWith($VersionDirPath, [System.StringComparison]::OrdinalIgnoreCase)) {
            Say ('[WARN] 配置原路径不在版本目录内，跳过: ' + $orig)
            continue
        }
        if ($PreviewOnly) {
            Say ('[预览] 将恢复配置: ' + $orig)
            $actionCount = $actionCount + 1
            continue
        }
        if (Test-Path -LiteralPath $orig -PathType Leaf) {
            $null = Move-FileToBackup -OriginalPath $orig -BackupModsDir (Join-Path $rollbackDir 'current-config') -Reason 'rollback: keep current config'
        }
        try {
            $null = Copy-FileVerified -SourcePath $bkp -DestinationPath $orig
            Say ('已恢复配置: ' + (Split-Path -Leaf $orig))
            $actionCount = $actionCount + 1
        } catch {
            Say ('[FAIL] 恢复配置失败: ' + $orig + ' -> ' + $_.Exception.Message)
            $failCount = $failCount + 1
        }
    }
    foreach ($name in @('taczpronehitbox-common.toml', 'taczpronehitbox-client.toml', 'taczpronehitbox-sprint.properties')) {
        $p = Join-Path $ConfigDir $name
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        if ($PreviewOnly) {
            Say ('[预览] 将移走本 mod 生成的配置: ' + $p)
            $actionCount = $actionCount + 1
            continue
        }
        $null = Move-FileToBackup -OriginalPath $p -BackupModsDir (Join-Path $rollbackDir 'removed-configs') -Reason 'rollback: mod generated config'
        Say ('已移走本 mod 生成的配置: ' + $name)
        $actionCount = $actionCount + 1
    }
    Say ''
    if ($failCount -gt 0) {
        Say ('[FAIL] 回滚未完全成功（' + $failCount + ' 个错误），请检查上面的输出。')
        return 1
    }
    if ($PreviewOnly) {
        Say ('[PASS] 回滚预览完成：共 ' + $actionCount + ' 个动作，未改动任何文件。去掉 -DryRun 即真正回滚。')
    } else {
        Say ('[PASS] 回滚完成，共执行 ' + $actionCount + ' 个动作。重跑安装请再执行不带 -Rollback 的命令。')
    }
    return 0
}

function Invoke-Launch {
    param(
        [string]$LauncherBatPath,
        [string]$VersionDirPath,
        [string]$StdoutLogPath,
        [int]$TimeoutSec,
        [int]$StabilitySec
    )
    $result = [pscustomobject]@{
        Ok = $false
        TitleReached = $false
        RenderSeen = $false
        NewSessionSeen = $false
        TimedOut = $false
        FatalLine = ''
        FatalLines = @()
        TitleSeconds = -1
        LogPath = (Join-Path $VersionDirPath 'logs\latest.log')
        CmdProcessId = 0
        KillInfo = $null
        StartedAt = (Get-Date)
        LaunchSeconds = -1
    }
    $logPath = $result.LogPath
    $preSize = -1
    $preLineCount = 0
    if (Test-Path -LiteralPath $logPath -PathType Leaf) {
        $preSize = (Get-Item -LiteralPath $logPath).Length
        try { $preLineCount = @(Get-Content -LiteralPath $logPath -Encoding UTF8 -ErrorAction Stop).Count } catch { $preLineCount = 0 }
    }
    Say ('启动脚本: ' + $LauncherBatPath)
    Say ('stdout 日志: ' + $StdoutLogPath)
    $argString = '/d /s /c ""' + $LauncherBatPath + '" > "' + $StdoutLogPath + '" 2>&1 < nul"'
    $cmdProc = $null
    try {
        $cmdProc = Start-Process -FilePath 'cmd.exe' -ArgumentList $argString -WorkingDirectory $VersionDirPath -WindowStyle Hidden -PassThru
    } catch {
        $result.FatalLine = ('无法启动 cmd.exe: ' + $_.Exception.Message)
        Say ('[FAIL] ' + $result.FatalLine)
        return $result
    }
    $result.CmdProcessId = $cmdProc.Id
    Say ('已启动 cmd PID=' + $cmdProc.Id + '，开始等待最新日志（超时 ' + $TimeoutSec + ' 秒）...')
    $launchTime = Get-Date
    $deadline = $launchTime.AddSeconds($TimeoutSec)
    $lastProgress = $launchTime
    $pollCount = 0
    $renderSeen = $false
    $fatal = $null
    $appendMode = $false
    $freshSkipLines = 0
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $pollCount = $pollCount + 1
        $cmdAlive = -not $cmdProc.HasExited
        $javaInfo = Get-GameJavaInfo -VersionDirToMatch $VersionDirPath
        $javaCountText = 'unknown'
        if ($javaInfo.Available) { $javaCountText = [string]$javaInfo.Matches.Count }
        $newSession = $false
        $logSize = -1
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            $logItem = Get-Item -LiteralPath $logPath
            $logSize = $logItem.Length
            if ($logItem.LastWriteTime -gt $launchTime.AddSeconds(-2)) { $newSession = $true }
            if (($preSize -ge 0) -and ($logItem.Length -lt $preSize)) { $newSession = $true }
        }
        if ($newSession) {
            if (-not $result.NewSessionSeen) {
                $result.NewSessionSeen = $true
                if ((($preSize -ge 0) -and ($logItem.Length -ge $preSize)) -and ($preLineCount -gt 0)) {
                    $appendMode = $true
                    $freshSkipLines = $preLineCount
                }
                Say ('  检测到新的日志会话（第 ' + [Math]::Round(((Get-Date) - $launchTime).TotalSeconds, 1) + ' 秒）')
                if (-not $appendMode) {
                    $headLines = @()
                    try { $headLines = @(Get-Content -LiteralPath $logPath -TotalCount 3 -Encoding UTF8 -ErrorAction Stop) } catch { }
                    $headText = ($headLines -join ' ')
                    if ($headText -match 'ModLauncher running') { Say '  日志首行确认 ModLauncher 已启动' }
                } else {
                    Say ('  旧日志未轮转（文件变大），按行号过滤旧内容：忽略前 ' + $preLineCount + ' 行')
                }
            }
            $tail = Get-FreshLogLines -Path $logPath -TailCount 600 -SkipFirstLines $freshSkipLines
            $fatalLines = Find-FatalLines -Lines $tail
            if ($fatalLines.Count -gt 0) {
                $fatal = $fatalLines[0]
                $result.FatalLines = $fatalLines
                break
            }
            if ((-not $renderSeen) -and ($tail -match $script:RenderRx)) {
                $renderSeen = $true
                $result.RenderSeen = $true
                Say ('  渲染初始化完成: Backend library: LWJGL（第 ' + [Math]::Round(((Get-Date) - $launchTime).TotalSeconds, 1) + ' 秒）')
            }
            if (Test-TitleScreen -Lines $tail) {
                $result.TitleReached = $true
                $result.TitleSeconds = [Math]::Round(((Get-Date) - $launchTime).TotalSeconds, 1)
                Say ('  到达标题界面特征（第 ' + $result.TitleSeconds + ' 秒）')
                break
            }
        }
        if ((-not $newSession) -and (-not $cmdAlive) -and $javaInfo.Available -and ($javaInfo.Matches.Count -eq 0)) {
            Say '  [FAIL] 启动脚本已退出且没有游戏 java 进程，也没有新日志会话'
            break
        }
        if (($javaInfo.Available) -and ($javaInfo.Matches.Count -eq 0) -and $result.NewSessionSeen -and (-not $cmdAlive)) {
            Say '  [FAIL] 游戏进程已退出（启动脚本也已退出）'
            break
        }
        if (((Get-Date) - $lastProgress).TotalSeconds -ge 10) {
            $elapsed = [Math]::Round(((Get-Date) - $launchTime).TotalSeconds, 0)
            Say ('  ... ' + $elapsed + ' 秒: java=' + $javaCountText + ', 日志=' + $logSize + ' 字节, cmd存活=' + $cmdAlive)
            $lastProgress = Get-Date
        }
    }
    $result.LaunchSeconds = [Math]::Round(((Get-Date) - $launchTime).TotalSeconds, 1)
    if (-not $result.TitleReached -and [string]::IsNullOrEmpty($result.FatalLine) -and $fatal -eq $null -and ((Get-Date) -ge $deadline)) {
        $result.TimedOut = $true
        Say ('  [FAIL] 等待标题界面超时（' + $TimeoutSec + ' 秒）')
    }
    if ($fatal -ne $null) {
        $result.FatalLine = [string]$fatal
        Say ('  [FAIL] 检测到崩溃/注入错误日志: ' + $fatal)
    }
    if ($result.TitleReached -and [string]::IsNullOrEmpty($result.FatalLine)) {
        Say ('  稳定观察 ' + $StabilitySec + ' 秒...')
        $stable = $true
        $stabilityDeadline = (Get-Date).AddSeconds($StabilitySec)
        while ((Get-Date) -lt $stabilityDeadline) {
            Start-Sleep -Seconds 1
            $tail = Get-FreshLogLines -Path $logPath -TailCount 600 -SkipFirstLines $freshSkipLines
            $fatalLines = Find-FatalLines -Lines $tail
            if ($fatalLines.Count -gt 0) {
                $stable = $false
                $result.FatalLine = [string]$fatalLines[0]
                Say ('  [FAIL] 稳定观察期间出现崩溃/注入错误: ' + $result.FatalLine)
                break
            }
            $javaInfo = Get-GameJavaInfo -VersionDirToMatch $VersionDirPath
            if ($javaInfo.Available -and ($javaInfo.Matches.Count -eq 0)) {
                $stable = $false
                Say '  [FAIL] 稳定观察期间游戏进程退出了'
                break
            }
        }
        $result.Ok = $stable
    } else {
        $result.Ok = $false
    }
    Say '结束游戏进程（只结束命令行包含该版本目录的 java.exe）...'
    $killInfo = Stop-StartedGame -VersionDirToMatch $VersionDirPath -CmdProcessId $cmdProc.Id
    $result.KillInfo = $killInfo
    if ($killInfo.KilledPids.Count -gt 0) {
        Say ('  已结束 java PID: ' + ($killInfo.KilledPids -join ', '))
    } else {
        Say '  未能按命令行精确结束 java 进程（可能已被关闭或进程枚举被拒）'
    }
    if ($killInfo.Remaining.Count -gt 0) {
        Say ('  [WARN] 仍有 java 进程在运行: ' + (($killInfo.Remaining | ForEach-Object { 'PID ' + $_.ProcessId }) -join ', ') + '；请手动关闭游戏窗口')
    } else {
        if ($killInfo.Warnings.Count -gt 0) {
            Say ('  [WARN] 结束进程时有不完全确认: ' + (($killInfo.Warnings) -join ' | '))
        } else {
            Say '  游戏进程已结束'
        }
    }
    return $result
}

function Copy-EvidenceLogs {
    param(
        [string]$VersionDirPath,
        [string]$RunDir,
        [string]$StdoutLogPath
    )
    $latestSrc = Join-Path $VersionDirPath 'logs\latest.log'
    if (Test-Path -LiteralPath $latestSrc -PathType Leaf) {
        Copy-Item -LiteralPath $latestSrc -Destination (Join-Path $RunDir 'latest.log') -Force
        $tail = @()
        try { $tail = @(Get-Content -LiteralPath $latestSrc -Tail 400 -Encoding UTF8 -ErrorAction Stop) } catch { }
        Write-TextFile -Path (Join-Path $RunDir 'latest-tail.txt') -Lines ([string[]]$tail)
        $allLines = @()
        try { $allLines = @(Get-Content -LiteralPath $latestSrc -Encoding UTF8 -ErrorAction Stop) } catch { }
        $keyRx = 'taczpronehitbox|EntityUtil|TaCZ|mixin|OpenAL|Sound engine|Backend library|ERROR|WARN|crash|seamlesssprint|sprint lock|Minecraft/'
        $keyLines = New-Object System.Collections.ArrayList
        foreach ($line in $allLines) {
            if ($line -match $keyRx) { [void]$keyLines.Add($line) }
            if ($keyLines.Count -ge 3000) { break }
        }
        Write-TextFile -Path (Join-Path $RunDir 'key-lines.txt') -Lines ([string[]]$keyLines.ToArray())
        Say ('证据: latest.log (' + $allLines.Count + ' 行) / latest-tail.txt / key-lines.txt 已复制到 ' + $RunDir)
    } else {
        Say '[WARN] 版本目录下没有 logs\latest.log，无法复制日志证据'
    }
    $debugSrc = Join-Path $VersionDirPath 'logs\debug.log'
    if (Test-Path -LiteralPath $debugSrc -PathType Leaf) {
        $debugLines = @()
        try { $debugLines = @(Get-Content -LiteralPath $debugSrc -Encoding UTF8 -ErrorAction Stop) } catch { }
        $dbgRx = 'taczpronehitbox|EntityUtil|Found valid mod file|Registering mixin config|Channel .tacz|Mixin apply|NoSuchMethod|MixinApplyError'
        $dbgOut = New-Object System.Collections.ArrayList
        foreach ($line in $debugLines) {
            if ($line -match $dbgRx) { [void]$dbgOut.Add($line) }
            if ($dbgOut.Count -ge 3000) { break }
        }
        Write-TextFile -Path (Join-Path $RunDir 'debug-extract.txt') -Lines ([string[]]$dbgOut.ToArray())
        Say ('证据: debug.log 关键行 (' + $dbgOut.Count + ' 行) -> debug-extract.txt')
    }
    if (Test-Path -LiteralPath $StdoutLogPath -PathType Leaf) {
        Copy-Item -LiteralPath $StdoutLogPath -Destination (Join-Path $RunDir 'launch-stdout.log') -Force
        Say '证据: launch-stdout.log 已复制'
    }
    $crashDir = Join-Path $VersionDirPath 'crash-reports'
    if (Test-Path -LiteralPath $crashDir -PathType Container) {
        $fresh = @(Get-ChildItem -LiteralPath $crashDir -File -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-30) })
        if ($fresh.Count -gt 0) {
            $dest = Join-Path $RunDir 'crash-reports'
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            foreach ($f in $fresh) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dest $f.Name) -Force }
            Say ('[WARN] 发现 ' + $fresh.Count + ' 个新的 crash-reports 文件，已复制到 evidence')
        }
    }
}

function Invoke-Main {
    Say-Sep
    Say '  TaCZ Prone Hitbox - 实机启动测试 (launch_test.ps1)'
    Say ('  时间: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Say-Sep

    $backupRootPath = $BackupRoot
    if ([string]::IsNullOrEmpty($backupRootPath)) { $backupRootPath = Join-Path $script:ProjectRoot 'install-backup' }
    $backupRootPath = Get-NormalizedPath -Path $backupRootPath
    $evidenceRootPath = $EvidenceRoot
    if ([string]::IsNullOrEmpty($evidenceRootPath)) { $evidenceRootPath = Join-Path $script:ProjectRoot 'evidence' }
    $evidenceRootPath = Get-NormalizedPath -Path $evidenceRootPath

    if ($TimeoutSeconds -lt 30) { Say ('[FAIL] -TimeoutSeconds 至少 30（当前 ' + $TimeoutSeconds + '）'); return 2 }
    if ($StabilitySeconds -lt 0) { Say '[FAIL] -StabilitySeconds 不能为负数'; return 2 }

    $versionDirPath = Get-NormalizedPath -Path $VersionDir
    $modsDir = Join-Path $versionDirPath 'mods'
    $configDir = Join-Path $versionDirPath 'config'
    $launcherPath = $LauncherBat
    if ([string]::IsNullOrEmpty($launcherPath)) { $launcherPath = Get-DefaultLauncherBat -VersionDirPath $versionDirPath }
    if (-not [string]::IsNullOrEmpty($launcherPath)) { $launcherPath = Get-NormalizedPath -Path $launcherPath }

    Say-Section '参数与路径'
    Say ('版本目录 : ' + $versionDirPath)
    Say ('mods 目录: ' + $modsDir)
    if ($Rollback) { Say '启动脚本 : (回滚模式不需要)' } else { Say ('启动脚本 : ' + $launcherPath) }
    Say ('备份根目录: ' + $backupRootPath)
    Say ('证据根目录: ' + $evidenceRootPath)
    Say ('模式     : ' + $(if ($Rollback) { '回滚' } elseif ($NoInstall) { '不安装，仅启动' } elseif ($DryRun) { '仅校验 (-DryRun)' } else { '安装 + 启动' }))
    Say ('超时/稳定: ' + $TimeoutSeconds + ' 秒 / ' + $StabilitySeconds + ' 秒')

    $validationErrors = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $versionDirPath -PathType Container)) {
        [void]$validationErrors.Add('版本目录不存在: ' + $versionDirPath)
    }
    if (-not (Test-Path -LiteralPath $modsDir -PathType Container)) {
        [void]$validationErrors.Add('mods 目录不存在: ' + $modsDir)
    }
    if ((-not $Rollback) -and (-not (Test-Path -LiteralPath $launcherPath -PathType Leaf))) {
        [void]$validationErrors.Add('启动脚本不存在: ' + $launcherPath + '（可用 -LauncherBat 指定）')
    }
    if ($validationErrors.Count -gt 0) {
        Say-Section '校验失败'
        foreach ($err in @($validationErrors.ToArray())) { Say ('[FAIL] ' + $err) }
        return 2
    }
    if (-not $Rollback) {
        $launcherJava = Get-LauncherJavaExe -LauncherBatPath $launcherPath
        if ($launcherJava) {
            if (Test-Path -LiteralPath $launcherJava -PathType Leaf) {
                Say ('启动脚本使用的 java: ' + $launcherJava)
            } else {
                Say ('[FAIL] 启动脚本引用的 java.exe 不存在: ' + $launcherJava)
                return 2
            }
        } else {
            Say '[WARN] 无法从启动脚本中解析 java.exe 路径'
        }
    }
    if (-not $Rollback) {
        $taczJars = @(Get-ChildItem -LiteralPath $modsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)tacz-1\.20\.1-' })
        if ($taczJars.Count -gt 0) {
            Say ('TaCZ 已安装: ' + (($taczJars | ForEach-Object { $_.Name }) -join ', '))
        } else {
            Say '[WARN] mods 里没找到 tacz-1.20.1-*.jar：本 mod 强制依赖 TaCZ 1.1.8+，缺少会导致启动失败'
        }
        $existingOurJars = @(Get-ChildItem -LiteralPath $modsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)^taczpronehitbox' })
        if ($existingOurJars.Count -gt 0) {
            Say ('mods 中已有本 mod jar: ' + (($existingOurJars | ForEach-Object { $_.Name }) -join ', '))
        }
        $legacySprintJars = @(Get-ChildItem -LiteralPath $modsDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '(?i)^seamlesssprint.*\.jar$' })
        if ($legacySprintJars.Count -gt 0) {
            Say ('待移出备份的旧 sprint jar: ' + (($legacySprintJars | ForEach-Object { $_.Name }) -join ', '))
        } else {
            Say 'mods 中没有旧 seamlesssprint jar（可能已卸载）'
        }
    }

    $jarPath = $Jar
    $jarInfo = $null
    if (-not $NoInstall -and -not $Rollback) {
        if ([string]::IsNullOrEmpty($jarPath)) { $jarPath = Get-DefaultJar }
        if ([string]::IsNullOrEmpty($jarPath)) {
            Say '[FAIL] 找不到要安装的 jar（build\libs 或 dist 下没有 taczpronehitbox-*.jar），可用 -Jar 指定'
            return 2
        }
        $jarPath = Get-NormalizedPath -Path $jarPath
        if (-not (Test-Path -LiteralPath $jarPath -PathType Leaf)) {
            Say ('[FAIL] jar 不存在: ' + $jarPath)
            return 2
        }
        Say ('待安装 jar: ' + $jarPath)
        $jarInfo = Get-JarInfo -JarPath $jarPath
        if (-not $jarInfo.Valid) {
            Say ('[FAIL] jar 结构校验失败（需要 META-INF/mods.toml + taczpronehitbox.mixins.json + MANIFEST MixinConfigs）: ' + $jarInfo.Error)
            Say ('        manifest=' + $jarInfo.HasManifest + ' mods.toml=' + $jarInfo.HasModsToml + ' mixins.json=' + $jarInfo.HasMixinsJson + ' modId=' + $jarInfo.ModIdFound + ' MixinConfigs=' + $jarInfo.MixinConfigs)
            return 2
        }
        Say ('jar 校验通过: 版本 ' + $jarInfo.Version + ', 条目 ' + $jarInfo.EntryCount + ' 个, SHA256 ' + (Get-FileSha256 -Path $jarPath))
    } elseif ($Rollback) {
        Say '回滚模式不需要新 jar'
    } else {
        Say '(-NoInstall) 跳过安装：不复制 jar、不做备份'
    }

    $runningInfo = Get-GameJavaInfo -VersionDirToMatch $versionDirPath
    if ($runningInfo.Available) {
        if ($runningInfo.Matches.Count -gt 0) {
            Say ('[FAIL] 该版本的游戏正在运行（java PID: ' + (($runningInfo.Matches | ForEach-Object { $_.ProcessId }) -join ', ') + '），请先关闭游戏再运行本脚本')
            return 3
        }
        Say '预检: 该版本当前没有运行中的游戏进程'
    } else {
        Say ('[WARN] 无法枚举 Win32_Process（' + $runningInfo.Error + '）：跳过"已在运行"预检，结束时用进程树兜底')
    }

    if ($Rollback) {
        $evidenceDir = ''
        if (-not $DryRun) {
            $evidenceDir = Join-Path $evidenceRootPath ($script:Timestamp + '-rollback')
            New-Item -ItemType Directory -Path $evidenceDir -Force | Out-Null
        }
        $rollbackExit = Invoke-Rollback -VersionDirPath $versionDirPath -ModsDir $modsDir -ConfigDir $configDir -BackupRootPath $backupRootPath -ExplicitBackupDir $BackupDir -EvidenceDirPath $evidenceDir -PreviewOnly ([bool]$DryRun)
        if (-not [string]::IsNullOrEmpty($evidenceDir)) {
            Write-TextFile -Path (Join-Path $evidenceDir 'rollback.log') -Lines ([string[]]$script:ReportLines.ToArray())
            Say ('回滚日志: ' + (Join-Path $evidenceDir 'rollback.log'))
        }
        return $rollbackExit
    }

    if ($DryRun) {
        Say-Section '运行计划 (-DryRun，不会改动任何文件)'
        if ($NoInstall) {
            Say '1) (-NoInstall) 不备份、不复制 jar，直接使用当前 mods 状态'
        } else {
            Say ('1) 备份到: ' + (Join-Path $backupRootPath $script:Timestamp))
            Say '   备份内容: 旧 seamlesssprint*.jar、config\seamlesssprint.properties、mods 全量清单、旧 taczpronehitbox*.jar（如有）'
            Say ('2) 复制到 mods: ' + (Split-Path -Leaf $jarPath) + ' (版本 ' + $jarInfo.Version + ')')
        }
        Say ('3) 启动: cmd /c "' + $launcherPath + '"（工作目录 ' + $versionDirPath + '）')
        Say ('   stdout 重定向到: ' + (Join-Path $evidenceRootPath 'launch-stdout.log'))
        Say ('4) 轮询: ' + (Join-Path $versionDirPath 'logs\latest.log') + '，等待标题界面特征，超时 ' + $TimeoutSeconds + ' 秒')
        Say ('5) 稳定 ' + $StabilitySeconds + ' 秒后，只结束命令行包含版本目录的 java.exe')
        Say ('6) 证据输出到: ' + (Join-Path $evidenceRootPath ($script:Timestamp + $(if ($NoInstall) { '-noinstall' } else { '-install' }))) + '，并自动运行 analyze_launch_log.ps1')
        Say ''
        Say '[PASS] DryRun 校验全部通过，可以正式运行（去掉 -DryRun）。'
        return 0
    }

    $installRecord = $null
    if (-not $NoInstall) {
        Say-Section '安装 / 备份'
        try {
            $installRecord = Install-ModJar -JarPath $jarPath -JarVersion $jarInfo.Version -VersionDirPath $versionDirPath -ModsDir $modsDir -ConfigDir $configDir -BackupRootPath $backupRootPath
        } catch {
            Say ('[FAIL] 安装失败（写用户实例需要提权：danger-full-access / 管理员）: ' + $_.Exception.Message)
            return 2
        }
        Add-Result -Name '安装与备份' -Status 'PASS' -Detail ('备份 ' + $installRecord.BackupPath + '，jar ' + $installRecord.InstalledJarName + ' v' + $jarInfo.Version)
        if ($installRecord.RemovedMods.Count -gt 0) {
            Say ('已移出 mods 的旧 jar: ' + (($installRecord.RemovedMods | ForEach-Object { Split-Path -Leaf $_.OriginalPath }) -join ', ') + '（完整文件在备份目录，可回滚）')
        }
    } else {
        Add-Result -Name '安装与备份' -Status 'SKIP' -Detail '(-NoInstall) 直接使用当前 mods 状态'
    }

    $runMode = 'install'
    if ($NoInstall) { $runMode = 'noinstall' }
    $runDir = Join-Path $evidenceRootPath ($script:Timestamp + '-' + $runMode)
    New-Item -ItemType Directory -Path $runDir -Force | Out-Null
    $stdoutLog = Join-Path $evidenceRootPath 'launch-stdout.log'

    Say-Section '启动游戏'
    $launchResult = Invoke-Launch -LauncherBatPath $launcherPath -VersionDirPath $versionDirPath -StdoutLogPath $stdoutLog -TimeoutSec $TimeoutSeconds -StabilitySec $StabilitySeconds

    Say-Section '取证'
    Copy-EvidenceLogs -VersionDirPath $versionDirPath -RunDir $runDir -StdoutLogPath $stdoutLog
    if ($installRecord -ne $null) {
        $json = $installRecord | ConvertTo-Json -Depth 10
        Write-TextFile -Path (Join-Path $runDir 'install-record.json') -Lines @([string]$json)
    }

    $analyzeExit = -1
    $analyzeScript = Join-Path $PSScriptRoot 'analyze_launch_log.ps1'
    $mainLog = Join-Path $versionDirPath 'logs\latest.log'
    if (-not $launchResult.NewSessionSeen) {
        Say-Section '日志分析 (analyze_launch_log.ps1)'
        Say '[WARN] 本次启动没有检测到新的日志会话（游戏可能没起来 / 日志未更新），跳过日志分析'
    } elseif (Test-Path -LiteralPath $analyzeScript -PathType Leaf) {
        Say-Section '日志分析 (analyze_launch_log.ps1)'
        $powershellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $analyzeOutFile = Join-Path $runDir 'analyze.txt'
        $analyzeOutput = ''
        try {
            $analyzeOutput = (& $powershellExe -NoProfile -ExecutionPolicy Bypass -File $analyzeScript -LogPath $mainLog -OutFile $analyzeOutFile 2>&1 | Out-String)
            $analyzeExit = $LASTEXITCODE
        } catch {
            $analyzeOutput = ('调用分析脚本失败: ' + $_.Exception.Message)
            $analyzeExit = -2
        }
        foreach ($line in ($analyzeOutput -split [string][char]10)) { Say $line }
        Say ('analyze 退出码: ' + $analyzeExit + '（0 = 无 FAIL 项）')
    } else {
        Say '[WARN] 找不到 tools\analyze_launch_log.ps1，跳过日志分析'
    }

    Say-Section '结果'
    $launchOk = [bool]$launchResult.Ok
    if ($launchOk) {
        Add-Result -Name '游戏启动到标题界面' -Status 'PASS' -Detail ('用时 ' + $launchResult.TitleSeconds + ' 秒，稳定 ' + $StabilitySeconds + ' 秒无崩溃')
    } else {
        $detail = '未到达标题界面/出现崩溃'
        if ($launchResult.TimedOut) { $detail = '等待标题界面超时 (' + $TimeoutSeconds + ' 秒)' }
        if (-not [string]::IsNullOrEmpty([string]$launchResult.FatalLine)) { $detail = '崩溃/注入错误: ' + [string]$launchResult.FatalLine }
        Add-Result -Name '游戏启动到标题界面' -Status 'FAIL' -Detail $detail
    }
    $killOk = $true
    $killConfirmed = $true
    if ($launchResult.KillInfo -ne $null) {
        if ($launchResult.KillInfo.Remaining.Count -gt 0) { $killOk = $false; $killConfirmed = $false }
        if (($launchResult.KillInfo.KilledPids.Count -eq 0) -and ($launchResult.KillInfo.Warnings.Count -gt 0)) { $killConfirmed = $false }
    }
    if (-not $killOk) {
        Add-Result -Name '结束游戏进程' -Status 'WARN' -Detail '仍有 java 进程残留，请手动关闭游戏窗口'
    } elseif (-not $killConfirmed) {
        Add-Result -Name '结束游戏进程' -Status 'WARN' -Detail '进程枚举/结束被拒绝，无法确认游戏是否已退出（如有残留请手动关闭）'
    } else {
        Add-Result -Name '结束游戏进程' -Status 'PASS' -Detail '未发现残留 java 进程'
    }
    if ($analyzeExit -eq 0) {
        Add-Result -Name '日志分析' -Status 'PASS' -Detail 'analyze_launch_log.ps1 无 FAIL 项'
    } elseif ($analyzeExit -eq -1) {
        Add-Result -Name '日志分析' -Status 'SKIP' -Detail '分析脚本未运行'
    } else {
        Add-Result -Name '日志分析' -Status 'FAIL' -Detail ('analyze_launch_log.ps1 退出码 ' + $analyzeExit + '，详见 ' + (Join-Path $runDir 'analyze.txt'))
    }
    $overall = $launchOk -and (($analyzeExit -eq 0) -or ($analyzeExit -eq -1))
    Say ''
    Say ('汇总: PASS=' + $script:PassCount + ' FAIL=' + $script:FailCount + ' WARN=' + $script:WarnCount)
    if ($overall) {
        Say '[总体] PASS'
    } else {
        Say '[总体] FAIL'
    }
    Say ('证据目录: ' + $runDir)
    if ($installRecord -ne $null) {
        Say ('备份目录: ' + $installRecord.BackupPath)
        Say ('回滚命令: powershell -NoProfile -ExecutionPolicy Bypass -File tools\launch_test.ps1 -Rollback -BackupDir "' + $installRecord.BackupPath + '"')
    }
    $summaryLines = New-Object System.Collections.ArrayList
    [void]$summaryLines.Add('launch_test.ps1 summary')
    [void]$summaryLines.Add(('time: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')))
    [void]$summaryLines.Add(('versionDir: ' + $versionDirPath))
    [void]$summaryLines.Add(('launcher: ' + $launcherPath))
    [void]$summaryLines.Add(('titleReached: ' + $launchResult.TitleReached))
    [void]$summaryLines.Add(('titleSeconds: ' + $launchResult.TitleSeconds))
    [void]$summaryLines.Add(('fatal: ' + ([string]$launchResult.FatalLine)))
    [void]$summaryLines.Add(('analyzeExit: ' + $analyzeExit))
    [void]$summaryLines.Add(('overall: ' + $(if ($overall) { 'PASS' } else { 'FAIL' })))
    Write-TextFile -Path (Join-Path $runDir 'summary.txt') -Lines ([string[]]$summaryLines.ToArray())
    Write-TextFile -Path (Join-Path $runDir 'launch-test.log') -Lines ([string[]]$script:ReportLines.ToArray())
    if ($overall) { return 0 } else { return 1 }
}

try {
    $exitCode = Invoke-Main
    exit $exitCode
} catch {
    Write-Host ''
    Write-Host ('[FAIL] 未预期的脚本错误: ' + $_.Exception.Message)
    Write-Host ([string]$_.ScriptStackTrace)
    exit 2
}
