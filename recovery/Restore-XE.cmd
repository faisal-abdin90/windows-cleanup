@echo off
setlocal
rem Runs inside Windows RE. Never assume its drive letters match normal Windows.
set "TARGETOS="
for /f "tokens=2,*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\RecoveryEnvironment" /v TargetOS 2^>nul') do set "TARGETOS=%%B"
if not defined TARGETOS exit /b 10
if not exist "%TARGETOS%\System32" exit /b 11
for %%D in ("%TARGETOS%") do set "OSDRIVE=%%~dD"
set "SOURCE=%~dp0XE"
if not exist "%SOURCE%\Unattend.xml" exit /b 12
if not exist "%TARGETOS%\Panther" mkdir "%TARGETOS%\Panther"
copy /y "%SOURCE%\Unattend.xml" "%TARGETOS%\Panther\Unattend.xml" >nul
if errorlevel 1 exit /b 13
xcopy "%SOURCE%\payload\*" "%OSDRIVE%\ProgramData\XE\" /e /i /h /y /q >nul
if errorlevel 1 exit /b 14
exit /b 0
