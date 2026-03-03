/**
 * generate_training_data.js — 状态对(State Pair)训练数据生成器
 *
 * 特征向量(185维):
 *   [当前状态(92维) | 上一状态(92维) | 在当前状态时长归一化(1维)]
 *
 * 对每个矩阵行 (curr_state → actions):
 *   × 3 种合成前驱状态（由 TRANSITION_PROBS 定义）
 *   × 3 种时长分档（刚到/稳定/久留）
 *   = 最多 9 个训练样本/行，共约 ~1500 个样本
 */
'use strict';
const fs = require('fs');
const path = require('path');

// ── 动作目录（40个已定义，槽位64个）────────────────────────────────
const ACTIONS = [
  { code:'A1', name:'亮地铁码' },  { code:'A2', name:'亮公交码' },
  { code:'A3', name:'亮支付码' },  { code:'A4', name:'亮门票' },
  { code:'B1', name:'查看今日日程' }, { code:'B2', name:'查看明日日程' },
  { code:'B3', name:'查看下午日程' }, { code:'B4', name:'设置闹钟' },
  { code:'B5', name:'设置出行提醒' }, { code:'B6', name:'设置散场提醒' },
  { code:'B7', name:'检查行程/车票' },{ code:'B8', name:'提醒检票时间' },
  { code:'B9', name:'下班提醒' },
  { code:'C1', name:'查看天气' },
  { code:'D1', name:'播放音乐' }, { code:'D2', name:'播放白噪音' },
  { code:'D3', name:'播放播客' }, { code:'D4', name:'查看新闻' },
  { code:'E1', name:'导航回家' },  { code:'E2', name:'导航到公司' },
  { code:'E3', name:'导航到餐厅' },{ code:'E4', name:'导航到店铺' },
  { code:'E5', name:'导航到枢纽' },{ code:'E6', name:'导航景点' },
  { code:'E7', name:'通用导航' },  { code:'E8', name:'停车位记录' },
  { code:'F1', name:'查看到站时间' },{ code:'F2', name:'提醒下车站' },
  { code:'F3', name:'查看船班时刻' },{ code:'F4', name:'查看场次座位' },
  { code:'G1', name:'久坐提醒' }, { code:'G2', name:'补水提醒' },
  { code:'G3', name:'拉伸提醒' }, { code:'G4', name:'查看步数' },
  { code:'G5', name:'休息提醒' },
  { code:'H1', name:'点餐建议' },
  { code:'I1', name:'联系人提醒' },
  { code:'J1', name:'关闭通知' }, { code:'J2', name:'静音确认' },
  { code:'J3', name:'注意财物' },
];
const ACT_INDEX = Object.fromEntries(ACTIONS.map((a, i) => [a.code, i]));
const ACT_DIM_TOTAL = 64;

// ── 特征维度常量 ────────────────────────────────────────────────────
const SINGLE_DIM = 92;   // 单状态维度
const FEAT_DIM   = 185;  // 92(curr) + 92(prev) + 1(time)
const OFFSETS = { time:0, location:12, motion:48, phone:56, light:68, sound:76, dayType:84 };

// ── 时长分档 (time_in_state 归一化) ────────────────────────────────
// 0.0 = 刚到(<5min)  0.33 = 稳定(5-30min)  0.67 = 久留(30min-2h)  1.0 = 超长(>2h)
const TIME_BUCKETS = [0.0, 0.33, 0.67];

// ── 位置转移先验 (curr_location → [{prev_location, prob}]) ──────────
// 位置码: '0'=unknown '1'=home '2'=work '3'=commute '4'=restaurant
//         '5'=gym '6'=outdoor '7'=airport '8'=shopping '9'=subway
//         'A'=bus_stop 'B'=ferry 'C'=train_station 'D'=cafe 'E'=cinema 'F'=park
const TRANSITION_PROBS = {
  '1': [['3',0.5],['6',0.2],['4',0.15],['2',0.15]],  // home ← commute/outdoor/restaurant/work
  '2': [['3',0.6],['1',0.2],['4',0.1],['6',0.1]],    // work ← commute/home/restaurant/outdoor
  '3': [['1',0.55],['2',0.45]],                        // commute ← home/work
  '4': [['2',0.4],['6',0.25],['1',0.2],['8',0.15]],  // restaurant ← work/outdoor/home/shopping
  '5': [['2',0.4],['1',0.4],['6',0.2]],               // gym ← work/home/outdoor
  '6': [['1',0.5],['5',0.3],['F',0.2]],               // outdoor ← home/gym/park
  '7': [['3',0.5],['1',0.3],['2',0.2]],               // airport ← commute/home/work
  '8': [['6',0.4],['1',0.3],['2',0.3]],               // shopping ← outdoor/home/work
  '9': [['1',0.5],['2',0.5]],                          // subway ← home/work
  'A': [['1',0.5],['2',0.5]],                          // bus_stop ← home/work
  'B': [['6',0.4],['1',0.3],['3',0.3]],               // ferry ← outdoor/home/commute
  'C': [['3',0.4],['1',0.3],['2',0.3]],               // train_station ← commute/home/work
  'D': [['2',0.5],['6',0.3],['1',0.2]],               // cafe ← work/outdoor/home
  'E': [['6',0.4],['1',0.3],['8',0.3]],               // cinema ← outdoor/home/shopping
  'F': [['1',0.5],['6',0.3],['5',0.2]],               // park ← home/outdoor/gym
  '0': [['0',1.0]],                                     // unknown ← unknown
};

// ── 单状态编码（92维 one-hot）───────────────────────────────────────
function charToIdx(dim, c) {
  if (dim === 'time')    return (c >= '1' && c <= '9') ? c.charCodeAt(0) - 49 : 0;
  if (dim === 'location') {
    if (c === '0') return 35;
    if (c >= '1' && c <= '9') return c.charCodeAt(0) - 49;
    if (c >= 'A' && c <= 'Z') return 9 + c.charCodeAt(0) - 65;
    return 35;
  }
  if (dim === 'motion')  return (c >= '1' && c <= '4') ? c.charCodeAt(0) - 49 : 3;
  if (dim === 'phone')   return (c >= '1' && c <= '8') ? c.charCodeAt(0) - 49 : 7;
  return (c >= '0' && c <= '4') ? c.charCodeAt(0) - 48 : 0;
}

function encodeSingle(stateCode) {
  const x = new Float32Array(SINGLE_DIM);
  ['time','location','motion','phone','light','sound','dayType'].forEach((d, i) => {
    x[OFFSETS[d] + charToIdx(d, stateCode[i])] = 1.0;
  });
  return x;
}

/** 编码状态对 → 185维 */
function encodePair(currCode, prevCode, timeNorm) {
  const x = new Float32Array(FEAT_DIM);
  const xc = encodeSingle(currCode);
  const xp = encodeSingle(prevCode);
  x.set(xc, 0);
  x.set(xp, SINGLE_DIM);
  x[SINGLE_DIM * 2] = timeNorm;
  return Array.from(x);
}

/** 给定当前位置码，返回 top-N 前驱位置码 */
function getPrevLocations(locCode, n = 3) {
  const probs = TRANSITION_PROBS[locCode] || [['0', 1.0]];
  return probs.slice(0, n).map(p => p[0]);
}

/** 构造前驱 StateCode（保留 time/motion/phone/light/sound/dayType 不变，只换 location） */
function makePrevCode(currCode, prevLoc) {
  return currCode[0] + prevLoc + currCode[2] + currCode[3] + currCode[4] + currCode[5] + currCode[6];
}

// ── 别名映射 ────────────────────────────────────────────────────────
const ALIAS = {
  '查看今日日程':'B1','今日日程':'B1','今日日程概览':'B1','今日行程':'B1',
  '查看明日日程':'B2','查看下午日程':'B3','查看日程':'B3',
  '设置明日闹钟':'B4','设置闹钟':'B4','设置出行提醒':'B5','设置提醒':'B5',
  '设置散场提醒':'B6','检查行程':'B7','检查行程/车票':'B7',
  '提醒检票时间':'B8','下班提醒':'B9',
  '查看天气':'C1','天气提醒':'C1','查看天气/穿衣':'C1','查看天气/穿衣建议':'C1',
  '播放音乐':'D1','听音乐':'D1','听音乐/播客':'D1',
  '播放白噪音':'D2','听播客':'D3',
  '新闻摘要':'D4','查看新闻':'D4','查看新闻摘要':'D4',
  '导航回家':'E1','查看回家路线':'E1','导航到公司':'E2',
  '导航到餐厅':'E3','导航到站内餐厅':'E3','查看附近餐厅':'E3',
  '导航到店铺':'E4',
  '导航到候车厅':'E5','导航到登机口':'E5','导航到影厅':'E5','导航到检票口':'E5',
  '导航景点':'E6','导航到景点':'E6','查看景点信息':'E6',
  '导航':'E7','导航到目的地':'E7','停车位记录':'E8',
  '查看到站时间':'F1','提醒下车站':'F2','查看轮渡时刻':'F3','查看场次/座位':'F4',
  '到达提醒':'F1',
  '久坐提醒':'G1','补水提醒':'G2','拉伸提醒':'G3','查看步数':'G4','休息提醒':'G5',
  '点餐建议':'H1','联系人提醒':'I1',
  '关闭通知提醒':'J1','关闭通知':'J1','静音确认':'J2','注意财物':'J3',
  '亮地铁码':'A1','亮公交码':'A2','亮支付码':'A3','亮门票':'A4','亮园区门票':'A4',
};

// ── 解析矩阵 ────────────────────────────────────────────────────────
const matrixPath = path.join(__dirname, '../docs/ps-recommendation-matrix.md');
const content = fs.readFileSync(matrixPath, 'utf-8');
const ROW_RE = /^\| ([A-Z0-9]{7}) \|[^|]+\|[^|]+\|[^|]+\|[^|]+\|[^|]+\|[^|]+\|([^|]+)\|([^|]+)\|([^|]+)\|/gm;

function parseRec(raw) {
  const results = [];
  const codeRe = /([^\[]+)\[([A-Z]\d)\]\((\d+)%\)/g;
  let mr;
  while ((mr = codeRe.exec(raw)) !== null) {
    const [,, code, pct] = mr;
    const idx = ACT_INDEX[code];
    if (idx !== undefined) results.push({ idx, pct: parseInt(pct) });
  }
  if (results.length > 0) return results;
  const plainRe = /([^|(]+)\((\d+)%\)/g;
  while ((mr = plainRe.exec(raw)) !== null) {
    const name = mr[1].trim();
    const code = ALIAS[name];
    if (code) {
      const idx = ACT_INDEX[code];
      if (idx !== undefined) results.push({ idx, pct: parseInt(mr[2]) });
    }
  }
  return results;
}

const samples = [];
let m;

while ((m = ROW_RE.exec(content)) !== null) {
  const [, stateCode, r1raw, r2raw, r3raw] = m;
  const recs = [...parseRec(r1raw), ...parseRec(r2raw), ...parseRec(r3raw)];
  if (recs.length === 0) continue;

  const y = new Array(ACT_DIM_TOTAL).fill(0);
  for (const { idx, pct } of recs) y[idx] = Math.max(y[idx], pct / 100.0);

  const currLoc = stateCode[1];
  const prevLocs = getPrevLocations(currLoc, 3);

  // 对每个前驱位置 × 每个时长分档 → 生成一个样本
  for (const prevLoc of prevLocs) {
    const prevCode = makePrevCode(stateCode, prevLoc);
    // 时长分档：同位置不生成"刚到"（0.0），首次出现才是刚到
    const timeBuckets = prevLoc === currLoc
      ? [0.33, 0.67, 1.0]    // 位置不变 → 稳定/久留
      : [0.0, 0.33, 0.67];   // 位置切换 → 刚到/稳定
    for (const t of timeBuckets) {
      samples.push({
        state_code: stateCode,
        prev_code: prevCode,
        time_norm: t,
        x: encodePair(stateCode, prevCode, t),
        y,
      });
    }
  }
}

console.log(`✅ 生成 ${samples.length} 个状态对样本 → scripts/training_data.json`);
console.log(`   feat_dim=${FEAT_DIM}(92curr+92prev+1time), act_dim=${ACT_DIM_TOTAL}`);

const output = {
  meta: {
    feat_dim: FEAT_DIM, act_dim: ACT_DIM_TOTAL, act_used: ACTIONS.length,
    single_dim: SINGLE_DIM,
    offsets: OFFSETS,
    dims: { time:12, location:36, motion:8, phone:12, light:8, sound:8, dayType:8 },
    note: 'feat=92curr+92prev+1time=185, act_dim=64(40used+24reserved)',
    samples: samples.length, generated: new Date().toISOString(),
  },
  actions: ACTIONS.map((a, i) => ({ ...a, idx: i })),
  samples,
};

fs.writeFileSync(path.join(__dirname, 'training_data.json'), JSON.stringify(output, null, 2));
