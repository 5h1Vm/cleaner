<# : cleaner.bat - batch launcher. The PowerShell part starts after the closing comment tag.
@echo off
setlocal
title Cleaner
set "CLEANER_PATH=%~f0"
set "CLEANER_ARGS=%*"
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([IO.File]::ReadAllText($env:CLEANER_PATH)))"
rem Exit code 10 means this window handed over to the elevated window.
if "%errorlevel%"=="10" exit /b
echo.
pause
exit /b
#>

# =====================================================================
#  Cleaner for Windows 10 / 11
#  https://github.com/5h1Vm/cleaner
#
#  Double-click cleaner.bat. It runs in two stages:
#    1. As you: trims free space inside your WSL distros (WSL only
#       shows your distros to your normal, non-admin account).
#    2. As admin: everything else.
#
#  Nothing here is specific to one machine. Every location is resolved
#  at runtime: from the tool itself, its environment variables, the
#  registry, or the vendor default relative to the user's profile.
# =====================================================================

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
# Protected folders (Defender, Search) raise "Access is denied" on Test-Path.
# Treat those as "not reachable" instead of printing errors.
$PSDefaultParameterValues['Test-Path:ErrorAction'] = 'SilentlyContinue'

$ArgText = [string]$env:CLEANER_ARGS

# ---------------------------------------------------------------------
#  Who are we cleaning for?
#  When a standard user elevates with another admin account, the
#  elevated process has the admin's profile. Stage 1 passes the
#  original user's SID so stage 2 cleans the right profile.
# ---------------------------------------------------------------------
$CurrentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$TargetSid  = $CurrentSid
if ($ArgText -match '/user:(S-[0-9-]+)') { $TargetSid = $Matches[1] }
$SameUser = ($TargetSid -eq $CurrentSid)

if ($SameUser) {
    $UserProfile = $env:USERPROFILE
    $Local       = $env:LOCALAPPDATA
    $Roaming     = $env:APPDATA
    $UserTemp    = [IO.Path]::GetTempPath().TrimEnd('\')
} else {
    $pl = Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$TargetSid" -ErrorAction SilentlyContinue
    $UserProfile = [Environment]::ExpandEnvironmentVariables([string]$pl.ProfileImagePath)
    $shell = Get-ItemProperty "Registry::HKEY_USERS\$TargetSid\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders" -ErrorAction SilentlyContinue
    function Expand-ForUser([string]$v) { if (-not $v) { return $null }; return ($v -replace '%USERPROFILE%', $UserProfile) }
    $Local   = Expand-ForUser $shell.'Local AppData'
    $Roaming = Expand-ForUser $shell.AppData
    if (-not $Local)   { $Local   = Join-Path $UserProfile 'AppData\Local' }
    if (-not $Roaming) { $Roaming = Join-Path $UserProfile 'AppData\Roaming' }
    $UserTemp = Join-Path $Local 'Temp'
}
$UserHive = "Registry::HKEY_USERS\$TargetSid"
$IsAdmin  = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

# Stage 1 writes its trim results here for stage 2 to show.
$TrimResultFile = Join-Path $UserTemp 'cleaner-trim.json'

# ---------------------------------------------------------------------
#  Output
#    [*] section     [>] step starts     |  detail lines
#    [i] info        [!] warning         '- [+] step result
# ---------------------------------------------------------------------
$script:StepNo     = 0
$script:Timer      = $null
$script:TotalFreed = 0

function Write-Section([string]$t) {
    $bar = '=' * [Math]::Max(4, 60 - $t.Length)
    Write-Host ''
    Write-Host ('[*] ===[ {0} ]{1}' -f $t.ToUpper(), $bar) -ForegroundColor Green
}
function Start-Step([string]$t) {
    $script:StepNo++
    $script:Timer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host ('[>] 0x{0:X2}  {1}' -f $script:StepNo, $t) -ForegroundColor Green
}
function Write-Detail([string]$t) { Write-Host "    |  $t"     -ForegroundColor DarkGreen }
function Write-Info([string]$t)   { Write-Host "    |  [i] $t" -ForegroundColor DarkGreen }
function Write-Warn([string]$t)   { Write-Host "    |  [!] $t" -ForegroundColor Yellow }
function End-Step([string]$t, [string]$Color = 'Green') {
    $tag  = if ($Color -eq 'Green') { '[+]' } else { '[!]' }
    $time = if ($script:Timer) { ' | {0:N2}s' -f $script:Timer.Elapsed.TotalSeconds } else { '' }
    Write-Host ("    '- {0} {1}{2}" -f $tag, $t, $time) -ForegroundColor $Color
}

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}

# Shows paths inside the user's profile as ~\...
function Short([string]$p) {
    if ($p -and $UserProfile -and $p.StartsWith($UserProfile, [StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $p.Substring($UserProfile.Length)
    }
    return $p
}

# Returns the first argument that is not empty.
function First-Set { foreach ($a in $args) { if ($a) { return $a } }; return $null }

function Test-Tool([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Runs a command quietly and returns its trimmed text output (used to ask
# tools where their caches live).
function Get-ToolOutput([string]$Name, [string[]]$Arguments) {
    try { return ((& $Name @Arguments 2>$null | Out-String).Trim()) } catch { return $null }
}

function Show-Banner {
    try {
        $Host.UI.RawUI.WindowTitle     = 'Cleaner'
        $Host.UI.RawUI.BackgroundColor = 'Black'
        $Host.UI.RawUI.ForegroundColor = 'Green'
        Clear-Host
    } catch { }
    $banner = @(
        '   ________    _________    _   ____________ '
        '  / ____/ /   / ____/   |  / | / / ____/ __ \'
        ' / /   / /   / __/ / /| | /  |/ / __/ / /_/ /'
        '/ /___/ /___/ /___/ ___ |/ /|  / /___/ _, _/ '
        '\____/_____/_____/_/  |_/_/ |_/_____/_/ |_|  '
    )
    Write-Host ''
    foreach ($l in $banner) { Write-Host "  $l" -ForegroundColor Green }
    Write-Host ''
}

# ---------------------------------------------------------------------
#  Process helpers
# ---------------------------------------------------------------------
# Runs a command, prints its output, returns its exit code.
function Invoke-Tool([string]$Name, [string[]]$Arguments) {
    Write-Info ('exec  {0} {1}' -f $Name, ($Arguments -join ' '))
    $out = @(); $code = $null
    try {
        $out  = @(& $Name @Arguments 2>&1 | ForEach-Object { "$_" })
        $code = $LASTEXITCODE
    } catch { $out = @($_.Exception.Message); $code = 1 }
    if ($null -eq $code) { $code = 0 }
    $lines = @($out | Where-Object { $_.Trim() -and $_ -ne 'System.Management.Automation.RemoteException' })
    if ($lines.Count -le 12) {
        foreach ($l in $lines) { Write-Detail "> $l" }
    } else {
        foreach ($l in ($lines | Select-Object -First 8)) { Write-Detail "> $l" }
        Write-Detail ("> ... {0} more lines ..." -f ($lines.Count - 11))
        foreach ($l in ($lines | Select-Object -Last 3)) { Write-Detail "> $l" }
    }
    return $code
}

# Runs a program with a time limit and captures its output.
function Invoke-Timed([string]$File, [string]$Arguments, [int]$Seconds) {
    $r = [pscustomobject]@{ Ok = $false; ExitCode = $null; Output = @() }
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -PassThru `
             -RedirectStandardOutput $o -RedirectStandardError $e -ErrorAction Stop
        # Reading Handle keeps ExitCode available after a timed wait (PowerShell quirk).
        $null = $p.Handle
        if (-not $p.WaitForExit($Seconds * 1000)) {
            try { $p.Kill() } catch { }
            $r.Output = @("timed out after $Seconds s")
            return $r
        }
        $p.WaitForExit()
        $r.ExitCode = $p.ExitCode
        $r.Ok = ($p.ExitCode -eq 0)
        # wsl.exe writes UTF-16 messages; strip the NULs so they read normally.
        $r.Output = @((Get-Content -LiteralPath $o -ErrorAction SilentlyContinue) + (Get-Content -LiteralPath $e -ErrorAction SilentlyContinue) |
                      ForEach-Object { ($_ -replace "`0", '').Trim() } | Where-Object { $_ })
    } catch { $r.Output = @($_.Exception.Message) }
    finally { Remove-Item -LiteralPath $o, $e -Force -ErrorAction SilentlyContinue }
    return $r
}

# WSL distros registered for the user, from the Lxss registry key.
function Get-WslDistros {
    $list = @()
    $lxss = Join-Path $UserHive 'Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxss)) { return $list }
    Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if (-not $p.BasePath) { return }
        $vhdName = if ($p.VhdFileName) { $p.VhdFileName } else { 'ext4.vhdx' }
        $list += [pscustomobject]@{
            Name = $p.DistributionName
            Vhd  = (Join-Path ($p.BasePath -replace '^\\\\\?\\', '') $vhdName)
        }
    }
    return $list
}

# Tells a distro's filesystem which blocks are free, so compaction can
# return them to Windows. docker-desktop is only trimmed while Docker runs.
function Invoke-Trim($Distro, [bool]$DockerRunning) {
    if (-not (Test-Path -LiteralPath $Distro.Vhd)) { return $null }   # WSL 1 distro, no disk
    if ($Distro.Name -like 'docker-desktop*' -and -not $DockerRunning) { return $null }
    # No quotes around the name: wsl.exe keeps them as part of the name when
    # started this way. Distro names cannot contain spaces, so none are needed.
    # Full path because "wsl -e" does not search sbin. /sbin/fstrim resolves on
    # Debian, Ubuntu, Kali, Fedora, Arch and Alpine alike.
    $r = Invoke-Timed 'wsl.exe' "-d $($Distro.Name) -u root -e /sbin/fstrim -av" 180
    return [pscustomobject]@{ Name = $Distro.Name; Ok = $r.Ok; ExitCode = $r.ExitCode; Output = @($r.Output) }
}

# =====================================================================
#  Stage 1: not admin yet. Trim WSL as the normal user, then elevate.
# =====================================================================
if (-not $IsAdmin) {
    Show-Banner
    Write-Section 'Prepare'
    $distros = @(Get-WslDistros)
    $results = @()
    if ($distros.Count -gt 0 -and (Test-Tool 'wsl')) {
        $dockerRunning = $false
        if (($distros | Where-Object { $_.Name -like 'docker-desktop*' }) -and (Test-Tool 'docker')) {
            $dockerRunning = (Invoke-Timed 'docker' 'info' 20).Ok
        }
        foreach ($d in $distros) {
            $res = $null
            if (Test-Path -LiteralPath $d.Vhd) {
                if ($d.Name -notlike 'docker-desktop*' -or $dockerRunning) {
                    Start-Step "Trim free space: $($d.Name)"
                    Write-Info "exec  wsl -d $($d.Name) -u root -e /sbin/fstrim -av"
                    $res = Invoke-Trim $d $dockerRunning
                    foreach ($l in $res.Output) { Write-Detail "> $l" }
                    if ($res.Ok) { End-Step 'trimmed' } else { End-Step ('trim failed (exit {0})' -f $res.ExitCode) 'Yellow' }
                }
            }
            if ($res) { $results += $res }
        }
    }
    try { ConvertTo-Json -InputObject @($results) -Depth 4 | Set-Content -LiteralPath $TrimResultFile -Encoding UTF8 } catch { }

    Start-Step 'Request administrator rights'
    try {
        Start-Process -FilePath $env:CLEANER_PATH -ArgumentList ('/user:' + $CurrentSid) -Verb RunAs -ErrorAction Stop
        End-Step 'continuing in the admin window'
        exit 10
    } catch {
        Remove-Item -LiteralPath $TrimResultFile -Force -ErrorAction SilentlyContinue
        End-Step 'administrator rights were not granted, nothing was cleaned' 'Red'
        exit 1
    }
}

# =====================================================================
#  Stage 2: admin.
# =====================================================================

# Trim results from stage 1 (read now, before Temp is cleaned).
$PreTrim = @{}
if (Test-Path -LiteralPath $TrimResultFile) {
    try {
        foreach ($t in @(Get-Content -LiteralPath $TrimResultFile -Raw | ConvertFrom-Json)) { if ($t.Name) { $PreTrim[$t.Name] = $t } }
    } catch { }
    Remove-Item -LiteralPath $TrimResultFile -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------
#  File helpers
# ---------------------------------------------------------------------
function Get-EntrySize($Item) {
    try {
        if ($Item -is [IO.FileInfo]) { return [double]$Item.Length }
        if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return 0 }
        $s = (Get-ChildItem -LiteralPath $Item.FullName -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($s) { return [double]$s }
    } catch { }
    return 0
}

function Get-FolderSize([string[]]$Folders) {
    $t = 0
    foreach ($f in $Folders) {
        if (-not ($f -and (Test-Path -LiteralPath $f))) { continue }
        $s = (Get-ChildItem -LiteralPath $f -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
        if ($s) { $t += $s }
    }
    return [double]$t
}

# Deletes one file or folder. Folders go through "rd /s /q", which removes
# junctions and symlinks without following them into their targets.
function Remove-Entry([IO.FileSystemInfo]$Item) {
    try {
        if ($Item -is [IO.DirectoryInfo]) {
            if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                [IO.Directory]::Delete($Item.FullName, $false)
            } else {
                & cmd.exe /d /c "rd /s /q `"$($Item.FullName)`"" 2>$null
            }
        } else {
            $Item.Attributes = 'Normal'
            $Item.Delete()
        }
    } catch { }
    return -not (Test-Path -LiteralPath $Item.FullName)
}

# Removes everything matching each path pattern, e.g. "C:\x\*" or "C:\x\*.db",
# and prints every entry. Locked or protected entries are reported and kept.
function Remove-Items([string]$Label, [string[]]$Paths) {
    $Paths = @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($Paths.Count -eq 0) { return }
    Start-Step $Label
    $targets = @()
    foreach ($p in $Paths) {
        Write-Info "scan  $(Short $p)"
        $targets += @(Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue)
    }
    if ($targets.Count -eq 0) { End-Step 'already clean'; return }
    $done = 0; $busy = 0; $bytes = 0
    foreach ($t in $targets) {
        $size = Get-EntrySize $t
        if (Remove-Entry $t) {
            $done++; $bytes += $size
            Write-Detail ('rm    {0}  ({1})' -f (Short $t.FullName), (Format-Size $size))
        } else {
            $busy++
            Write-Warn ('busy  {0}' -f (Short $t.FullName))
        }
    }
    $script:TotalFreed += $bytes
    $msg = "$done removed"
    if ($busy) { $msg += " | $busy in use" }
    $msg += " | $(Format-Size $bytes) freed"
    End-Step $msg $(if ($busy) { 'Yellow' } else { 'Green' })
}

# Clears the contents of each folder that exists (not the folder itself).
# Folders that do not exist on this machine are skipped silently.
function Clear-Folder([string]$Label, [string[]]$Folders) {
    $paths = @()
    foreach ($f in $Folders) {
        if ($f -and (Test-Path -LiteralPath $f)) { $paths += (Join-Path $f '*') }
    }
    Remove-Items $Label $paths
}

# A developer cache: use the tool's own clean command when it is installed
# for this user, otherwise delete the cache folder the tool reports or the
# vendor's default folder.
function Clear-DevCache {
    param([string]$Label, [string]$Tool, [string[]]$CleanArgs, [string[]]$Folders)
    $Folders = @($Folders | Where-Object { $_ })
    if ($Tool -and $CleanArgs -and $SameUser -and (Test-Tool $Tool)) {
        Start-Step $Label
        $existing = @($Folders | Where-Object { Test-Path -LiteralPath $_ })
        foreach ($f in $existing) { Write-Info "cache $(Short $f)" }
        $before = Get-FolderSize $existing
        $code  = Invoke-Tool $Tool $CleanArgs
        $after = Get-FolderSize $existing
        $freed = [Math]::Max(0, $before - $after)
        $script:TotalFreed += $freed
        $msg = "exit $code"
        if ($existing.Count) { $msg += " | $(Format-Size $freed) freed" }
        End-Step $msg $(if ($code -eq 0) { 'Green' } else { 'Yellow' })
        return
    }
    Clear-Folder $Label $Folders
}

# y/N question that gives up after $Seconds with no key press.
function Read-YesNo([string]$Question, [int]$Seconds) {
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } }
    catch { Write-Warn "$Question  (no keyboard available, skipped)"; return $false }
    $end = (Get-Date).AddSeconds($Seconds); $last = -1
    while ((Get-Date) -lt $end) {
        $left = [int][math]::Ceiling(($end - (Get-Date)).TotalSeconds)
        if ($left -ne $last) {
            Write-Host ("`r    |  [?] $Question [y/N] ({0,2}s) " -f $left) -ForegroundColor Yellow -NoNewline
            $last = $left
        }
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true)
            Write-Host $k.KeyChar -ForegroundColor Yellow
            return ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y')
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ''
    Write-Info 'no answer in time'
    return $false
}

function Get-FreeSpace {
    $r = [ordered]@{}
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        Sort-Object DeviceID | ForEach-Object { $r[$_.DeviceID] = [double]$_.FreeSpace }
    return $r
}

# ---------------------------------------------------------------------
#  Start
# ---------------------------------------------------------------------
Show-Banner
$RunTimer = [Diagnostics.Stopwatch]::StartNew()

$os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue
$FreeBefore = Get-FreeSpace
Write-Host ('[*] host    : {0}' -f $env:COMPUTERNAME) -ForegroundColor DarkGreen
Write-Host ('[*] user    : {0}' -f $UserProfile) -ForegroundColor DarkGreen
Write-Host ('[*] admin   : {0}' -f $(if ($IsAdmin) { 'yes' } else { 'no' })) -ForegroundColor DarkGreen
Write-Host ('[*] os      : {0} (build {1})' -f $os.Caption, $os.BuildNumber) -ForegroundColor DarkGreen
Write-Host ('[*] drives  : {0}' -f (($FreeBefore.Keys | ForEach-Object { "$_ $(Format-Size $FreeBefore[$_]) free" }) -join ' | ')) -ForegroundColor DarkGreen
Write-Host '[!] close your browsers and apps for the best result' -ForegroundColor Yellow
Write-Host '[!] WSL and Docker Desktop will be shut down to compact their disks' -ForegroundColor Yellow

# Optional log file, saved next to cleaner.bat (or in the user's profile
# if that folder is read-only). No answer in 30 s means no log.
$LogFile = $null
Write-Section 'Log'
Start-Step 'Log file'
if (Read-YesNo 'Save a log file of this run?' 30) {
    $name = 'cleaner-{0:yyyy-MM-dd_HHmmss}.log' -f (Get-Date)
    foreach ($dir in @((Split-Path -Parent $env:CLEANER_PATH), $UserProfile)) {
        if (-not $dir) { continue }
        $candidate = Join-Path $dir $name
        try {
            Start-Transcript -LiteralPath $candidate -ErrorAction Stop | Out-Null
            $LogFile = $candidate
            break
        } catch { }
    }
    if ($LogFile) { End-Step "logging to $(Short $LogFile)" } else { End-Step 'could not create a log file, continuing without' 'Yellow' }
} else {
    End-Step 'no log'
}

# ---------------------------------------------------------------------
Write-Section 'Temporary files'
# ---------------------------------------------------------------------
$tempDirs = @($UserTemp, (Join-Path $env:WINDIR 'Temp')) | Where-Object { $_ } |
            ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Select-Object -Unique
Clear-Folder 'Temp folders' $tempDirs
Clear-Folder 'Prefetch' @(Join-Path $env:WINDIR 'Prefetch')

# ---------------------------------------------------------------------
Write-Section 'Windows Update'
# ---------------------------------------------------------------------
$wuServices = 'wuauserv', 'bits'
Start-Step 'Stop update services'
foreach ($s in $wuServices) { Write-Info "stop  $s" }
Stop-Service -Name $wuServices -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
End-Step 'stopped'
Clear-Folder 'Windows Update download cache' @(Join-Path $env:WINDIR 'SoftwareDistribution\Download')
Clear-Folder 'Windows Update logs'           @(Join-Path $env:WINDIR 'SoftwareDistribution\DataStore\Logs')
Start-Step 'Start update services'
foreach ($s in $wuServices) { Write-Info "start $s" }
Start-Service -Name $wuServices -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
End-Step 'started'

$doCache = Join-Path $env:WINDIR 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
if (Test-Tool 'Delete-DeliveryOptimizationCache') {
    Start-Step 'Delivery Optimization cache'
    $before = Get-FolderSize @($doCache)
    Write-Info 'exec  Delete-DeliveryOptimizationCache -Force'
    try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop *> $null } catch { Write-Warn $_.Exception.Message }
    $freed = [Math]::Max(0, $before - (Get-FolderSize @($doCache)))
    $script:TotalFreed += $freed
    End-Step "$(Format-Size $freed) freed"
} else {
    Clear-Folder 'Delivery Optimization cache' @($doCache)
}

# ---------------------------------------------------------------------
Write-Section 'Browser caches'
# ---------------------------------------------------------------------
# Chromium browsers keep every profile under "User Data". Profiles are
# found by looking for their Preferences file, not by assuming "Default".
$chromium = [ordered]@{
    'Edge'     = 'Microsoft\Edge'
    'Chrome'   = 'Google\Chrome'
    'Brave'    = 'BraveSoftware\Brave-Browser'
    'Vivaldi'  = 'Vivaldi'
    'Chromium' = 'Chromium'
    'Yandex'   = 'Yandex\YandexBrowser'
}
foreach ($name in $chromium.Keys) {
    $userData = Join-Path $Local (Join-Path $chromium[$name] 'User Data')
    if (-not (Test-Path -LiteralPath $userData)) { continue }
    $paths = @()
    Get-ChildItem -LiteralPath $userData -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Preferences') } |
        ForEach-Object {
            foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage') {
                $d = Join-Path $_.FullName $c
                if (Test-Path -LiteralPath $d) { $paths += (Join-Path $d '*') }
            }
        }
    foreach ($c in 'GrShaderCache', 'ShaderCache') {
        $d = Join-Path $userData $c
        if (Test-Path -LiteralPath $d) { $paths += (Join-Path $d '*') }
    }
    Remove-Items "$name cache" $paths
}
# Opera keeps a flat layout per edition (Opera Stable, Opera GX Stable, ...).
Get-ChildItem -LiteralPath (Join-Path $Local 'Opera Software') -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    Clear-Folder "$($_.Name) cache" @((Join-Path $_.FullName 'Cache'), (Join-Path $_.FullName 'GPUCache'))
}
# Firefox and its forks keep the cache in the Local profile folder.
foreach ($ff in 'Mozilla\Firefox', 'Waterfox', 'LibreWolf', 'Floorp', 'zen') {
    $profiles = Join-Path $Local (Join-Path $ff 'Profiles')
    Get-ChildItem -LiteralPath $profiles -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        Clear-Folder "$(Split-Path $ff -Leaf) cache ($($_.Name))" @((Join-Path $_.FullName 'cache2'), (Join-Path $_.FullName 'startupCache'))
    }
}

# ---------------------------------------------------------------------
Write-Section 'GPU and shader caches'
# ---------------------------------------------------------------------
Clear-Folder 'DirectX shader cache' @(Join-Path $Local 'D3DSCache')
Clear-Folder 'NVIDIA shader cache'  @((Join-Path $Local 'NVIDIA\DXCache'), (Join-Path $Local 'NVIDIA\GLCache'), (Join-Path $Local 'NVIDIA Corporation\NV_Cache'))
Clear-Folder 'AMD shader cache'     @((Join-Path $Local 'AMD\DXCache'), (Join-Path $Local 'AMD\GLCache'), (Join-Path $Local 'AMD\VkCache'), (Join-Path $Local 'AMD\DxcCache'))
Clear-Folder 'Intel shader cache'   @(Join-Path $Local 'Intel\ShaderCache')

# ---------------------------------------------------------------------
Write-Section 'Windows caches and logs'
# ---------------------------------------------------------------------
$explorer = Join-Path $Local 'Microsoft\Windows\Explorer'
Remove-Items 'Thumbnail cache' @(Join-Path $explorer 'thumbcache_*.db')
Remove-Items 'Icon cache'      @(Join-Path $explorer 'iconcache_*.db')

$werUser = Join-Path $Local 'Microsoft\Windows\WER'
$werSys  = Join-Path $env:ProgramData 'Microsoft\Windows\WER'
Clear-Folder 'Error reports (user)'   @((Join-Path $werUser 'ReportQueue'), (Join-Path $werUser 'ReportArchive'), (Join-Path $werUser 'Temp'))
Clear-Folder 'Error reports (system)' @((Join-Path $werSys 'ReportQueue'), (Join-Path $werSys 'ReportArchive'), (Join-Path $werSys 'ERC'), (Join-Path $werSys 'Temp'))

$defHistory = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Scans\History'
Clear-Folder 'Defender scan history' @((Join-Path $defHistory 'Service\DetectionHistory'), (Join-Path $defHistory 'CacheManager'))

Start-Step 'Stop font cache service'
Write-Info 'stop  FontCache'
Stop-Service -Name 'FontCache' -Force -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
End-Step 'stopped'
Remove-Items 'Font cache' @((Join-Path $env:WINDIR 'ServiceProfiles\LocalService\AppData\Local\FontCache\*'), (Join-Path $env:WINDIR 'System32\FNTCACHE.DAT'))
Start-Step 'Start font cache service'
Write-Info 'start FontCache'
Start-Service -Name 'FontCache' -ErrorAction SilentlyContinue -WarningAction SilentlyContinue
End-Step 'started'

Clear-Folder 'Crash dumps (user)'   @(Join-Path $Local 'CrashDumps')
Clear-Folder 'Crash dumps (system)' @(Join-Path $env:WINDIR 'Minidump')
$memDump = Join-Path $env:WINDIR 'MEMORY.DMP'
if (Test-Path -LiteralPath $memDump) { Remove-Items 'Full memory dump' @($memDump) }

$recent = Join-Path $Roaming 'Microsoft\Windows\Recent'
Clear-Folder 'Jump lists' @((Join-Path $recent 'AutomaticDestinations'), (Join-Path $recent 'CustomDestinations'))

Clear-Folder 'Windows AI cache'    @(Join-Path $Local 'Microsoft\Windows\AIGenerated')
Clear-Folder 'Windows shell cache' @(Join-Path $Local 'Microsoft\Windows\Caches')
Clear-Folder 'Search index logs'   @(Join-Path $env:ProgramData 'Microsoft\Search\Data\Applications\Windows\GatherLogs')
Clear-Folder '.NET usage logs'     @((Join-Path $Local 'Microsoft\CLR_v2.0\UsageLogs'), (Join-Path $Local 'Microsoft\CLR_v4.0\UsageLogs'), (Join-Path $Local 'Microsoft\CLR_v4.0_32\UsageLogs'))

# ---------------------------------------------------------------------
Write-Section 'App caches'
# ---------------------------------------------------------------------
$teamsClassic = Join-Path $Roaming 'Microsoft\Teams'
Clear-Folder 'Teams (classic) cache' @((Join-Path $teamsClassic 'Cache'), (Join-Path $teamsClassic 'blob_storage'), (Join-Path $teamsClassic 'GPUCache'), (Join-Path $teamsClassic 'tmp'))
Get-ChildItem -LiteralPath (Join-Path $Local 'Packages') -Directory -Filter 'MSTeams_*' -ErrorAction SilentlyContinue | ForEach-Object {
    Clear-Folder 'Teams (new) cache' @(Join-Path $_.FullName 'LocalCache')
}
$oneDrive = Join-Path $Local 'Microsoft\OneDrive'
Clear-Folder 'OneDrive logs' @((Join-Path $oneDrive 'logs'), (Join-Path $oneDrive 'setup\logs'))

# VS Code and its forks.
$editors = 'Code', 'Code - Insiders', 'VSCodium', 'Cursor', 'Windsurf'
foreach ($ed in $editors) {
    $root = Join-Path $Roaming $ed
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Clear-Folder "$ed cache" @((Join-Path $root 'Cache'), (Join-Path $root 'CachedData'), (Join-Path $root 'Code Cache'), (Join-Path $root 'GPUCache'), (Join-Path $root 'CachedExtensionVSIXs'))
}
# Any other Electron app (Discord, Slack, Spotify, ...). They are found by
# their "Local Storage" folder, then only their cache folders are cleared.
Get-ChildItem -LiteralPath $Roaming -Directory -ErrorAction SilentlyContinue | ForEach-Object {
    $app = $_.FullName
    if ($editors -contains $_.Name) { return }
    if (-not (Test-Path -LiteralPath (Join-Path $app 'Local Storage'))) { return }
    $paths = @()
    foreach ($c in 'Cache', 'Code Cache', 'GPUCache', 'DawnCache', 'DawnGraphiteCache', 'DawnWebGPUCache') {
        $d = Join-Path $app $c
        if (Test-Path -LiteralPath $d) { $paths += (Join-Path $d '*') }
    }
    Remove-Items "$($_.Name) cache" $paths
}

# ---------------------------------------------------------------------
Write-Section 'Developer caches'
# ---------------------------------------------------------------------
# Each entry asks the tool where its cache lives, then the tool's
# environment variable, then the vendor default. A tool's own clean
# command is used whenever it is installed.

$npmCache = $null
if ($SameUser -and (Test-Tool 'npm')) { $npmCache = Get-ToolOutput 'npm' @('config', 'get', 'cache') }
Clear-DevCache 'npm cache' 'npm' @('cache', 'clean', '--force') @(
    (Join-Path (First-Set $npmCache $env:npm_config_cache (Join-Path $Local 'npm-cache')) '_cacache'))

$yarnCache = $null
if ($SameUser -and (Test-Tool 'yarn')) { $yarnCache = Get-ToolOutput 'yarn' @('cache', 'dir') }
Clear-DevCache 'Yarn cache' 'yarn' @('cache', 'clean') @((First-Set $yarnCache $env:YARN_CACHE_FOLDER (Join-Path $Local 'Yarn\Cache')))

# pnpm: only prune packages no project uses. The store itself is never deleted.
if ($SameUser -and (Test-Tool 'pnpm')) { Clear-DevCache 'pnpm store (unused packages)' 'pnpm' @('store', 'prune') @() }

Clear-DevCache 'Bun cache' 'bun' @('pm', 'cache', 'rm') @(
    (First-Set $env:BUN_INSTALL_CACHE_DIR (Join-Path (First-Set $env:BUN_INSTALL (Join-Path $UserProfile '.bun')) 'install\cache')))

Clear-Folder 'Deno npm cache' @(Join-Path (First-Set $env:DENO_DIR (Join-Path $Local 'deno')) 'npm')

# pip: every Python install shares one cache folder, so ask any pip for it.
$pipCache = $null
if ($SameUser) {
    $pipCandidates = @(
        @{ Exe = 'pip';    Args = @('cache', 'dir') },
        @{ Exe = 'py';     Args = @('-m', 'pip', 'cache', 'dir') },
        @{ Exe = 'python'; Args = @('-m', 'pip', 'cache', 'dir') }
    )
    foreach ($c in $pipCandidates) {
        if ($pipCache -or -not (Test-Tool $c.Exe)) { continue }
        $out = Get-ToolOutput $c.Exe $c.Args
        if ($out -and (Test-Path -LiteralPath $out)) { $pipCache = $out }
    }
}
Clear-Folder 'pip cache' @((First-Set $pipCache $env:PIP_CACHE_DIR (Join-Path $Local 'pip\cache')))

Clear-DevCache 'uv cache' 'uv' @('cache', 'clean') @((First-Set $env:UV_CACHE_DIR (Join-Path $Local 'uv\cache')))

$poetryCache = $null
if ($SameUser -and (Test-Tool 'poetry')) { $poetryCache = Get-ToolOutput 'poetry' @('config', 'cache-dir') }
$poetryCache = First-Set $poetryCache $env:POETRY_CACHE_DIR (Join-Path $Local 'pypoetry\Cache')
Clear-Folder 'Poetry cache' @((Join-Path $poetryCache 'cache'), (Join-Path $poetryCache 'artifacts'))

Clear-Folder 'Pipenv cache' @((First-Set $env:PIPENV_CACHE_DIR (Join-Path $Local 'pipenv\pipenv\Cache')))

if ($SameUser -and (Test-Tool 'conda')) { Clear-DevCache 'Conda packages and tarballs' 'conda' @('clean', '--all', '--yes') @() }

# NuGet: clear the download and temp caches, keep global-packages so
# projects do not need a full restore. "dotnet nuget" only exists when a
# .NET SDK is installed (the runtime alone does not have it).
$nugetHttp    = First-Set $env:NUGET_HTTP_CACHE_PATH (Join-Path $Local 'NuGet\v3-cache')
$nugetPlugins = First-Set $env:NUGET_PLUGINS_CACHE_PATH (Join-Path $Local 'NuGet\plugins-cache')
$hasDotnetSdk = $SameUser -and (Test-Tool 'dotnet') -and [bool](Get-ToolOutput 'dotnet' @('--list-sdks'))
if ($hasDotnetSdk) {
    Clear-DevCache 'NuGet HTTP cache'    'dotnet' @('nuget', 'locals', 'http-cache', '--clear')    @($nugetHttp)
    Clear-DevCache 'NuGet temp cache'    'dotnet' @('nuget', 'locals', 'temp', '--clear')          @()
    Clear-DevCache 'NuGet plugins cache' 'dotnet' @('nuget', 'locals', 'plugins-cache', '--clear') @($nugetPlugins)
} else {
    Clear-Folder 'NuGet HTTP cache'    @($nugetHttp)
    Clear-Folder 'NuGet plugins cache' @($nugetPlugins)
}

$goCache = $null
if ($SameUser -and (Test-Tool 'go')) { $goCache = Get-ToolOutput 'go' @('env', 'GOCACHE') }
Clear-DevCache 'Go build cache' 'go' @('clean', '-cache') @((First-Set $goCache $env:GOCACHE (Join-Path $Local 'go-build')))

# Cargo: downloaded .crate archives only. Extracted sources stay.
Clear-Folder 'Cargo download cache' @(Join-Path (First-Set $env:CARGO_HOME (Join-Path $UserProfile '.cargo')) 'registry\cache')

Clear-Folder 'Gradle build cache' @(Join-Path (First-Set $env:GRADLE_USER_HOME (Join-Path $UserProfile '.gradle')) 'caches\build-cache-1')

$composerCache = $null
if ($SameUser -and (Test-Tool 'composer')) { $composerCache = Get-ToolOutput 'composer' @('config', '--global', 'cache-dir') }
Clear-DevCache 'Composer cache' 'composer' @('clear-cache') @((First-Set $composerCache $env:COMPOSER_CACHE_DIR (Join-Path $Local 'Composer')))

Clear-DevCache 'Scoop download cache' 'scoop' @('cache', 'rm', '*') @(Join-Path (First-Set $env:SCOOP (Join-Path $UserProfile 'scoop')) 'cache')

$chocoRoot = First-Set $env:ChocolateyInstall (Join-Path $env:ProgramData 'chocolatey')
Clear-Folder 'Chocolatey leftovers' @((Join-Path $UserTemp 'chocolatey'), (Join-Path $chocoRoot 'lib-bad'), (Join-Path $chocoRoot 'lib-bkp'))

# winget has no cache command. Its installers download to Temp (cleaned
# above); its logs live in the App Installer package folder.
Get-ChildItem -LiteralPath (Join-Path $Local 'Packages') -Directory -Filter 'Microsoft.DesktopAppInstaller_*' -ErrorAction SilentlyContinue | ForEach-Object {
    Clear-Folder 'winget logs' @(Join-Path $_.FullName 'LocalState\DiagOutputDir')
}

Clear-Folder 'Electron download cache'         @((First-Set $env:ELECTRON_CACHE (Join-Path $Local 'electron\Cache')))
Clear-Folder 'electron-builder download cache' @((First-Set $env:ELECTRON_BUILDER_CACHE (Join-Path $Local 'electron-builder\Cache')))
Clear-Folder 'node-gyp headers cache'          @(Join-Path $Local 'node-gyp\Cache')

# ---------------------------------------------------------------------
Write-Section 'Docker'
# ---------------------------------------------------------------------
# Only asked when the Docker engine is already running. If it is not
# running there is nothing to prune, so the step is skipped.
$DockerUp = $false
if (Test-Tool 'docker') {
    Start-Step 'Unused images and build cache'
    $DockerUp = (Invoke-Timed 'docker' 'info' 20).Ok
    if (-not $DockerUp) {
        Write-Info 'engine not running'
        End-Step 'skipped'
    } elseif (Read-YesNo 'Remove unused Docker images and build cache? Containers and volumes are kept.' 60) {
        $c1 = Invoke-Tool 'docker' @('image', 'prune', '--all', '--force')
        $c2 = Invoke-Tool 'docker' @('builder', 'prune', '--all', '--force')
        End-Step ('image prune exit {0} | builder prune exit {1}' -f $c1, $c2) $(if ($c1 -eq 0 -and $c2 -eq 0) { 'Green' } else { 'Yellow' })
    } else {
        End-Step 'skipped'
    }
}

# ---------------------------------------------------------------------
Write-Section 'Virtual disks'
# ---------------------------------------------------------------------
# Disks are found, not assumed:
#   - WSL distros from the user's Lxss registry key
#   - Docker Desktop disks from its settings file (custom folder) and its default folder
#   - Hyper-V VMs that are switched off and have no checkpoints
$disks = New-Object System.Collections.Generic.List[object]
function Add-Disk([string]$Path, [string]$Source) {
    if (-not $Path) { return }
    $Path = $Path -replace '^\\\\\?\\', ''
    if ($Path -notmatch '\.vhdx?$') { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $full = [IO.Path]::GetFullPath($Path)
    foreach ($d in $disks) { if ($d.Path -eq $full) { return } }
    $disks.Add([pscustomobject]@{ Path = $full; Source = $Source })
}

Start-Step 'Discover virtual disks'
Write-Info 'scan  WSL registry (Lxss)'
$wslDistros = @(Get-WslDistros)
foreach ($w in $wslDistros) { Add-Disk $w.Vhd "WSL: $($w.Name)" }

Write-Info 'scan  Docker Desktop settings and data folders'
$dockerDirs = @(Join-Path $Local 'Docker\wsl')
foreach ($f in 'settings-store.json', 'settings.json') {
    $sf = Join-Path $Roaming (Join-Path 'Docker' $f)
    if (-not (Test-Path -LiteralPath $sf)) { continue }
    try {
        $s = Get-Content -LiteralPath $sf -Raw | ConvertFrom-Json
        foreach ($k in 'CustomWslDistroDir', 'customWslDistroDir', 'dataFolder', 'DataFolder') {
            if ($s.$k) { $dockerDirs += [string]$s.$k }
        }
    } catch { }
}
$dockerDirs += (Join-Path $env:ProgramData 'DockerDesktop\vm-data')   # older Hyper-V backend
foreach ($dir in ($dockerDirs | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    Get-ChildItem -LiteralPath $dir -Recurse -Depth 3 -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.vhdx', '.vhd' } |
        ForEach-Object { Add-Disk $_.FullName 'Docker Desktop' }
}

if (Test-Tool 'Get-VM') {
    Write-Info 'scan  Hyper-V virtual machines'
    try {
        Get-VM -ErrorAction Stop | ForEach-Object {
            $vm = $_
            if ($vm.State -ne 'Off') { Write-Warn "Hyper-V VM '$($vm.Name)' is running, its disks are skipped"; return }
            if (@(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue).Count -gt 0) { Write-Warn "Hyper-V VM '$($vm.Name)' has checkpoints, its disks are skipped"; return }
            Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue | ForEach-Object { Add-Disk $_.Path "Hyper-V: $($vm.Name)" }
        }
    } catch { Write-Warn 'Hyper-V is installed but could not be queried' }
}

$diskTotal = 0
foreach ($d in $disks) {
    $len = (Get-Item -LiteralPath $d.Path).Length
    $diskTotal += $len
    Write-Detail ('found {0}  {1}  ({2})' -f $d.Source, (Short $d.Path), (Format-Size $len))
}
End-Step ('{0} disk(s), {1} on disk' -f $disks.Count, (Format-Size $diskTotal))

if ($disks.Count -gt 0) {
    $haveWsl = ($wslDistros.Count -gt 0) -and (Test-Tool 'wsl')

    # 1. Trim. Normally done in stage 1 as the user; shown here. If stage 1
    #    did not run (started as admin directly), try it now.
    if ($haveWsl) {
        foreach ($w in $wslDistros) {
            if (-not (Test-Path -LiteralPath $w.Vhd)) { continue }
            $res = $PreTrim[$w.Name]
            if ($res) {
                Start-Step "Trim free space: $($w.Name)"
                Write-Info 'done before elevation, as your normal account'
            } else {
                if ($w.Name -like 'docker-desktop*' -and -not $DockerUp) { continue }
                Start-Step "Trim free space: $($w.Name)"
                Write-Info "exec  wsl -d $($w.Name) -u root -e /sbin/fstrim -av"
                $res = Invoke-Trim $w $DockerUp
                if (-not $res) { End-Step 'skipped'; continue }
            }
            foreach ($l in @($res.Output)) { Write-Detail "> $l" }
            if ($res.Ok) { End-Step 'trimmed' }
            else { End-Step ('trim failed (exit {0}), compacting anyway. Double-click cleaner.bat instead of "Run as administrator" so it can trim first.' -f $res.ExitCode) 'Yellow' }
        }
    }

    # 2. Release the disks.
    $dockerProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'Docker Desktop' -or $_.ProcessName -like 'com.docker.*' })
    if ($dockerProcs.Count -gt 0) {
        Start-Step 'Stop Docker Desktop'
        foreach ($p in $dockerProcs) { Write-Detail ('kill  {0} (pid {1})' -f $p.ProcessName, $p.Id) }
        $dockerProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        End-Step 'stopped'
    }
    if ($haveWsl) {
        Start-Step 'Shut down WSL'
        Write-Info 'exec  wsl --shutdown'
        $null = Invoke-Timed 'wsl.exe' '--shutdown' 60
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Process -Name 'vmmem', 'vmmemWSL' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
        Start-Sleep -Seconds 2
        End-Step 'WSL is down'
    }

    # 3. Compact with diskpart, which ships with every Windows edition.
    $saved = 0
    foreach ($d in $disks) {
        $before = (Get-Item -LiteralPath $d.Path).Length
        Start-Step "Compact $($d.Source)"
        Write-Info "disk  $(Short $d.Path)"
        Write-Info 'exec  diskpart: select vdisk / attach readonly / compact / detach'
        $dp = [IO.Path]::GetTempFileName()
        $okCompact = $false
        $out = @()
        try {
            Set-Content -LiteralPath $dp -Encoding Default -Value @("select vdisk file=`"$($d.Path)`"", 'attach vdisk readonly', 'compact vdisk')
            $out = @(& diskpart.exe /s $dp)
            $okCompact = ($LASTEXITCODE -eq 0)
        } finally {
            Set-Content -LiteralPath $dp -Encoding Default -Value @("select vdisk file=`"$($d.Path)`"", 'detach vdisk noerr')
            $null = & diskpart.exe /s $dp
            Remove-Item -LiteralPath $dp -Force -ErrorAction SilentlyContinue
        }
        # Keep diskpart's result lines, drop its banner and progress noise.
        $out | ForEach-Object { "$_".Trim() } |
            Where-Object { $_ -and $_ -notmatch 'DiskPart version|Copyright|On computer|percent completed' } |
            ForEach-Object { Write-Detail "> $_" }
        $after = (Get-Item -LiteralPath $d.Path).Length
        if ($okCompact) {
            $freed = [Math]::Max(0, $before - $after)
            $saved += $freed
            End-Step ('{0} -> {1} | {2} freed' -f (Format-Size $before), (Format-Size $after), (Format-Size $freed))
        } else {
            End-Step 'could not compact (disk in use or not a dynamic disk)' 'Yellow'
        }
    }
    $script:TotalFreed += $saved
    if ($dockerProcs.Count -gt 0) { Write-Host '[!] Docker Desktop was stopped. Start it again when you need it.' -ForegroundColor Yellow }
}

# ---------------------------------------------------------------------
Write-Section 'System cleanup'
# ---------------------------------------------------------------------
# Previous Windows installation, left behind by feature updates. Found on
# the system drive; skipped when it does not exist. Windows locks it, so
# ownership goes to the built-in Administrators group first. The group is
# named by its well-known SID, which is the same on every Windows language.
$winOld = Join-Path $env:SystemDrive 'Windows.old'
if ((Test-Path -LiteralPath $winOld) -and -not ([IO.Path]::GetFullPath($env:WINDIR).StartsWith([IO.Path]::GetFullPath($winOld), [StringComparison]::OrdinalIgnoreCase))) {
    Start-Step 'Previous Windows installation (Windows.old)'
    Write-Info "found $winOld"
    Write-Info 'after this, you cannot roll back to the previous Windows version'
    $before = Get-FolderSize @($winOld)
    Write-Info "size  $(Format-Size $before)"
    Write-Info 'exec  takeown /F <folder> /R /A /D Y'
    $null = & takeown.exe /F $winOld /R /A /D Y 2>&1
    Write-Info 'exec  icacls <folder> /grant *S-1-5-32-544:F /T /C /Q'
    $null = & icacls.exe $winOld /grant '*S-1-5-32-544:F' /T /C /Q 2>&1
    Write-Info 'exec  rd /s /q <folder>'
    & cmd.exe /d /c "rd /s /q `"$winOld`"" 2>$null
    $left = Get-FolderSize @($winOld)
    $freed = [Math]::Max(0, $before - $left)
    $script:TotalFreed += $freed
    if (Test-Path -LiteralPath $winOld) { End-Step ("partly removed | {0} freed | {1} left (in use)" -f (Format-Size $freed), (Format-Size $left)) 'Yellow' }
    else { End-Step "removed | $(Format-Size $freed) freed" }
}

Start-Step 'Recycle Bin (all drives)'
Write-Info 'exec  Clear-RecycleBin -Force'
Clear-RecycleBin -Force -ErrorAction SilentlyContinue
End-Step 'emptied'

Start-Step 'Event logs'
$logs = @(& wevtutil.exe el 2>$null)
Write-Info "found $($logs.Count) logs"
$n = 0; $failed = @()
foreach ($l in $logs) {
    & wevtutil.exe cl "$l" 2>$null
    if ($LASTEXITCODE -eq 0) { $n++ } else { $failed += $l }
}
foreach ($f in $failed) { Write-Warn "kept  $f (protected)" }
End-Step "cleared $n of $($logs.Count)"

Start-Step 'DNS cache'
Write-Info 'exec  ipconfig /flushdns'
$null = & ipconfig.exe /flushdns
End-Step 'flushed'

# Storage Sense keeps cleaning between runs. It is turned on for the user
# being cleaned (their own registry hive, found by SID), with:
#   - temporary files cleanup on
#   - Recycle Bin cleanup after 60 days, the longest option Windows offers
#     (Settings > System > Storage > Storage Sense lists 1, 14, 30, 60 days)
# Downloads cleanup and the run schedule are left as the user set them.
# The value names below are Windows' own Storage Sense settings.
Start-Step 'Storage Sense settings'
$ssPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\StorageSense'
$ssPolicy    = Get-ItemProperty -Path $ssPolicyKey -ErrorAction SilentlyContinue
$ssKey       = Join-Path $UserHive 'Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
if ($ssPolicy -and $null -ne $ssPolicy.AllowStorageSenseGlobal -and $ssPolicy.AllowStorageSenseGlobal -eq 0) {
    Write-Warn 'Storage Sense is turned off by a system policy (managed PC), leaving it alone'
    End-Step 'skipped' 'Yellow'
} else {
    if (-not (Test-Path $ssKey)) { $null = New-Item -Path $ssKey -ErrorAction SilentlyContinue }
    $current = Get-ItemProperty -Path $ssKey -ErrorAction SilentlyContinue
    $wanted = [ordered]@{
        '01'  = @{ Value = 1;  Label = 'Storage Sense' }
        '04'  = @{ Value = 1;  Label = 'delete temporary files' }
        '08'  = @{ Value = 1;  Label = 'Recycle Bin cleanup' }
        '256' = @{ Value = 60; Label = 'Recycle Bin age (days)' }
    }
    $changed = 0
    foreach ($name in $wanted.Keys) {
        $old = $current.$name
        $new = $wanted[$name].Value
        try {
            Set-ItemProperty -Path $ssKey -Name $name -Value $new -Type DWord -ErrorAction Stop
            $oldText = if ($null -eq $old) { 'unset' } else { $old }
            if ("$old" -ne "$new") { $changed++ }
            Write-Info ('{0,-24} {1} -> {2}' -f $wanted[$name].Label, $oldText, $new)
        } catch { Write-Warn "could not set $($wanted[$name].Label): $($_.Exception.Message)" }
    }
    if ($ssPolicy -and $null -ne $ssPolicy.ConfigStorageSenseRecycleBinCleanupThreshold) {
        Write-Warn ('a system policy sets the Recycle Bin age to {0} days and overrides this' -f $ssPolicy.ConfigStorageSenseRecycleBinCleanupThreshold)
    }
    End-Step ('on | {0} setting(s) changed' -f $changed)
}

Start-Step 'Run Storage Sense now'
Write-Info 'exec  scheduled task \Microsoft\Windows\DiskFootprint\StorageSense'
try { Start-ScheduledTask -TaskPath '\Microsoft\Windows\DiskFootprint\' -TaskName 'StorageSense' -ErrorAction Stop; End-Step 'triggered' }
catch { End-Step 'not available on this system' 'Yellow' }

# /ResetBase removes the old copies of updated Windows components. It frees
# more space than a plain cleanup, but installed updates can no longer be
# uninstalled afterwards.
Start-Step 'Windows component store (can take several minutes)'
Write-Info 'exec  dism /online /Cleanup-Image /StartComponentCleanup /ResetBase'
Write-Info 'after this, installed Windows updates can no longer be uninstalled'
& dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase /Quiet
End-Step ("exit {0}" -f $LASTEXITCODE) $(if ($LASTEXITCODE -eq 0) { 'Green' } else { 'Yellow' })

# ---------------------------------------------------------------------
Write-Section 'SSD TRIM'
# ---------------------------------------------------------------------
# Runs last, after everything above has freed space. Every fixed drive
# with a letter is checked; TRIM is sent only to drives on an SSD. Drives
# whose type Windows cannot tell (some VMs, RAID) are tried as well, and
# drives that do not support TRIM simply report so.
if (Test-Tool 'Optimize-Volume') {
    $volumes = @(Get-Volume -ErrorAction SilentlyContinue |
                 Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter -and $_.FileSystem -in 'NTFS', 'ReFS' } |
                 Sort-Object DriveLetter)
    foreach ($v in $volumes) {
        $letter = [string]$v.DriveLetter
        $media = 'Unspecified'
        try {
            $diskNo = (Get-Partition -DriveLetter $letter -ErrorAction Stop | Select-Object -First 1).DiskNumber
            $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { [string]$_.DeviceId -eq [string]$diskNo } | Select-Object -First 1
            if ($pd) { $media = [string]$pd.MediaType }
        } catch { }
        if ($media -eq 'HDD') { continue }
        Start-Step "TRIM ${letter}:"
        Write-Info ('drive {0}: {1}, {2}' -f $letter, $media, $v.FileSystem)
        Write-Info "exec  Optimize-Volume -DriveLetter $letter -ReTrim"
        try {
            $msgs = @(Optimize-Volume -DriveLetter $letter -ReTrim -Verbose -ErrorAction Stop 4>&1 | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
            foreach ($m in ($msgs | Select-Object -Last 3)) { Write-Detail "> $m" }
            End-Step 'trimmed'
        } catch {
            Write-Detail "> $($_.Exception.Message)"
            End-Step 'TRIM not supported on this drive' 'Yellow'
        }
    }
}

# ---------------------------------------------------------------------
Write-Section 'Summary'
# ---------------------------------------------------------------------
$FreeAfter = Get-FreeSpace
foreach ($k in $FreeAfter.Keys) {
    $b = $FreeBefore[$k]; $a = $FreeAfter[$k]
    $diff = $a - $b
    $gain = if ($diff -gt 0) { "  (+$(Format-Size $diff))" } else { '' }
    Write-Host ('[+] {0}  {1} -> {2} free{3}' -f $k, (Format-Size $b), (Format-Size $a), $gain) -ForegroundColor Green
}
Write-Host ('[+] measured by the steps above: {0}' -f (Format-Size $script:TotalFreed)) -ForegroundColor Green
Write-Host ('[+] {0} steps in {1:mm\:ss}' -f $script:StepNo, $RunTimer.Elapsed) -ForegroundColor Green
Write-Host '[+] done' -ForegroundColor Green
if ($LogFile) {
    Write-Host ('[+] log saved: {0}' -f $LogFile) -ForegroundColor Green
    try { Stop-Transcript | Out-Null } catch { }
}
