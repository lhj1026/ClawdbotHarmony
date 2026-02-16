@echo off
cd /d C:\Users\Liuho\ClawdBotHarmony
set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
set PATH=%PATH%;C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains
echo Building HAP with debug...
call "C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --no-daemon --stacktrace
