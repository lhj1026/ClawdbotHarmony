@echo off 
cd /d C:\Users\Liuho\ClawdBotHarmony 
set "HVIGOR_USER_HOME=C:\Users\liuhongjie\.hvigor" 
call scripts\build_and_install.bat > "C:\Users\Liuho\ClawdBotHarmony\build_output.log" 2>&1 
echo EXIT_CODE=%0% >> "C:\Users\Liuho\ClawdBotHarmony\build_output.log" 
