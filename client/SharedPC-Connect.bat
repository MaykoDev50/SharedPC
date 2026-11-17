@echo off
rem SharedPC Connect - double-click to open
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0SharedPC-Connect.ps1"
