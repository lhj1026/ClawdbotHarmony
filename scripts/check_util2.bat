@echo off
cd /d C:\Users\Liuho\ClawdBotHarmony
set NODE_HOME=C:\Program Files\Huawei\DevEco Studio\tools\node
"%NODE_HOME%\node.exe" -e "const fs = require('fs'); const content = fs.readFileSync('C:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor/src/base/util/file-util.js', 'utf8'); const idx = content.indexOf('exitIfNotExists'); const snippet = content.substring(idx, idx+500); console.log(snippet);"
