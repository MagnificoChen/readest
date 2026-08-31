@echo off
rem Double-click launcher for build-windows.ps1.
rem Keeps the window open after the build so output and errors stay visible.
rem Supports forwarding arguments, e.g.: build-windows.cmd -CheckOnly
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build-windows.ps1" %*
set EXITCODE=%ERRORLEVEL%
echo.
echo ===== build-windows.ps1 finished, exit code %EXITCODE% =====
echo Press any key to close this window...
pause >nul
exit /b %EXITCODE%
