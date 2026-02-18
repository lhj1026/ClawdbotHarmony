@echo off
cd /d C:\Users\Liuho\ClawdBotHarmony
set NODE_HOME=C:\Program Files\Huawei\DevEco Studio\tools\node
"%NODE_HOME%\node.exe" -e "const pkg = require('C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/package.json'); console.log('hvigor version: ' + pkg.version);"
