@echo off
rem SharedPC - give VirtualBox back the processor's virtualization (VT-x).
rem Since 18/11 Windows' own hypervisor (Hyper-V) is running and takes VT-x, so VirtualBox
rem falls back to a slow mode in which the computers get stuck while starting.
net session >nul 2>&1
if errorlevel 1 (
  powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs"
  exit /b
)
chcp 65001 >nul
echo.
echo Turning off the Windows hypervisor so VirtualBox can use VT-x...
echo.
rem 1) don't start the Windows hypervisor at boot
bcdedit /set hypervisorlaunchtype off
rem 2) Memory integrity (Core isolation) also starts the hypervisor - turn it off
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity" /v Enabled /t REG_DWORD /d 0 /f >nul
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f >nul
rem 3) Windows features that turn the hypervisor on
dism /online /disable-feature /featurename:Microsoft-Hyper-V-All /norestart >nul 2>&1
dism /online /disable-feature /featurename:VirtualMachinePlatform /norestart >nul 2>&1
dism /online /disable-feature /featurename:HypervisorPlatform /norestart >nul 2>&1
dism /online /disable-feature /featurename:Containers-DisposableClientVM /norestart >nul 2>&1
echo.
echo ============================================================
echo  Done. The computer must RESTART once for this to work.
echo  After the restart the virtual computers start by themselves
echo  (wait 3-5 minutes), then connect as usual.
echo.
echo  To undo one day:  bcdedit /set hypervisorlaunchtype auto
echo ============================================================
echo.
choice /c YN /m "Restart now"
if errorlevel 2 exit /b
shutdown /r /t 5
