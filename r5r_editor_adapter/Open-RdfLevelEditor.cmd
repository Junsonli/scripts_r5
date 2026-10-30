@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Open-RdfLevelEditor.ps1" %*
if errorlevel 1 pause
