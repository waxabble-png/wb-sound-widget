@echo off
rem ===========================================================================
rem  wb-notify - send an event to the whale widget (and its sound)
rem ---------------------------------------------------------------------------
rem  Usage:
rem     wb-notify done                        task finished sound + bubble
rem     wb-notify ask                         needs-your-input sound + bubble
rem     wb-notify notify                      soft reminder sound + bubble
rem     wb-notify done -t "Build OK" -m "12s" custom title / message
rem     wb-notify --kind done --silent        bubble only, no sound
rem
rem  Works standalone: any program (CI, scripts, editors) can call it.
rem ===========================================================================
setlocal

set "HERE=%~dp0"
set "ENTRY=%HERE%..\hooks\notify.mjs"
set "NODE="

if exist "%ENTRY%" goto :findnode
echo [wb-notify] entry not found: %ENTRY% 1>&2
exit /b 1

:findnode
where node >nul 2>nul
if "%errorlevel%"=="0" set "NODE=node"
if defined NODE goto :run

if exist "%USERPROFILE%\.workbuddy\binaries\node\versions\22.22.2-6\node.exe" set "NODE=%USERPROFILE%\.workbuddy\binaries\node\versions\22.22.2-6\node.exe"
if defined NODE goto :run
if exist "D:\Nodejs\node.exe" set "NODE=D:\Nodejs\node.exe"
if defined NODE goto :run
if exist "%ProgramFiles%\nodejs\node.exe" set "NODE=%ProgramFiles%\nodejs\node.exe"
if defined NODE goto :run

echo [wb-notify] node.exe not found. Install Node.js or set WB_WIDGET_NODE. 1>&2
exit /b 1

:run
"%NODE%" "%ENTRY%" %*
exit /b %errorlevel%
