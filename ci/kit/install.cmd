@echo off
rem WinUHid dev test build - installer for TEST MACHINES ONLY.
rem Trusts this build's throwaway test certificate, then installs the driver package.
setlocal
cd /d "%~dp0"

fltmc >nul 2>&1
if errorlevel 1 goto needadmin

echo.
echo  WinUHid dev test build - for test machines only
echo.

echo [1/3] Trusting this build's test certificate...
certutil -addstore -f Root "%~dp0WinUHid-dev-test.cer" >nul
if errorlevel 1 goto certfail

echo [2/3] Installing the driver package...
start "" /wait msiexec /i "%~dp0WinUHid-dev-test-x64.msi" /qn /norestart /l*v "%~dp0install.log"
set RC=%ERRORLEVEL%
if "%RC%"=="3010" goto installed
if not "%RC%"=="0" goto msifail

:installed
echo [3/3] Looking for the control device...
pnputil /enum-devices /class System | findstr /i /c:"WinUHid" >nul
if errorlevel 1 goto nodevice

echo.
echo  OK - installed. Next step: run selftest.cmd
if "%RC%"=="3010" echo  Windows asks for a restart to finish.
set RESULT=0
goto end

:needadmin
echo.
echo  This needs administrator rights.
echo  Right-click install.cmd and choose "Run as administrator".
set RESULT=1
goto end

:certfail
echo.
echo  FAILED: could not add the test certificate to the trusted roots.
set RESULT=1
goto end

:msifail
echo.
echo  FAILED: the installer returned %RC%. Details are in install.log next to this file.
set RESULT=1
goto end

:nodevice
echo.
echo  FAILED: the installer finished but the WinUHid control device is not present.
echo  Details are in install.log next to this file.
set RESULT=1
goto end

:end
echo.
if not defined CI pause
exit /b %RESULT%
