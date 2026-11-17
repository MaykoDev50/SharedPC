@echo off
rem Double-click to install everything (asks for administrator permission)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0SharedPC-Host-Install.ps1"
