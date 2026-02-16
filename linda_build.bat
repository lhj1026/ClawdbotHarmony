@echo off
cd /d C:\Users\Liuho\ClawdBotHarmony

set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
set HOS_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony
set NODE_HOME=C:\Program Files\Huawei\DevEco Studio\tools\node
set OHOS_BASE_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony
set PATH=%NODE_HOME%;C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin;C:\Program Files\Huawei\DevEco Studio\tools\ohpm\bin;%PATH%

echo Building...
call "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=debug --no-daemon

echo Build result: %ERRORLEVEL%
