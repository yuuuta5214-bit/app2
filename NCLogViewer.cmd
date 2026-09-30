@echo off
rem ==========================================================================
rem  NCLogViewer.cmd - Launcher for the NCLog Viewer (Show-NCLogViewer)
rem
rem  Usage:
rem    - Double-click       : open an empty viewer (use [Open] or drag and drop)
rem    - Drag and drop      : drop one .BIN file onto this file to open it
rem
rem  This file is intentionally ASCII only: cmd.exe reads batch files in the
rem  OEM code page (CP932 on Japanese Windows), so all Japanese messages are
rem  shown by tools\Start-NCLogViewer.ps1 instead.
rem
rem  -STA is required by WPF. -WindowStyle Hidden hides this console window
rem  while the viewer is open; errors are shown in a message box.
rem  -ExecutionPolicy Bypass applies only to this pwsh process and only to the
rem  scripts shipped next to this file. It cannot override an execution policy
rem  enforced by Group Policy (MachinePolicy / UserPolicy).
rem ==========================================================================
setlocal EnableExtensions DisableDelayedExpansion

rem --- Locate PowerShell 7 (pwsh.exe). Windows PowerShell 5.1 is not supported.
set "PWSH="
for /f "delims=" %%P in ('where.exe pwsh.exe 2^>nul') do if not defined PWSH set "PWSH=%%P"
if not defined PWSH if exist "%ProgramFiles%\PowerShell\7\pwsh.exe" set "PWSH=%ProgramFiles%\PowerShell\7\pwsh.exe"
if not defined PWSH (
    echo [ERROR] PowerShell 7 ^(pwsh.exe^) was not found.
    echo         Install it, then run this file again:
    echo           winget install --id Microsoft.PowerShell --source winget
    echo.
    pause
    exit /b 9009
)

rem --- All package files must sit next to this file.
set "LAUNCHER=%~dp0tools\Start-NCLogViewer.ps1"
set "MISSING=0"
call :require "%LAUNCHER%"
call :require "%~dp0NCLogTools\NCLogTools.psd1"
call :require "%~dp0NCLogTools\Viewer\NCLogViewer.xaml"
if not "%MISSING%"=="0" goto :missing

"%PWSH%" -NoLogo -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%LAUNCHER%" %*
exit /b %ERRORLEVEL%

:missing
echo.
echo         This tool needs the whole package, not only this .cmd file.
echo         Download the package zip, extract ALL of it, and run
echo         NCLogViewer.cmd from the extracted folder. Required layout:
echo.
echo           NCLogViewer.cmd
echo           NCLogTools\    (folder)
echo           tools\         (folder)
echo.
pause
exit /b 2

rem --- Subroutine: report a missing file (path is quoted so "&" and ")" are safe)
:require
if exist "%~1" exit /b 0
if "%MISSING%"=="0" echo [ERROR] Required file not found:
echo           "%~1"
set "MISSING=1"
exit /b 0
