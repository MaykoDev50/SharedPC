@echo off
rem SharedPC - keep this computer running so the customers' computers never stop.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
  exit /b
)
echo Setting up "never turn off"...
rem power button and sleep button -> only turn off the SCREEN (plugged in and on battery)
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 4
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS PBUTTONACTION 4
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 4
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS SBUTTONACTION 4
rem closing the lid -> do nothing (plugged in and on battery)
powercfg /setacvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
powercfg /setdcvalueindex SCHEME_CURRENT SUB_BUTTONS LIDACTION 0
rem never sleep / hibernate (also on battery, e.g. during a power cut); screen off after 10 minutes
powercfg /change standby-timeout-ac 0
powercfg /change standby-timeout-dc 0
powercfg /change hibernate-timeout-ac 0
powercfg /change hibernate-timeout-dc 0
powercfg /change monitor-timeout-ac 10
powercfg /setactive SCHEME_CURRENT
rem remove "Shut down / Restart / Sleep" from the Start menu and Alt+F4 (so nobody turns it off by mistake)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer" /v NoClose /t REG_DWORD /d 1 /f >nul
rem Windows Update: no automatic restart while you are signed in, and not during 08:00-02:00
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoRebootWithLoggedOnUsers /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v ActiveHoursStart /t REG_DWORD /d 8 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v ActiveHoursEnd /t REG_DWORD /d 2 /f >nul
reg add "HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" /v SmartActiveHoursState /t REG_DWORD /d 0 /f >nul
echo.
echo Done! Sign out and back in (or restart once) so the Start menu change applies.
echo - Power button / closing the lid only turn off the screen.
echo - "Shut down" is removed from the Start menu.
echo - To really turn the computer off one day, run AllowShutdown.bat first.
echo.
pause
