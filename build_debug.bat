@echo off
REM ClawdbotHarmony build script
cd /d "%~dp0"
set "DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio"
set "HVIGORW=%DEVECO_SDK_HOME%\tools\hvigor\bin\hvigorw.bat"

REM Pre-delete signed HAP to avoid file lock issue during SignHap
set "HAP_OUT=entry\build\default\outputs\default\entry-default-signed.hap"
if exist "%HAP_OUT%" (
    del /f /q "%HAP_OUT%" 2>nul
    if exist "%HAP_OUT%" (
        echo WARNING: Could not delete old HAP, trying taskkill...
        taskkill /f /im node.exe /fi "WINDOWTITLE eq hvigor" 2>nul
        timeout /t 2 /nobreak >nul
        del /f /q "%HAP_OUT%" 2>nul
    )
)

call "%HVIGORW%" assembleHap --no-daemon 2>&1
