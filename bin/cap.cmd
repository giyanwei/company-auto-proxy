@echo off
if exist "%~dp0proxy-cli.ps1" (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0proxy-cli.ps1" %*
) else (
    powershell -ExecutionPolicy Bypass -NoProfile -File "%~dp0..\src\proxy-cli.ps1" %*
)
