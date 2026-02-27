/**
 * 训练数据接收服务
 * 
 * 轻量级 HTTP 服务，用于接收 HarmonyOS 客户端上传的训练数据
 * 与 OpenClaw Gateway 运行在同一台机器上
 * 
 * 使用方式：
 *   node server/training-server.js
 * 
 * 端口：18790 (Gateway 是 18789)
 */

const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT = 18790;
const DATA_DIR = path.join(__dirname, 'training-data');
const FEDERATED_DIR = path.join(__dirname, 'federated-data');
const FEDERATED_UPLOADS_DIR = path.join(FEDERATED_DIR, 'uploads');
const FEDERATED_MODEL_PATH = path.join(FEDERATED_DIR, 'model.json');

// 确保数据目录存在
if (!fs.existsSync(DATA_DIR)) {
  fs.mkdirSync(DATA_DIR, { recursive: true });
}
if (!fs.existsSync(FEDERATED_UPLOADS_DIR)) {
  fs.mkdirSync(FEDERATED_UPLOADS_DIR, { recursive: true });
}

// 请求日志
function log(method, url, status, bodySize = 0) {
  const timestamp = new Date().toISOString();
  console.log(`[${timestamp}] ${method} ${url} ${status} ${bodySize}bytes`);
}

// CORS headers
const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
  'Access-Control-Allow-Headers': 'Content-Type',
  'Content-Type': 'application/json'
};

// 处理 OPTIONS 预检请求
function handleOptions(res) {
  res.writeHead(204, CORS_HEADERS);
  res.end();
}

// 处理健康检查
function handleHealth(res) {
  res.writeHead(200, CORS_HEADERS);
  res.end(JSON.stringify({ status: 'ok', timestamp: Date.now() }));
}

// 处理训练数据上传
function handleUpload(req, res) {
  let body = '';
  
  req.on('data', chunk => {
    body += chunk.toString();
    // 限制请求体大小 (1MB)
    if (body.length > 1024 * 1024) {
      res.writeHead(413, CORS_HEADERS);
      res.end(JSON.stringify({ error: 'Request body too large' }));
      req.destroy();
      return;
    }
  });
  
  req.on('end', () => {
    try {
      const payload = JSON.parse(body);
      
      // 验证基本结构
      if (!payload.deviceId || !payload.records || !Array.isArray(payload.records)) {
        res.writeHead(400, CORS_HEADERS);
        res.end(JSON.stringify({ error: 'Invalid payload structure' }));
        log('POST', '/training/upload', 400);
        return;
      }
      
      // 按设备ID保存数据
      const deviceId = payload.deviceId.replace(/[^a-zA-Z0-9_-]/g, '_');
      const date = new Date().toISOString().slice(0, 10);
      const filename = `${deviceId}_${date}.jsonl`;
      const filepath = path.join(DATA_DIR, filename);
      
      // 追加写入（每条记录一行 JSON）
      const lines = payload.records.map(r => JSON.stringify(r)).join('\n') + '\n';
      fs.appendFileSync(filepath, lines);
      
      const response = {
        success: true,
        receivedCount: payload.records.length,
        serverTime: Date.now(),
        file: filename
      };
      
      res.writeHead(200, CORS_HEADERS);
      res.end(JSON.stringify(response));
      log('POST', '/training/upload', 200, body.length);
      
      // 打印统计
      console.log(`  -> Saved ${payload.records.length} records from ${deviceId}`);
      
    } catch (err) {
      res.writeHead(400, CORS_HEADERS);
      res.end(JSON.stringify({ error: 'Invalid JSON: ' + err.message }));
      log('POST', '/training/upload', 400);
    }
  });
  
  req.on('error', err => {
    console.error('Request error:', err.message);
    res.writeHead(500, CORS_HEADERS);
    res.end(JSON.stringify({ error: 'Internal server error' }));
  });
}

// 处理数据统计
function handleStats(req, res) {
  try {
    const files = fs.readdirSync(DATA_DIR).filter(f => f.endsWith('.jsonl'));
    
    let totalRecords = 0;
    let totalBytes = 0;
    const deviceStats = {};
    
    for (const file of files) {
      const filepath = path.join(DATA_DIR, file);
      const stat = fs.statSync(filepath);
      const content = fs.readFileSync(filepath, 'utf8');
      const lines = content.trim().split('\n').filter(l => l.length > 0);
      
      totalRecords += lines.length;
      totalBytes += stat.size;
      
      // 从文件名提取设备ID
      const deviceId = file.split('_')[0];
      if (!deviceStats[deviceId]) {
        deviceStats[deviceId] = { files: 0, records: 0, bytes: 0 };
      }
      deviceStats[deviceId].files++;
      deviceStats[deviceId].records += lines.length;
      deviceStats[deviceId].bytes += stat.size;
    }
    
    const response = {
      totalFiles: files.length,
      totalRecords,
      totalBytes,
      totalMB: (totalBytes / 1024 / 1024).toFixed(2),
      devices: deviceStats
    };
    
    res.writeHead(200, CORS_HEADERS);
    res.end(JSON.stringify(response, null, 2));
    log('GET', '/training/stats', 200);
    
  } catch (err) {
    res.writeHead(500, CORS_HEADERS);
    res.end(JSON.stringify({ error: err.message }));
    log('GET', '/training/stats', 500);
  }
}

// ============================================================
// 联邦学习 (Federated Learning) Endpoints
// ============================================================

/**
 * 从匿名化条件自动生成可读的社区规则名称
 */
function generateRuleName(conditions) {
  const parts = [];
  let isWeekend = null;

  for (const c of conditions) {
    if (c.key === 'isWeekend') {
      isWeekend = c.value === 'true' || c.value === true;
    } else if (c.key === 'timeOfDay') {
      parts.push(c.value);
    } else if (c.key === 'placeCategory') {
      parts.push(`at ${c.value}`);
    } else if (c.key === 'motionState') {
      parts.push(`while ${c.value}`);
    } else if (c.key === 'actionType') {
      parts.push(c.value);
    }
  }

  if (isWeekend === true) parts.unshift('Weekend');
  else if (isWeekend === false) parts.unshift('Weekday');

  return (parts.join(' ') || 'Community rule') + ' suggestion';
}

/**
 * 聚合所有设备上传，生成联邦模型
 */
function aggregateFederatedModel() {
  const uploadsDir = FEDERATED_UPLOADS_DIR;
  const files = fs.readdirSync(uploadsDir).filter(f => f.endsWith('.json'));

  if (files.length === 0) return;

  // 读取现有模型版本号以递增
  let currentVersion = 0;
  if (fs.existsSync(FEDERATED_MODEL_PATH)) {
    try {
      const existing = JSON.parse(fs.readFileSync(FEDERATED_MODEL_PATH, 'utf8'));
      currentVersion = existing.modelVersion || 0;
    } catch (e) { /* ignore */ }
  }

  // 收集所有设备数据
  const allUploads = [];
  for (const file of files) {
    try {
      const data = JSON.parse(fs.readFileSync(path.join(uploadsDir, file), 'utf8'));
      allUploads.push(data);
    } catch (e) {
      console.error(`  -> Failed to parse ${file}: ${e.message}`);
    }
  }

  if (allUploads.length === 0) return;

  // === L1: 规则聚合 ===
  // 按 conditionFingerprint 分组
  const rulesByFingerprint = {};  // fingerprint -> { devices: Set, rules: [] }

  for (const upload of allUploads) {
    if (!upload.rules || !Array.isArray(upload.rules)) continue;
    const deviceFp = upload.deviceFingerprint || 'unknown';

    for (const rule of upload.rules) {
      const fp = rule.conditionFingerprint;
      if (!fp) continue;

      if (!rulesByFingerprint[fp]) {
        rulesByFingerprint[fp] = { devices: new Set(), rules: [], conditions: rule.conditions || [] };
      }
      rulesByFingerprint[fp].devices.add(deviceFp);
      rulesByFingerprint[fp].rules.push(rule);
    }
  }

  // 生成社区规则: 3+ 设备 + 聚合 confidence > 0.5
  const communityRules = [];
  for (const [fp, group] of Object.entries(rulesByFingerprint)) {
    if (group.devices.size < 3) continue;

    // 加权平均 confidence，求和 triggerCount/acceptCount
    let totalWeight = 0;
    let weightedConfidence = 0;
    let totalTriggerCount = 0;
    let totalAcceptCount = 0;

    for (const rule of group.rules) {
      const weight = rule.dataPoints || rule.triggerCount || 1;
      weightedConfidence += (rule.confidence || 0) * weight;
      totalWeight += weight;
      totalTriggerCount += rule.triggerCount || 0;
      totalAcceptCount += rule.acceptCount || 0;
    }

    const avgConfidence = totalWeight > 0 ? weightedConfidence / totalWeight : 0;
    if (avgConfidence <= 0.5) continue;

    communityRules.push({
      id: `community_${fp.substring(0, 8)}`,
      name: generateRuleName(group.conditions),
      conditionFingerprint: fp,
      conditions: group.conditions,
      confidence: Math.round(avgConfidence * 1000) / 1000,
      triggerCount: totalTriggerCount,
      acceptCount: totalAcceptCount,
      deviceCount: group.devices.size
    });
  }

  // === L3: 行为模式聚合 ===
  const patternMap = {};  // key -> frequency

  for (const upload of allUploads) {
    if (!upload.patterns || !Array.isArray(upload.patterns)) continue;

    for (const p of upload.patterns) {
      const key = `${p.placeCategory || ''}|${p.timeOfDay || ''}|${p.isWeekend ? 'weekend' : 'weekday'}|${p.motionState || ''}|${p.actionType || ''}`;
      patternMap[key] = (patternMap[key] || 0) + (p.frequency || 1);
    }
  }

  // Top-20 patterns
  const topPatterns = Object.entries(patternMap)
    .sort((a, b) => b[1] - a[1])
    .slice(0, 20)
    .map(([key, frequency]) => {
      const [placeCategory, timeOfDay, dayType, motionState, actionType] = key.split('|');
      return {
        placeCategory: placeCategory || 'unknown',
        timeOfDay: timeOfDay || 'unknown',
        isWeekend: dayType === 'weekend',
        motionState: motionState || 'unknown',
        actionType: actionType || 'unknown',
        frequency
      };
    });

  // 生成模型
  const model = {
    protocolVersion: 1,
    aggregatedAt: Date.now(),
    participantCount: allUploads.length,
    communityRules,
    linucbState: null,
    topPatterns,
    modelVersion: currentVersion + 1
  };

  fs.writeFileSync(FEDERATED_MODEL_PATH, JSON.stringify(model, null, 2));
  console.log(`  -> Aggregated federated model v${model.modelVersion}: ${communityRules.length} community rules, ${topPatterns.length} patterns from ${allUploads.length} devices`);
}

/**
 * POST /training/federated/upload — 接收设备的匿名化模型更新
 */
function handleFederatedUpload(req, res) {
  let body = '';

  req.on('data', chunk => {
    body += chunk.toString();
    if (body.length > 1024 * 1024) {
      res.writeHead(413, CORS_HEADERS);
      res.end(JSON.stringify({ error: 'Request body too large' }));
      req.destroy();
      return;
    }
  });

  req.on('end', () => {
    try {
      const payload = JSON.parse(body);

      // 验证基本结构
      if (!payload.protocolVersion || !payload.deviceFingerprint || !Array.isArray(payload.rules)) {
        res.writeHead(400, CORS_HEADERS);
        res.end(JSON.stringify({ error: 'Invalid federated update: requires protocolVersion, deviceFingerprint, rules[]' }));
        log('POST', '/training/federated/upload', 400);
        return;
      }

      // Sanitize 设备指纹（只保留 hex 字符）
      const fingerprint = payload.deviceFingerprint.replace(/[^a-fA-F0-9]/g, '').substring(0, 64);
      if (fingerprint.length === 0) {
        res.writeHead(400, CORS_HEADERS);
        res.end(JSON.stringify({ error: 'Invalid deviceFingerprint' }));
        log('POST', '/training/federated/upload', 400);
        return;
      }

      // 写入设备更新文件（覆盖，只保留最新）
      const filepath = path.join(FEDERATED_UPLOADS_DIR, `${fingerprint}.json`);
      fs.writeFileSync(filepath, JSON.stringify(payload, null, 2));

      // 触发聚合
      aggregateFederatedModel();

      // 读取当前模型版本
      let modelVersion = 0;
      if (fs.existsSync(FEDERATED_MODEL_PATH)) {
        try {
          const model = JSON.parse(fs.readFileSync(FEDERATED_MODEL_PATH, 'utf8'));
          modelVersion = model.modelVersion || 0;
        } catch (e) { /* ignore */ }
      }

      const response = {
        success: true,
        modelVersion,
        serverTime: Date.now()
      };

      res.writeHead(200, CORS_HEADERS);
      res.end(JSON.stringify(response));
      log('POST', '/training/federated/upload', 200, body.length);
      console.log(`  -> Federated upload from ${fingerprint.substring(0, 8)}...: ${payload.rules.length} rules, ${(payload.patterns || []).length} patterns`);

    } catch (err) {
      res.writeHead(400, CORS_HEADERS);
      res.end(JSON.stringify({ error: 'Invalid JSON: ' + err.message }));
      log('POST', '/training/federated/upload', 400);
    }
  });

  req.on('error', err => {
    console.error('Federated upload error:', err.message);
    res.writeHead(500, CORS_HEADERS);
    res.end(JSON.stringify({ error: 'Internal server error' }));
  });
}

/**
 * GET /training/federated/model?since={version} — 下载聚合模型
 */
function handleFederatedModel(req, res) {
  try {
    // 解析 ?since= 参数
    const urlObj = new URL(req.url, `http://127.0.0.1:${PORT}`);
    const sinceParam = urlObj.searchParams.get('since');
    const since = sinceParam ? parseInt(sinceParam, 10) : -1;

    // 读取当前模型
    if (!fs.existsSync(FEDERATED_MODEL_PATH)) {
      // 还没有聚合过 → 返回空模型
      const emptyModel = {
        protocolVersion: 1,
        aggregatedAt: 0,
        participantCount: 0,
        communityRules: [],
        linucbState: null,
        topPatterns: [],
        modelVersion: 0
      };
      res.writeHead(200, CORS_HEADERS);
      res.end(JSON.stringify(emptyModel));
      log('GET', '/training/federated/model', 200);
      return;
    }

    const model = JSON.parse(fs.readFileSync(FEDERATED_MODEL_PATH, 'utf8'));
    const currentVersion = model.modelVersion || 0;

    // 如果客户端已有最新版本 → 304
    if (since >= currentVersion) {
      res.writeHead(304, CORS_HEADERS);
      res.end();
      log('GET', '/training/federated/model', 304);
      return;
    }

    res.writeHead(200, CORS_HEADERS);
    res.end(JSON.stringify(model));
    log('GET', '/training/federated/model', 200);

  } catch (err) {
    res.writeHead(500, CORS_HEADERS);
    res.end(JSON.stringify({ error: err.message }));
    log('GET', '/training/federated/model', 500);
  }
}

/**
 * GET /training/federated/stats — 联邦同步统计
 */
function handleFederatedStats(req, res) {
  try {
    const uploadFiles = fs.existsSync(FEDERATED_UPLOADS_DIR)
      ? fs.readdirSync(FEDERATED_UPLOADS_DIR).filter(f => f.endsWith('.json'))
      : [];

    let communityRuleCount = 0;
    let topPatternCount = 0;
    let aggregatedAt = 0;
    let modelVersion = 0;

    if (fs.existsSync(FEDERATED_MODEL_PATH)) {
      const model = JSON.parse(fs.readFileSync(FEDERATED_MODEL_PATH, 'utf8'));
      communityRuleCount = (model.communityRules || []).length;
      topPatternCount = (model.topPatterns || []).length;
      aggregatedAt = model.aggregatedAt || 0;
      modelVersion = model.modelVersion || 0;
    }

    const response = {
      participantCount: uploadFiles.length,
      communityRuleCount,
      topPatternCount,
      modelVersion,
      aggregatedAt: aggregatedAt ? new Date(aggregatedAt).toISOString() : null
    };

    res.writeHead(200, CORS_HEADERS);
    res.end(JSON.stringify(response, null, 2));
    log('GET', '/training/federated/stats', 200);

  } catch (err) {
    res.writeHead(500, CORS_HEADERS);
    res.end(JSON.stringify({ error: err.message }));
    log('GET', '/training/federated/stats', 500);
  }
}

// 主请求处理器
const server = http.createServer((req, res) => {
  const url = req.url.split('?')[0];
  const method = req.method;
  
  // 路由
  if (method === 'OPTIONS') {
    handleOptions(res);
  } else if (url === '/health' && method === 'GET') {
    handleHealth(res);
  } else if (url === '/training/upload' && method === 'POST') {
    handleUpload(req, res);
  } else if (url === '/training/stats' && method === 'GET') {
    handleStats(req, res);
  } else if (url === '/training/federated/upload' && method === 'POST') {
    handleFederatedUpload(req, res);
  } else if (url === '/training/federated/model' && method === 'GET') {
    handleFederatedModel(req, res);
  } else if (url === '/training/federated/stats' && method === 'GET') {
    handleFederatedStats(req, res);
  } else {
    res.writeHead(404, CORS_HEADERS);
    res.end(JSON.stringify({ error: 'Not found' }));
    log(method, url, 404);
  }
});

server.listen(PORT, () => {
  console.log(`Training Data Server running on http://127.0.0.1:${PORT}`);
  console.log('');
  console.log('Endpoints:');
  console.log(`  GET  /health                     - Health check`);
  console.log(`  POST /training/upload             - Upload training data`);
  console.log(`  GET  /training/stats              - View statistics`);
  console.log(`  POST /training/federated/upload   - Upload federated model update`);
  console.log(`  GET  /training/federated/model    - Download aggregated model`);
  console.log(`  GET  /training/federated/stats    - Federated sync statistics`);
  console.log('');
  console.log(`Data directory:      ${DATA_DIR}`);
  console.log(`Federated directory: ${FEDERATED_DIR}`);
  console.log('');
});

// 优雅关闭
process.on('SIGINT', () => {
  console.log('\nShutting down...');
  server.close(() => {
    console.log('Server closed');
    process.exit(0);
  });
});
