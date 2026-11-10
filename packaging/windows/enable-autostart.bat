@echo off
rem Enable "start with Windows" for this portable copy of cn-calendar.
rem Writes only to HKCU (current user); no administrator rights needed.
set "APP=%~dp0cn_calendar.exe"
if not exist "%APP%" (
  echo Cannot find cn_calendar.exe next to this script.
  pause
  exit /b 1
)
reg add "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v CnCalendar /t REG_SZ /d "\"%APP%\"" /f >nul
if errorlevel 1 (
  echo Failed to write the autostart entry.
) else (
  echo Done - cn-calendar will start automatically when you sign in.
  echo To turn it off, double-click disable-autostart.bat
)
pause
