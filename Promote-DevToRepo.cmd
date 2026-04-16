@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Promote-DevToRepo.ps1" %*
pause
