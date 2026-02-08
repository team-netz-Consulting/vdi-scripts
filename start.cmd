@echo off
REM Startet den Bootstrapper für vdi-scripts

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap\main.ps1"

exit /b %ERRORLEVEL%
