@echo off
REM Launches Elmer without a console window hanging around.
start "" powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0Elmer.ps1"
