@echo off
setlocal
echo === RF Network Tool v1.4.2 Full QA / CI-E2E - Windows Tests ===
set PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0tests\WINDOWS_INTEGRATION_TEST_v1_4_2.ps1"
set RC=%ERRORLEVEL%
echo.
if not "%RC%"=="0" echo Windows integration tests FAILED with exit code %RC%.
if "%RC%"=="0" echo Windows integration tests PASSED.
pause
exit /b %RC%