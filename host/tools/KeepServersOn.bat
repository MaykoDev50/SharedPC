@echo off
rem SharedPC - keep this computer running so the customers' computers never stop.
rem Power button / closing the lid only turn off the SCREEN, and the computer never sleeps (when plugged in).
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
  exit /b
)
echo Setting power options...
rem power button -> turn off the display (4), plugged in and on battery
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 4
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 4
rem closing the lid -> do nothing (0) when plugged in
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
rem sleep button -> turn off the display
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 4
rem never sleep / hibernate when plugged in; screen turns off after 10 minutes
powercfg /change standby-timeout-ac 0
powercfg /change hibernate-timeout-ac 0
powercfg /change monitor-timeout-ac 10
powercfg /setactive SCHEME_CURRENT
rem Windows Update: do not restart between 08:00 and 02:00 (active hours max 18h)
reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v ActiveHoursStart /t REG_DWORD /d 8 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v ActiveHoursEnd /t REG_DWORD /d 2 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v SmartActiveHoursState /t REG_DWORD /d 0 /f >nul
echo.
echo Done! The power button and closing the lid now only turn off the screen.
echo The computer keeps running, and so do all the customers' computers.
echo.
pause
