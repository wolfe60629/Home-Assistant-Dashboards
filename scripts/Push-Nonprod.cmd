@echo off
cd /d "%~dp0.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0..\Sync-HaConfig.ps1" Push -Scope LovelaceNonprod
pause
