/**
 * generate_training_data.js
 * 解析推荐矩阵 → 生成 MLP 训练数据 (training_data.json)
 *
 * 输出格式：
 * {
 *   "meta": { "feat_dim": 71, "act_dim": 40, "samples": N },
 *   "actions": [ { "code":"A1", "name":"亮地铁码", "idx":0 }, ... ],
 *   "samples": [
 *     { "state_code": "3D11332", "x": [0,0,...1,...], "y": [0,0,...0.88,...] },
 *     ...
 *   ]
 * }
 *
 * 用法: node scripts/generate_training_data.js
 */

'use strict';
const fs = require('fs');
const path = require('path');

// ── 动作目录（与 ActionCatalog 一致）───────────────────────────────
const ACTIONS = [
  // A - 亮码
  { code:'A1', name:'亮地铁码' },  { code:'A2', name:'亮公交码' },
  { code:'A3', name:'亮支付码' },  { code:'A4', name:'亮门票' },
  // B - 日程
  { code:'B1', name:'查看今日日程' }, { code:'B2', name:'查看明日日程' },
  { code:'B3', name:'查看下午日程' }, { code:'B4', name:'设置闹钟' },
  { code:'B5', name:'设置出行提醒' }, { code:'B6', name:'设置散场提醒' },
  { code:'B7', name:'检查行程/车票' },{ code:'B8', name:'提醒检票时间' },
  { code:'B9', name:'下班提醒' },
  // C - 天气
  { code:'C1', name:'查看天气' },
  // D - 媒体
  { code:'D1', name:'播放音乐' }, { code:'D2', name:'播放白噪音' },
  { code:'D3', name:'播放播客' }, { code:'D4', name:'查看新闻' },
  // E - 导航
  { code:'E1', name:'导航回家' },    { code:'E2', name:'导航到公司' },
  { code:'E3', name:'导航到餐厅' },  { code:'E4', name:'导航到店铺' },
  { code:'E5', name:'导航到枢纽' },  { code:'E6', name:'导航景点' },
  { code:'E7', name:'通用导航' },    { code:'E8', name:'停车位记录' },
  // F - 交通
  { code:'F1', name:'查看到站时间' }, { code:'F2', name:'提醒下车站' },
  { code:'F3', name:'查看船班时刻' }, { code:'F4', name:'查看场次座位' },
  // G - 健康
  { code:'G1', name:'久坐提醒' }, { code:'G2', name:'补水提醒' },
  { code:'G3', name:'拉伸提醒' }, { code:'G4', name:'查看步数' },
  { code:'G5', name:'休息提醒' },
  // H - 餐饮
  { code:'H1', name:'点餐建议' },
  // I - 社交
  { code:'I1', name:'联系人提醒' },
  // J - 系统
  { code:'J1', name:'关闭通知' }, { code:'J2', name:'静音确认' },
  { code:'J3', name:'注意财物' },
];
const ACT_INDEX = Object.fromEntries(ACTIONS.map((a, i) => [a.code, i]));

// ── 特征编码（71维 one-hot）───────────────────────────────────────
// 布局：time[9] location[36] motion[4] phone[8] light[5] sound[5] dayType[4]
const FEAT_DIM = 71;
const OFFSETS = { time:0, location:9, motion:45, phone:49, light:57, sound:62, dayType:67 };

function charToIdx(dim, c) {
  switch (dim) {
    case 'time':
      if (c >= '1' && c <= '9') return c.charCodeAt(0) - 49; // '1'→0 … '9'→8
      return 0;
    case 'location':
      if (c === '0') return 35;                           // unknown
      if (c >= '1' && c <= '9') return c.charCodeAt(0) - 49; // 0-8
      if (c >= 'A' && c <= 'Z') return 9 + c.charCodeAt(0) - 65; // 9-34
      return 35;
    case 'motion':
      if (c >= '1' && c <= '4') return c.charCodeAt(0) - 49;
      return 3; // unknown
    case 'phone':
      if (c >= '1' && c <= '8') return c.charCodeAt(0) - 49;
      return 7; // unknown
    case 'light':
      if (c >= '0' && c <= '4') return c.charCodeAt(0) - 48;
      return 0;
    case 'sound':
      if (c >= '0' && c <= '4') return c.charCodeAt(0) - 48;
      return 0;
    case 'dayType':
      if (c >= '0' && c <= '3') return c.charCodeAt(0) - 48;
      return 0;
  }
  return 0;
}

function encodeState(stateCode) {
  const x = new Float32Array(FEAT_DIM);
  const dims = ['time','location','motion','phone','light','sound','dayType'];
  dims.forEach((dim, i) => {
    const idx = charToIdx(dim, stateCode[i]);
    x[OFFSETS[dim] + idx] = 1.0;
  });
  return Array.from(x);
}

// ── 别名映射（原始文本 → ActionCode）────────────────────────────────
const ALIAS = {
  // B - 日程
  '查看今日日程':'B1','今日日程':'B1','今日日程概览':'B1','今日行程':'B1',
  '查看明日日程':'B2','查看下午日程':'B3','查看日程':'B3',
  '设置明日闹钟':'B4','设置闹钟':'B4','设置出行提醒':'B5','设置提醒':'B5',
  '设置散场提醒':'B6','检查行程':'B7','检查行程/车票':'B7',
  '提醒检票时间':'B8','下班提醒':'B9',
  // C
  '查看天气':'C1','天气提醒':'C1','查看天气/穿衣':'C1','查看天气/穿衣建议':'C1',
  // D
  '播放音乐':'D1','听音乐':'D1','听音乐/播客':'D1','听播客/音乐':'D1',
  '播放白噪音':'D2','听播客':'D3','听播客/音乐3':'D3',
  '新闻摘要':'D4','查看新闻':'D4','查看新闻摘要':'D4',
  // E
  '导航回家':'E1','查看回家路线':'E1','导航到公司':'E2',
  '导航到餐厅':'E3','导航到站内餐厅':'E3','查看附近餐厅':'E3',
  '导航到店铺':'E4',
  '导航到候车厅':'E5','导航到登机口':'E5','导航到影厅':'E5','导航到检票口':'E5',
  '导航景点':'E6','导航到景点':'E6','查看景点信息':'E6',
  '导航':'E7','导航到目的地':'E7','停车位记录':'E8',
  // F
  '查看到站时间':'F1','提醒下车站':'F2','查看轮渡时刻':'F3','查看场次/座位':'F4',
  '到达提醒':'F1',
  // G
  '久坐提醒':'G1','补水提醒':'G2','拉伸提醒':'G3','查看步数':'G4','休息提醒':'G5',
  // H
  '点餐建议':'H1',
  // I
  '联系人提醒':'I1',
  // J
  '关闭通知提醒':'J1','关闭通知':'J1','静音确认':'J2','注意财物':'J3',
  // A - 亮码（矩阵中暂无，预留）
  '亮地铁码':'A1','亮公交码':'A2','亮支付码':'A3','亮门票':'A4','亮园区门票':'A4',
};

// ── 解析矩阵 ────────────────────────────────────────────────────────
const matrixPath = path.join(__dirname, '../docs/ps-recommendation-matrix.md');
const content = fs.readFileSync(matrixPath, 'utf-8');

// 匹配数据行（推荐列紧跟 | 无空格）
// | StateCode | Title | time | loc | motion | phone | dayType |rec1 |rec2 |rec3 | notes |
const ROW_RE = /^\| ([A-Z0-9]{7}) \|[^|]+\|[^|]+\|[^|]+\|[^|]+\|[^|]+\|[^|]+\|([^|]+)\|([^|]+)\|([^|]+)\|/gm;

const samples = [];
const unresolved = new Set();

let m;
while ((m = ROW_RE.exec(content)) !== null) {
  const [, stateCode, r1raw, r2raw, r3raw] = m;

  // 解析推荐列：动作名[Code](xx%) 或 动作名(xx%)
  function parseRec(raw) {
    const results = [];
    // 带 Code 格式：动作名[XX](pct%)
    const codeRe = /([^\[]+)\[([A-Z]\d)\]\((\d+)%\)/g;
    let mr;
    while ((mr = codeRe.exec(raw)) !== null) {
      const [, , code, pct] = mr;
      const idx = ACT_INDEX[code];
      if (idx !== undefined) results.push({ idx, pct: parseInt(pct) });
    }
    if (results.length > 0) return results;
    // 纯文字格式（兜底）
    const plainRe = /([^|(]+)\((\d+)%\)/g;
    while ((mr = plainRe.exec(raw)) !== null) {
      const name = mr[1].trim();
      const pct = parseInt(mr[2]);
      const code = ALIAS[name];
      if (code) {
        const idx = ACT_INDEX[code];
        if (idx !== undefined) results.push({ idx, pct });
      } else {
        unresolved.add(name);
      }
    }
    return results;
  }

  const recs = [
    ...parseRec(r1raw),
    ...parseRec(r2raw),
    ...parseRec(r3raw),
  ];
  if (recs.length === 0) continue;

  const x = encodeState(stateCode);
  const y = new Array(40).fill(0);
  for (const { idx, pct } of recs) {
    y[idx] = Math.max(y[idx], pct / 100.0);
  }

  samples.push({ state_code: stateCode, x, y });
}

if (unresolved.size > 0) {
  console.warn('⚠️  未解析动作:', [...unresolved]);
}

const output = {
  meta: { feat_dim: FEAT_DIM, act_dim: ACTIONS.length, samples: samples.length,
          offsets: OFFSETS, generated: new Date().toISOString() },
  actions: ACTIONS.map((a, i) => ({ ...a, idx: i })),
  samples,
};

const outPath = path.join(__dirname, 'training_data.json');
fs.writeFileSync(outPath, JSON.stringify(output, null, 2));
console.log(`✅ 生成 ${samples.length} 个训练样本 → ${outPath}`);
console.log(`   feat_dim=${FEAT_DIM}, act_dim=${ACTIONS.length}`);
