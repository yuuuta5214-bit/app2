@echo off
rem ==========================================================================
rem  NCLogExport.cmd - Launcher for Export-NCLogValues.ps1
rem
rem  Usage:
rem    - Double-click            : choose NCLog .BIN files in a file dialog
rem    - Drag and drop           : drop .BIN files or folders onto this file
rem    - Command line (advanced) : NCLogExport.cmd -Path C:\Logs\NCLog_*.BIN -Format CSV ...
rem                                (arguments starting with "-" are passed to
rem                                 Export-NCLogValues.ps1 unchanged)
rem
rem  This file is intentionally ASCII only: cmd.exe reads batch files in the
rem  OEM code page (CP932 on Japanese Windows), so all Japanese messages are
rem  printed by tools\Start-NCLogExport.ps1 instead.
rem
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

rem --- Scripts must sit next to this file.
set "LAUNCHER=%~dp0tools\Start-NCLogExport.ps1"
set "EXPORTER=%~dp0Export-NCLogValues.ps1"
if not exist "%LAUNCHER%" goto :missing
if not exist "%EXPORTER%" goto :missing

rem --- Advanced use: first argument is a parameter name -> call the exporter directly.
set "ARG1=%~1"
if defined ARG1 if "%ARG1:~0,1%"=="-" goto :passthrough

"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%LAUNCHER%" %*
exit /b %ERRORLEVEL%

:passthrough
"%PWSH%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%EXPORTER%" %*
exit /b %ERRORLEVEL%

:missing
echo [ERROR] Required script not found next to this file:
echo           %LAUNCHER%
echo           %EXPORTER%
echo         Keep NCLogExport.cmd in the same folder as Export-NCLogValues.ps1.
echo.
pause
exit /b 2
