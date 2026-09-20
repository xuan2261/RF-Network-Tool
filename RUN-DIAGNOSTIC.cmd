@echo off
setlocal
cd /d "%~dp0"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
echo === RF Network Tool v1.4.2 Full QA / CI-E2E Diagnostic ===
"%PSEXE%" -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0RF-Network-Tool-Launcher.ps1" -Diagnostic
set "RC=%ERRORLEVEL%"
echo.
if "%RC%"=="0" (echo Diagnostic: PASS) else (echo Diagnostic: FAIL - xem thu muc logs hoac %%LOCALAPPDATA%%\RF-Network-Tool\logs)
echo.
pause
exit /b %RC%