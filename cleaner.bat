@echo off
setlocal enabledelayedexpansion

:: =============================
:: Check for Admin Privileges
:: =============================
>nul 2>&1 "%SYSTEMROOT%\system32\icacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting administrative privileges...
    goto UACPrompt
) else (
    goto gotAdmin
)

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )
    pushd "%CD%"
    CD /D "%~dp0"

:: =============================
:: Main Cleanup Script
:: =============================
echo.
echo ================================================
echo   Cleaner - 2026
echo ================================================
echo.

:: ---- TEMP FILES ----
call :CleanupTask "User Temp Files"          "%TEMP%\*.*"
call :CleanupTask "LocalAppData Temp"        "%LOCALAPPDATA%\Temp\*.*"
call :CleanupTask "System Temp"              "C:\Windows\Temp\*.*"
call :CleanupTask "Prefetch Cache"           "C:\Windows\Prefetch\*.*"

:: ---- WINDOWS UPDATE (stop services FIRST) ----
call :StopUpdateServices
call :CleanupTask "WU Download Cache"        "C:\Windows\SoftwareDistribution\Download\*.*"
call :CleanupTask "WU Transaction Logs"      "C:\Windows\SoftwareDistribution\DataStore\Logs\*.*"
call :StartUpdateServices

:: ---- DELIVERY OPTIMIZATION ----
echo Clearing Delivery Optimization Cache...
powershell -NoProfile -NonInteractive -Command "Delete-DeliveryOptimizationCache -Force" >nul 2>&1
if errorlevel 1 (
    call :CleanupTask "DO Cache (fallback)"  "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*.*"
)
echo [OK] Delivery Optimization Cache cleared.

:: ---- BROWSER CACHES ----
call :CleanupTask "Edge Cache"               "%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Cache\*"  "%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\Code Cache\*"  "%LOCALAPPDATA%\Microsoft\Edge\User Data\Default\GPUCache\*"
call :CleanupTask "Chrome Cache"             "%LOCALAPPDATA%\Google\Chrome\User Data\Default\Cache\*"  "%LOCALAPPDATA%\Google\Chrome\User Data\Default\Code Cache\*"  "%LOCALAPPDATA%\Google\Chrome\User Data\Default\GPUCache\*"
call :CleanupTask "Brave Cache"              "%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Cache\*"  "%LOCALAPPDATA%\BraveSoftware\Brave-Browser\User Data\Default\Code Cache\*"

:: Firefox stores cache inside profile folders — target cache2\entries specifically
for /D %%P in ("%APPDATA%\Mozilla\Firefox\Profiles\*") do (
    if exist "%%P\cache2\entries" (
        echo Clearing Firefox Cache for profile %%~nxP...
        del /q /f /s "%%P\cache2\entries\*" 2>nul
    )
)

:: ---- GPU / SHADER CACHES ----
call :CleanupTask "DirectX Shader Cache"     "%LOCALAPPDATA%\D3DSCache\*.*"
call :CleanupTask "NVIDIA DXCache"           "%LOCALAPPDATA%\NVIDIA\DXCache\*.*"
call :CleanupTask "AMD DXCache"              "%LOCALAPPDATA%\AMD\DXCache\*.*"
call :CleanupTask "Intel ShaderCache"        "%LOCALAPPDATA%\Intel\ShaderCache\*.*"

:: ---- THUMBNAIL & ICON CACHES ----
call :CleanupTask "Thumbnail Cache"          "%LOCALAPPDATA%\Microsoft\Windows\Explorer\thumbcache_*.db"
call :CleanupTask "Icon Cache"               "%LOCALAPPDATA%\Microsoft\Windows\Explorer\iconcache_*.db"

:: ---- WINDOWS ERROR REPORTING ----
call :CleanupTask "WER User Reports"         "%LOCALAPPDATA%\Microsoft\Windows\WER\ReportQueue\*"  "%LOCALAPPDATA%\Microsoft\Windows\WER\ReportArchive\*"  "%LOCALAPPDATA%\Microsoft\Windows\WER\Temp\*"
call :CleanupTask "WER System Reports"       "C:\ProgramData\Microsoft\Windows\WER\ReportQueue\*"  "C:\ProgramData\Microsoft\Windows\WER\ReportArchive\*"  "C:\ProgramData\Microsoft\Windows\WER\ERC\*"

:: ---- WINDOWS DEFENDER LOGS ----
call :CleanupTask "Defender Scan History"    "C:\ProgramData\Microsoft\Windows Defender\Scans\History\Service\DetectionHistory\*"  "C:\ProgramData\Microsoft\Windows Defender\Scans\History\CacheManager\*"

:: ---- FONT CACHE (stop service first, Win11 only uses "FontCache") ----
call :RebuildFontCache

:: ---- TEAMS CACHE ----
call :CleanupTask "Teams Classic Cache"      "%APPDATA%\Microsoft\Teams\Cache\*"  "%APPDATA%\Microsoft\Teams\blob_storage\*"  "%APPDATA%\Microsoft\Teams\GPUCache\*"  "%APPDATA%\Microsoft\Teams\tmp\*"
call :CleanupTask "Teams New Cache"          "%LOCALAPPDATA%\Packages\MSTeams_8wekyb3d8bbwe\LocalCache\*"

:: ---- ONEDRIVE LOGS (NOT synced data) ----
call :CleanupTask "OneDrive Logs"            "%LOCALAPPDATA%\Microsoft\OneDrive\logs\*"  "%LOCALAPPDATA%\Microsoft\OneDrive\setup\logs\*"

:: ---- CRASH DUMPS ----
call :CleanupTask "User CrashDumps"          "%LOCALAPPDATA%\CrashDumps\*"
call :CleanupTask "System Minidumps"         "C:\Windows\Minidump\*.*"
if exist "C:\Windows\MEMORY.DMP" del /f /q "C:\Windows\MEMORY.DMP"

:: ---- JUMP LISTS / RECENT CACHE ----
call :CleanupTask "Jump List Cache"          "%APPDATA%\Microsoft\Windows\Recent\AutomaticDestinations\*"  "%APPDATA%\Microsoft\Windows\Recent\CustomDestinations\*"

:: ---- AI / COPILOT CACHE (Win11 23H2+) ----
call :CleanupTask "Windows AI Cache"         "%LOCALAPPDATA%\Microsoft\Windows\AIGenerated\*"
call :CleanupTask "Windows Shell Caches"     "%LOCALAPPDATA%\Microsoft\Windows\Caches\*"

:: ---- WINDOWS SEARCH INDEX LOGS ----
call :CleanupTask "Search Index Logs"        "C:\ProgramData\Microsoft\Search\Data\Applications\Windows\GatherLogs\*"

:: ---- .NET RUNTIME CACHE (large on dev machines) ----
call :CleanupTask ".NET CLR Opt Cache"       "%LOCALAPPDATA%\Microsoft\CLR_v2.0\*"  "%LOCALAPPDATA%\Microsoft\CLR_v4.0\*"

:: ---- VS CODE CACHE ----
call :CleanupTask "VS Code Cache"            "%APPDATA%\Code\Cache\*"  "%APPDATA%\Code\CachedData\*"  "%APPDATA%\Code\GPUCache\*"

:: ---- SPECIAL OPERATIONS ----
call :ClearRecycleBin
call :ClearEventLogs
call :ClearDNSCache
call :TriggerStorageSense
call :RunDISMCleanup

echo.
echo ================================================
echo         Cleanup completed successfully!
echo ================================================
echo.
pause
exit /b 0


:: ======================================================
:: SUBROUTINES
:: ======================================================

:CleanupTask
echo Clearing %~1...
for %%a in (%*) do (
    if not "%%a"=="%~1" (
        del /q /f /s "%%a" 2>nul
    )
)
goto :eof

:StopUpdateServices
echo Stopping Windows Update services...
net stop wuauserv >nul 2>&1
net stop bits >nul 2>&1
goto :eof

:StartUpdateServices
echo Restarting Windows Update services...
net start bits >nul 2>&1
net start wuauserv >nul 2>&1
goto :eof

:ClearRecycleBin
echo Clearing Recycle Bin...
powershell -NoProfile -NonInteractive -Command "Clear-RecycleBin -Force -ErrorAction SilentlyContinue" >nul 2>&1
echo [OK] Recycle Bin cleared.
goto :eof

:ClearEventLogs
echo Clearing Event Logs...
for /F "tokens=*" %%G in ('wevtutil el') do (wevtutil cl "%%G" 2>nul)
echo [OK] Event Logs cleared.
goto :eof

:ClearDNSCache
echo Clearing DNS Cache...
ipconfig /flushdns >nul
echo [OK] DNS Cache flushed.
goto :eof

:RebuildFontCache
echo Rebuilding Font Cache...
net stop FontCache >nul 2>&1
del /f /q "%WINDIR%\ServiceProfiles\LocalService\AppData\Local\FontCache\*" 2>nul
del /f /q "%WINDIR%\System32\FNTCACHE.DAT" 2>nul
net start FontCache >nul 2>&1
echo [OK] Font Cache rebuilt.
goto :eof

:TriggerStorageSense
echo Triggering Storage Sense...
powershell -NoProfile -NonInteractive -Command "Start-ScheduledTask -TaskPath '\Microsoft\Windows\DiskFootprint\' -TaskName 'StorageSense'" >nul 2>&1
echo [OK] Storage Sense triggered.
goto :eof

:RunDISMCleanup
echo Running DISM Component Store Cleanup ^(may take a few minutes^)...
dism /online /Cleanup-Image /StartComponentCleanup /Quiet
echo [OK] DISM Cleanup done.
goto :eof