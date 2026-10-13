@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Start-ChatGPT.ps1" -Configure
if errorlevel 1 pause
