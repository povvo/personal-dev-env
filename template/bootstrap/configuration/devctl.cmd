@echo off
pwsh.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0devctl.ps1" %*
