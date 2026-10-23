@echo off
rem Starts the MW4 Config Tool window. Close Call of Duty before applying.
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0MW4-Config-Tool.ps1" %*
if errorlevel 1 pause
