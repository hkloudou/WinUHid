@echo off
rem WinUHid dev test build - removes the driver package and this build's test certificate.
setlocal
cd /d "%~dp0"

fltmc >nul 2>&1
if errorlevel 1 goto needadmin

set RESULT=0

echo [1/2] Removing the driver package...
start "" /wait msiexec /x "%~dp0WinUHid-dev-test-x64.msi" /qn /norestart /l*v "%~dp0uninstall.log"
set RC=%ERRORLEVEL%
if "%RC%"=="0" goto removed
if "%RC%"=="3010" goto removed
if "%RC%"=="1605" goto notinstalled
echo  FAILED: the installer returned %RC%. Details are in uninstall.log next to this file.
set RESULT=1
goto certs

:notinstalled
echo  It was not installed.
goto certs

:removed
echo  Removed.

:certs
echo [2/2] Removing this build's test certificate...
set THUMB=
set /p THUMB=<"%~dp0cert-thumbprint.txt"
if not defined THUMB goto nothumb
certutil -delstore Root %THUMB% >nul 2>&1
certutil -delstore TrustedPublisher %THUMB% >nul 2>&1
echo  Done.
goto end

:nothumb
echo  cert-thumbprint.txt is missing; remove the "WinUHid Dev Test" certificate by hand (certlm.msc).
set RESULT=1
goto end

:needadmin
echo.
echo  This needs administrator rights.
echo  Right-click uninstall.cmd and choose "Run as administrator".
set RESULT=1
goto end

:end
echo.
if not defined CI pause
exit /b %RESULT%
