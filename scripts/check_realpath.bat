@echo off
cd /d C:\Users\Liuho\ClawdBotHarmony
set NODE_HOME=C:\Program Files\Huawei\DevEco Studio\tools\node
"%NODE_HOME%\node.exe" -e "const fs = require('fs'); const path = require('path'); const entryPath = path.resolve('./entry'); const realPath = fs.realpathSync.native(entryPath); console.log('resolved: ' + entryPath); console.log('realpath: ' + realPath); console.log('match: ' + (entryPath === realPath));"
