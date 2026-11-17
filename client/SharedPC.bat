@echo off
rem SharedPC - the same file for everyone. Always runs the newest version of the app (downloaded automatically).
set "D=%APPDATA%\SharedPC"
if not exist "%D%" mkdir "%D%"
curl.exe -L -s --fail -m 20 -o "%D%\app.new" "https://raw.githubusercontent.com/MaykoDev50/SharedPC/main/client/SharedPC-Connect.ps1?t=%RANDOM%%RANDOM%" && move /y "%D%\app.new" "%D%\app.ps1" >nul
if not exist "%D%\app.ps1" (
  echo Could not download SharedPC. Check your internet connection.
  pause
  exit /b 1
)
start "" powershell -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "%D%\app.ps1"
