@echo off
cd /d C:\Users\Liuho\ClawdBotHarmony
set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
set PATH=%PATH%;C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin
set PATH=%PATH%;C:\Program Files\Huawei\DevEco Studio\tools\node
call hvigorw --stop-daemon
call hvigorw assembleHap --mode module -p product=default -p buildMode=debug
