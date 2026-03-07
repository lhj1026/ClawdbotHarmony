@echo off
set HDC="C:\Program Files\Huawei\DevEco Studio\sdk\default\openharmony\toolchains\hdc.exe"
set HAP=C:\users\liuho\ClawdbotHarmony\entry\build\default\outputs\default\entry-default-signed.hap

echo === Connecting to device ===
%HDC% tconn 192.168.137.193:36509

echo === Listing connected devices ===
%HDC% list targets

echo === Installing HAP ===
%HDC% install %HAP%

echo === Done ===
