@echo off
setlocal
set "MODE=%~1"\r\nset "EXPECTED_SHA=%~2"
if "%MODE%"=="" set "MODE=SAFE"
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"

if /I "%MODE%"=="FULL" (
  echo === RF Network Tool - REAL MACHINE QUALIFICATION [FULL] ===
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0RF-Network-Tool-RealMachineQualification.ps1" -Mode Full -AllowModuleInstall %REV_ARG%
) else if /I "%MODE%"=="GUI" (
  echo === RF Network Tool - REAL MACHINE QUALIFICATION [GUI] ===
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0RF-Network-Tool-RealMachineQualification.ps1" -Mode Gui -AllowModuleInstall %REV_ARG%
) else (
  echo === RF Network Tool - REAL MACHINE QUALIFICATION [SAFE] ===
  "%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0RF-Network-Tool-RealMachineQualification.ps1" -Mode Safe
)

set "RC=%ERRORLEVEL%"
echo.
echo Evidence is under:
echo   %~dp0real-machine-results
echo Upload the newest RF-Network-Tool-REAL-MACHINE-LOGS-*.zip for audit.
echo.
pause
exit /b %RC%
