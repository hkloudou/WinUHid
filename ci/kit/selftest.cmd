@echo off
rem WinUHid dev test build - creates a virtual mouse and keyboard and checks that they work.
setlocal
cd /d "%~dp0"

rem selftest.cmd /y   does not wait for a key before closing (for scripts)
set UNATTENDED=
if /i "%~1"=="/y" set UNATTENDED=1

fltmc >nul 2>&1
if errorlevel 1 goto needadmin

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0selftest.ps1"
set RESULT=%ERRORLEVEL%
goto end

:needadmin
echo.
echo  This needs administrator rights: only administrators may drive virtual devices.
echo  Right-click selftest.cmd and choose "Run as administrator".
set RESULT=1
goto end

:end
echo.
if not defined UNATTENDED pause
exit /b %RESULT%
