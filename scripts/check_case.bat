@echo off
set NODE_HOME=C:\Program Files\Huawei\DevEco Studio\tools\node
"%NODE_HOME%\node.exe" -e "const fs = require('fs'); console.log('realpath: ' + fs.realpathSync.native('C:\\Users\\Liuho\\ClawdBotHarmony')); const entries = fs.readdirSync('C:\\Users\\Liuho'); entries.filter(e => e.toLowerCase().includes('clawd')).forEach(e => console.log('dir entry: ' + e));"
