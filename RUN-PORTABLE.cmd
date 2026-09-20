@echo off
setlocal
cd /d "%~dp0"
set "PSEXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PSEXE%" (
  echo ERROR: Windows PowerShell 5.1 not found: %PSEXE%
  pause
  exit /b 1
)
start "" "%PSEXE%" -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0RF-Network-Tool-Launcher.ps1"
exit /b 0