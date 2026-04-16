@echo off
cd /d "%~dp0.."
echo Full prod mirror into dev\ha-config (stop dev container first: cd dev ^&^& docker compose down)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Sync-HaConfig.ps1" PullDev %*
if errorlevel 1 exit /b 1
pause
