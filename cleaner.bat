@echo off
setlocal enabledelayedexpansion

:: Check for administrative privileges and self-elevate if necessary
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting administrative privileges...
    goto UACPrompt
) else ( goto gotAdmin )

:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\getadmin.vbs"
    "%temp%\getadmin.vbs"
    exit /B

:gotAdmin
    if exist "%temp%\getadmin.vbs" ( del "%temp%\getadmin.vbs" )
    pushd "%CD%"
    CD /D "%~dp0"

echo Running comprehensive cleanup script...

:: Clear temp folders
echo Clearing temp folders...
del /q /f /s "%TEMP%\*.*"
del /q /f /s "C:\Windows\Temp\*.*"

:: Clear Prefetch
echo Clearing Prefetch...
del /q /f /s "C:\Windows\Prefetch\*.*"

:: Clear Windows Update Cache
echo Clearing Windows Update Cache...
net stop wuauserv
net stop bits
del /q /f /s "C:\Windows\SoftwareDistribution\*.*"
net start wuauserv
net start bits

:: Clear Delivery Optimization Files
echo Clearing Delivery Optimization files...
del /q /f /s "C:\Windows\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache\*.*"

:: Clear Internet Explorer Cache
echo Clearing Internet Explorer Cache...
del /q /f /s "%localappdata%\Microsoft\Windows\INetCache\*.*"
del /q /f /s "%localappdata%\Microsoft\Windows\WebCache\*.*"

:: Clear DirectX Shader Cache
echo Clearing DirectX Shader Cache...
del /q /f /s "%localappdata%\NVIDIA\DXCache\*.*"
del /q /f /s "%localappdata%\AMD\DXCache\*.*"
del /q /f /s "%localappdata%\D3DSCache\*.*"

:: Clear Recycle Bin
echo Clearing Recycle Bin...
rd /s /q %systemdrive%\$Recycle.bin

:: Clear Thumbnails cache
echo Clearing Thumbnails cache...
del /q /f /s "%localappdata%\Microsoft\Windows\Explorer\thumbcache_*.db"

:: Clear Windows Error Reporting files
echo Clearing Windows Error Reporting files...
del /q /f /s "C:\ProgramData\Microsoft\Windows\WER\*.*"
del /q /f /s "%localappdata%\Microsoft\Windows\WER\*.*"
del /q /f /s "%SystemRoot%\System32\config\systemprofile\AppData\Local\Microsoft\Windows\WER\ReportQueue\*"
del /q /f /s "%SystemRoot%\System32\config\systemprofile\AppData\Local\Microsoft\Windows\WER\ReportArchive\*"
del /q /f /s "%SystemRoot%\System32\config\systemprofile\AppData\Local\Microsoft\Windows\WER\Temp\*"

:: Clear Windows Defender logs
echo Clearing Windows Defender logs...
del /q /f /s "C:\ProgramData\Microsoft\Windows Defender\Scans\History\*.*"

:: Run Disk Cleanup (cleanmgr) 
echo Running Disk Cleanup...
cleanmgr /sagerun:1

echo Cleanup completed.
pause