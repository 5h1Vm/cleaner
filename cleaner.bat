<# : cleaner.bat - batch launcher. The PowerShell part starts after the closing comment tag.
@echo off
setlocal
set "CLEANER_PATH=%~f0"
set "CLEANER_ARGS=%*"
if /i "%~1"=="/dry" goto run
if /i "%~1"=="/?" goto run
fltmc >nul 2>&1 && goto run
echo Requesting administrator rights...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value; try { Start-Process -FilePath $env:CLEANER_PATH -ArgumentList ('/user:' + $s) -Verb RunAs -ErrorAction Stop } catch { Write-Host 'Administrator rights were not granted. Nothing was cleaned.'; Start-Sleep -Seconds 5 }"
exit /b
:run
powershell -NoProfile -ExecutionPolicy Bypass -Command "& ([scriptblock]::Create([IO.File]::ReadAllText($env:CLEANER_PATH)))"
echo.
pause
exit /b
#>

# =====================================================================
#  Cleaner for Windows 10 / 11
#  https://github.com/5h1Vm/cleaner
#
#  Double-click cleaner.bat. It asks for admin rights, then runs below.
#  cleaner.bat /dry   shows what would be cleaned, changes nothing
#  cleaner.bat /?     shows help
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
$Version = '2.0.0'

$ArgText = [string]$env:CLEANER_ARGS
$DryRun  = $ArgText -match '(^|\s)[/-]dry(\s|$)'

if ($ArgText -match '(^|\s)[/-](\?|h|help)(\s|$)') {
    Write-Host "Cleaner $Version"
    Write-Host ''
    Write-Host '  cleaner.bat         clean everything (asks for admin rights)'
    Write-Host '  cleaner.bat /dry    show what would be cleaned, change nothing'
    Write-Host '  cleaner.bat /?      this help'
    return
}

# ---------------------------------------------------------------------
#  Who are we cleaning for?
#  When a standard user elevates with another admin account, the
#  elevated process has the admin's profile. The launcher passes the
#  original user's SID so we clean the right profile.
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

# ---------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------
function Write-Section([string]$t) { Write-Host ''; Write-Host "== $t" -ForegroundColor Cyan }
function Write-Step([string]$t)    { Write-Host "  - $t" }
function Write-Note([string]$t)    { Write-Host "      $t" -ForegroundColor DarkGray }

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return ('{0:N2} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    return ('{0:N0} KB' -f ($b / 1KB))
}

# Returns the first argument that is not empty.
function First-Set { foreach ($a in $args) { if ($a) { return $a } }; return $null }

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

# Removes everything matching each path pattern, e.g. "C:\x\*" or "C:\x\*.db".
# Locked or protected files are skipped quietly.
function Remove-Items([string]$Label, [string[]]$Paths) {
    $targets = @()
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $targets += @(Get-ChildItem -Path $p -Force -ErrorAction SilentlyContinue)
    }
    if ($targets.Count -eq 0) { return }
    Write-Step $Label
    if ($DryRun) { Write-Note "would remove $($targets.Count) item(s)"; return }
    $done = 0
    foreach ($t in $targets) { if (Remove-Entry $t) { $done++ } }
    $left = $targets.Count - $done
    if ($left -gt 0) { Write-Note "removed $done, skipped $left in use" } else { Write-Note "removed $done" }
}

# Contents of each folder (not the folder itself).
function Clear-Folder([string]$Label, [string[]]$Folders) {
    $paths = @()
    foreach ($f in $Folders) {
        if ($f -and (Test-Path -LiteralPath $f)) { $paths += (Join-Path $f '*') }
    }
    Remove-Items $Label $paths
}

function Test-Tool([string]$Name) { return [bool](Get-Command $Name -ErrorAction SilentlyContinue) }

# Runs a command quietly and returns its trimmed text output.
function Get-ToolOutput([string]$Name, [string[]]$Arguments) {
    try { return ((& $Name @Arguments 2>$null | Out-String).Trim()) } catch { return $null }
}

# Runs a program with a time limit. Returns $true if it exited with code 0.
function Invoke-Timed([string]$File, [string]$Arguments, [int]$Seconds) {
    $o = [IO.Path]::GetTempFileName(); $e = [IO.Path]::GetTempFileName()
    try {
        $p = Start-Process -FilePath $File -ArgumentList $Arguments -NoNewWindow -PassThru `
             -RedirectStandardOutput $o -RedirectStandardError $e -ErrorAction Stop
        if (-not $p.WaitForExit($Seconds * 1000)) { try { $p.Kill() } catch { }; return $false }
        return ($p.ExitCode -eq 0)
    } catch { return $false }
    finally { Remove-Item $o, $e -Force -ErrorAction SilentlyContinue }
}

# A developer cache: use the tool's own clean command when it is installed
# for this user, otherwise delete the cache folder the tool reports or the
# vendor's default folder.
function Clear-DevCache {
    param([string]$Label, [string]$Tool, [string[]]$CleanArgs, [string[]]$Folders)
    if ($Tool -and $CleanArgs -and $SameUser -and (Test-Tool $Tool)) {
        Write-Step "$Label ($Tool $($CleanArgs -join ' '))"
        if ($DryRun) { Write-Note 'would run the tool''s clean command'; return }
        $null = Get-ToolOutput $Tool $CleanArgs
        Write-Note 'done'
        return
    }
    Clear-Folder $Label $Folders
}

# y/N question that gives up after $Seconds with no key press.
function Read-YesNo([string]$Question, [int]$Seconds) {
    try { while ([Console]::KeyAvailable) { [void][Console]::ReadKey($true) } }
    catch { Write-Note "$Question  (no keyboard available, skipped)"; return $false }
    $end = (Get-Date).AddSeconds($Seconds); $last = -1
    while ((Get-Date) -lt $end) {
        $left = [int][math]::Ceiling(($end - (Get-Date)).TotalSeconds)
        if ($left -ne $last) { Write-Host ("`r    $Question [y/N] ({0,2}s) " -f $left) -NoNewline; $last = $left }
        if ([Console]::KeyAvailable) {
            $k = [Console]::ReadKey($true); Write-Host $k.KeyChar
            return ($k.KeyChar -eq 'y' -or $k.KeyChar -eq 'Y')
        }
        Start-Sleep -Milliseconds 100
    }
    Write-Host ''; Write-Note 'No answer, skipped.'
    return $false
}

function Get-FreeSpace {
    $r = @{}
    Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue |
        ForEach-Object { $r[$_.DeviceID] = [double]$_.FreeSpace }
    return $r
}

# ---------------------------------------------------------------------
#  Start
# ---------------------------------------------------------------------
Write-Host ''
Write-Host '================================================'
Write-Host "  Cleaner $Version"
if ($DryRun) { Write-Host '  DRY RUN: nothing will be changed' -ForegroundColor Yellow }
Write-Host '================================================'
Write-Host "  User: $UserProfile"
if (-not $IsAdmin -and -not $DryRun) {
    Write-Host '  Not running as administrator. Double-click cleaner.bat to elevate.' -ForegroundColor Red
    return
}
if (-not $DryRun) {
    Write-Host '  Close your browsers and apps for the best result.'
    Write-Host '  WSL and Docker Desktop will be shut down to compact their disks.'
}
$FreeBefore = Get-FreeSpace

# ---------------------------------------------------------------------
Write-Section 'Temporary files'
# ---------------------------------------------------------------------
$tempDirs = @($UserTemp, (Join-Path $env:WINDIR 'Temp')) | Where-Object { $_ } |
            ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Select-Object -Unique
Clear-Folder 'Temp folders' $tempDirs
Clear-Folder 'Prefetch' @(Join-Path $env:WINDIR 'Prefetch')

# ---------------------------------------------------------------------
Write-Section 'Windows Update and Delivery Optimization'
# ---------------------------------------------------------------------
$wuServices = 'wuauserv', 'bits'
if (-not $DryRun) { Stop-Service -Name $wuServices -Force -ErrorAction SilentlyContinue }
Clear-Folder 'Windows Update download cache' @(Join-Path $env:WINDIR 'SoftwareDistribution\Download')
Clear-Folder 'Windows Update logs'           @(Join-Path $env:WINDIR 'SoftwareDistribution\DataStore\Logs')
if (-not $DryRun) { Start-Service -Name $wuServices -ErrorAction SilentlyContinue }

$doCache = Join-Path $env:WINDIR 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache'
if ($DryRun) { Write-Step 'Delivery Optimization cache'; Write-Note 'would clear' }
else {
    $ok = $false
    if (Test-Tool 'Delete-DeliveryOptimizationCache') {
        try { Delete-DeliveryOptimizationCache -Force -ErrorAction Stop | Out-Null; $ok = $true } catch { }
    }
    if ($ok) { Write-Step 'Delivery Optimization cache'; Write-Note 'done' }
    else     { Clear-Folder 'Delivery Optimization cache' @($doCache) }
}

# ---------------------------------------------------------------------
Write-Section 'Browser caches (all profiles)'
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

if ($DryRun) { Write-Step 'Font cache'; Write-Note 'would rebuild' }
else {
    Stop-Service -Name 'FontCache' -Force -ErrorAction SilentlyContinue
    Remove-Items 'Font cache' @((Join-Path $env:WINDIR 'ServiceProfiles\LocalService\AppData\Local\FontCache\*'), (Join-Path $env:WINDIR 'System32\FNTCACHE.DAT'))
    Start-Service -Name 'FontCache' -ErrorAction SilentlyContinue
}

Clear-Folder 'Crash dumps (user)'   @(Join-Path $Local 'CrashDumps')
Clear-Folder 'Crash dumps (system)' @(Join-Path $env:WINDIR 'Minidump')
Remove-Items 'Full memory dump'     @(Join-Path $env:WINDIR 'MEMORY.DMP')

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

# NuGet: clear the download and temp caches. global-packages is kept so
# projects do not need a full restore.
if ($SameUser -and (Test-Tool 'dotnet')) {
    Clear-DevCache 'NuGet HTTP cache'    'dotnet' @('nuget', 'locals', 'http-cache', '--clear')    @()
    Clear-DevCache 'NuGet temp cache'    'dotnet' @('nuget', 'locals', 'temp', '--clear')          @()
    Clear-DevCache 'NuGet plugins cache' 'dotnet' @('nuget', 'locals', 'plugins-cache', '--clear') @()
} else {
    Clear-Folder 'NuGet HTTP cache' @((First-Set $env:NUGET_HTTP_CACHE_PATH (Join-Path $Local 'NuGet\v3-cache')), (Join-Path $Local 'NuGet\plugins-cache'))
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
$DockerUp = $false
if (Test-Tool 'docker') {
    $DockerUp = Invoke-Timed 'docker' 'info' 20
    if (-not $DockerUp) { Write-Step 'Docker engine is not running, skipping image cleanup' }
    elseif ($DryRun) { Write-Step 'Would ask: remove unused Docker images and build cache?' }
    elseif (Read-YesNo 'Remove unused Docker images and build cache? Containers and volumes are kept.' 60) {
        Write-Step 'Removing unused images'; $null = Get-ToolOutput 'docker' @('image', 'prune', '--all', '--force')
        Write-Step 'Removing build cache';   $null = Get-ToolOutput 'docker' @('builder', 'prune', '--all', '--force')
    }
} else { Write-Step 'Docker is not installed' }

# ---------------------------------------------------------------------
Write-Section 'Virtual disk compaction'
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

$wslDistros = @()
$lxss = Join-Path $UserHive 'Software\Microsoft\Windows\CurrentVersion\Lxss'
if (Test-Path $lxss) {
    Get-ChildItem $lxss -ErrorAction SilentlyContinue | ForEach-Object {
        $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
        if (-not $p.BasePath) { return }
        $vhdName = if ($p.VhdFileName) { $p.VhdFileName } else { 'ext4.vhdx' }
        $vhd = Join-Path ($p.BasePath -replace '^\\\\\?\\', '') $vhdName
        $wslDistros += [pscustomobject]@{ Name = $p.DistributionName; Vhd = $vhd }
        Add-Disk $vhd "WSL: $($p.DistributionName)"
    }
}

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
    try {
        Get-VM -ErrorAction Stop | ForEach-Object {
            $vm = $_
            if ($vm.State -ne 'Off') { Write-Note "Hyper-V VM '$($vm.Name)' is running, its disks are skipped"; return }
            if (@(Get-VMSnapshot -VM $vm -ErrorAction SilentlyContinue).Count -gt 0) { Write-Note "Hyper-V VM '$($vm.Name)' has checkpoints, its disks are skipped"; return }
            Get-VMHardDiskDrive -VM $vm -ErrorAction SilentlyContinue | ForEach-Object { Add-Disk $_.Path "Hyper-V: $($vm.Name)" }
        }
    } catch { }
}

if ($disks.Count -eq 0) {
    Write-Step 'No virtual disks found'
} elseif ($DryRun) {
    foreach ($d in $disks) { Write-Step "$($d.Source): $($d.Path) ($(Format-Size (Get-Item -LiteralPath $d.Path).Length))" }
    Write-Note 'would trim, shut down WSL and Docker, then compact each disk'
} else {
    $haveWsl = ($wslDistros.Count -gt 0) -and (Test-Tool 'wsl')

    # 1. Trim: tell each Linux filesystem which blocks are free, so the
    #    compaction can actually return them to Windows.
    if ($haveWsl) {
        foreach ($w in $wslDistros) {
            if (-not (Test-Path -LiteralPath $w.Vhd)) { continue }   # WSL 1 distro, no disk
            if ($w.Name -like 'docker-desktop*' -and -not $DockerUp) { continue }
            Write-Step "Trimming free space in $($w.Name)"
            if (-not (Invoke-Timed 'wsl.exe' "-d `"$($w.Name)`" -u root -e fstrim -av" 120)) { Write-Note 'could not trim (continuing)' }
        }
    }

    # 2. Release the disks.
    $dockerProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -eq 'Docker Desktop' -or $_.ProcessName -like 'com.docker.*' })
    if ($dockerProcs.Count -gt 0) { Write-Step 'Stopping Docker Desktop'; $dockerProcs | Stop-Process -Force -ErrorAction SilentlyContinue }
    if ($haveWsl) {
        Write-Step 'Shutting down WSL'
        $null = Invoke-Timed 'wsl.exe' '--shutdown' 60
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Process -Name 'vmmem', 'vmmemWSL' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 1 }
        Start-Sleep -Seconds 2
    }

    # 3. Compact with diskpart, which ships with every Windows edition.
    $saved = 0
    foreach ($d in $disks) {
        $before = (Get-Item -LiteralPath $d.Path).Length
        Write-Step "$($d.Source) ($(Format-Size $before))"
        $dp = [IO.Path]::GetTempFileName()
        $okCompact = $false
        try {
            Set-Content -LiteralPath $dp -Encoding Default -Value @("select vdisk file=`"$($d.Path)`"", 'attach vdisk readonly', 'compact vdisk')
            $null = & diskpart.exe /s $dp
            $okCompact = ($LASTEXITCODE -eq 0)
        } finally {
            Set-Content -LiteralPath $dp -Encoding Default -Value @("select vdisk file=`"$($d.Path)`"", 'detach vdisk noerr')
            $null = & diskpart.exe /s $dp
            Remove-Item -LiteralPath $dp -Force -ErrorAction SilentlyContinue
        }
        $after = (Get-Item -LiteralPath $d.Path).Length
        if ($okCompact) {
            $saved += ($before - $after)
            Write-Note "$(Format-Size $before) -> $(Format-Size $after)"
        } else {
            Write-Note 'could not compact (disk in use or not a dynamic disk)'
        }
    }
    if ($saved -gt 0) { Write-Note "Compaction freed $(Format-Size $saved)" }
    if ($dockerProcs.Count -gt 0) { Write-Note 'Docker Desktop was stopped. Start it again when you need it.' }
}

# ---------------------------------------------------------------------
Write-Section 'System cleanup'
# ---------------------------------------------------------------------
Write-Step 'Recycle Bin'
if ($DryRun) { Write-Note 'would empty' } else { Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Write-Note 'emptied' }

Write-Step 'Event logs'
$logs = @(& wevtutil.exe el 2>$null)
if ($DryRun) { Write-Note "would clear $($logs.Count) logs" }
else {
    $n = 0
    foreach ($l in $logs) { & wevtutil.exe cl "$l" 2>$null; if ($LASTEXITCODE -eq 0) { $n++ } }
    Write-Note "cleared $n of $($logs.Count)"
}

Write-Step 'DNS cache'
if ($DryRun) { Write-Note 'would flush' } else { $null = & ipconfig.exe /flushdns; Write-Note 'flushed' }

Write-Step 'Storage Sense'
if ($DryRun) { Write-Note 'would trigger' }
else {
    try { Start-ScheduledTask -TaskPath '\Microsoft\Windows\DiskFootprint\' -TaskName 'StorageSense' -ErrorAction Stop; Write-Note 'triggered' }
    catch { Write-Note 'not available on this system' }
}

Write-Step 'Windows component store (DISM, can take a few minutes)'
if ($DryRun) { Write-Note 'would run DISM /StartComponentCleanup' }
else { & dism.exe /online /Cleanup-Image /StartComponentCleanup /Quiet; Write-Note 'done' }

# ---------------------------------------------------------------------
#  Summary
# ---------------------------------------------------------------------
Write-Host ''
Write-Host '================================================'
if ($DryRun) {
    Write-Host '  Dry run finished. Nothing was changed.'
} else {
    Write-Host '  Cleanup finished. Free space now:'
    $FreeAfter = Get-FreeSpace
    foreach ($k in ($FreeAfter.Keys | Sort-Object)) {
        $diff = $FreeAfter[$k] - $FreeBefore[$k]
        $gain = if ($diff -gt 0) { " (+$(Format-Size $diff))" } else { '' }
        Write-Host "    $k $(Format-Size $FreeAfter[$k])$gain"
    }
}
Write-Host '================================================'
