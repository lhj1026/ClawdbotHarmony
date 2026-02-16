@echo off
setlocal

cd /d C:\Users\Liuho\ClawdBotHarmony
echo Working directory: %CD%
echo.

set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
set HOS_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony
set NODE_HOME=C:\Program Files\Huawei\DevEco Studio\tools\node
set OHOS_BASE_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony
set PATH=%NODE_HOME%;C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin;C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin;%PATH%

echo Checking entry directory...
dir entry
echo.

echo Running ohpm install...
call ohpm install

echo.
echo Building...
call hvigorw.cmd clean
call hvigorw.cmd assembleHap --mode module -p product=default -p buildMode=debug --no-daemon --analyze=false

echo.
echo Build exit code: %ERRORLEVEL%
pause
