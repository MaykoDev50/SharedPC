@echo off
rem SharedPC Manager - always runs the newest version (downloaded automatically), as administrator.
set "D=%APPDATA%\SharedPC-Manager"
if not exist "%D%" mkdir "%D%"
for %%F in (SharedPC-Manager.ps1 common.ps1 create-vm.ps1 setup-client.ps1) do (
  curl.exe -L -s --fail -m 30 -o "%D%\%%F.new" "https://raw.githubusercontent.com/MaykoDev50/SharedPC/main/manager/%%F?t=%RANDOM%%RANDOM%" && move /y "%D%\%%F.new" "%D%\%%F" >nul
)
if not exist "%D%\SharedPC-Manager.ps1" (
  echo Could not download SharedPC Manager. Check your internet connection.
  pause
  exit /b 1
)
powershell -NoProfile -Command "Start-Process powershell -Verb RunAs -WindowStyle Hidden -ArgumentList '-NoProfile -STA -ExecutionPolicy Bypass -File \"%D%\SharedPC-Manager.ps1\"'"
