@echo off

REM Auto-elevate to Administrator
net session >nul 2>&1
if %errorlevel% neq 0 (
  echo Requesting Administrator privileges...
  powershell -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
  exit /b
)

cd /d "%~dp0"

REM Honour PORT env var, default to 3003
if "%PORT%"=="" set PORT=3003

echo Killing anything listening on port %PORT%...
for /f "tokens=5" %%a in ('netstat -aon ^| findstr :%PORT% ^| findstr LISTENING') do taskkill /F /PID %%a >nul 2>&1

if not exist node_modules (
    echo Installing dependencies...
    npm install
)

echo Starting Plan Manager on http://localhost:%PORT%
node server.js
pause
