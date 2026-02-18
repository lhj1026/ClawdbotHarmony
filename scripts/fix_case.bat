@echo off
echo Killing DevEco Studio...
taskkill /f /im devecostudio64.exe 2>nul
timeout /t 3 >nul
echo Renaming directory...
cd /d C:\Users\Liuho
ren ClawdbotHarmony ClawdBotHarmony_tmp
timeout /t 1 >nul
ren ClawdBotHarmony_tmp ClawdBotHarmony
echo Done. Verifying...
dir C:\Users\Liuho | findstr -i Clawd
