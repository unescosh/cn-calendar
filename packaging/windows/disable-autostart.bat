@echo off
rem Remove the HKCU autostart entry. No administrator rights needed.
reg delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v CnCalendar /f >nul 2>&1
echo Done - cn-calendar will no longer start automatically.
pause
