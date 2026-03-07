@echo off
set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
cd /d C:\users\liuho\ClawdbotHarmony
call "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p module=entry@default --no-daemon 2>&1
