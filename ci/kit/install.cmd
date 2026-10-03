@echo off
rem WinUHid dev test build - installer for TEST MACHINES ONLY.
rem Trusts this build's throwaway test certificate, then installs the driver package.
rem Usage: install.cmd       asks for a key press before installing and before closing
rem        install.cmd /y    does not wait for anyone (for scripts)
rem This file is UTF-8 without a byte order mark; the next line makes the console read it that way.
chcp 65001 >nul
setlocal
cd /d "%~dp0"

rem install.cmd /y  = unattended: show the notice but do not wait for a key, neither before nor after.
set UNATTENDED=
if /i "%~1"=="/y" set UNATTENDED=1

fltmc >nul 2>&1
if errorlevel 1 goto needadmin

echo.
echo  ======================================================================
echo   注意：这是测试版本，驱动用的是自签名的测试证书，不是正式签名。
echo   只能安装在测试机上。请勿分发给用户，请勿用于生产环境。
echo.
echo   NOTICE: this is a TEST build. The driver is signed with a self-signed
echo   test certificate, not a production signature.
echo   Install it on test machines only. Do NOT distribute it to users.
echo  ======================================================================
echo.
if defined UNATTENDED goto confirmed
echo  按任意键继续安装；不想安装请直接关闭本窗口。
echo  Press any key to install, or close this window to cancel.
pause >nul
echo.

:confirmed
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
if not defined UNATTENDED pause
exit /b %RESULT%
