@echo off
pushd C:\Users\Liuho\ClawdBotHarmony
set DEVECO_SDK_HOME=C:\Program Files\Huawei\DevEco Studio\sdk
echo Building...
"C:\Program Files\Huawei\DevEco Studio\tools\hvigor\bin\hvigorw.bat" assembleHap --mode module -p product=default -p buildMode=release --no-daemon
echo Build done.
popd
