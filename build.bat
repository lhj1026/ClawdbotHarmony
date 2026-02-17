@echo off
set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
cd /d C:\Users\Liuho\ClawdbotHarmony
call "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=release --no-daemon
