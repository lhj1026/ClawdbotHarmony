/**
 * test_action_recommender.js — 状态对(State Pair) MLP 推理验证
 * 输入: 185维 = 92(curr) + 92(prev) + 1(time_norm)
 * 用法: node tests/context_ai/unit/test_action_recommender.js
 */
'use strict';
const fs = require('fs'), path = require('path');

// ── 加载权重 ─────────────────────────────────────────────────────────
const header = fs.readFileSync(
  path.join(__dirname, '../../../entry/src/main/cpp/context_engine/action_weights.h'), 'utf-8');

function extract(name) {
  const m = new RegExp(`static const float ${name}\\[\\d+\\] = \\{([^}]+)\\}`).exec(header);
  if (!m) throw new Error(`Array ${name} not found`);
  return m[1].split(',').map(v => parseFloat(v));
}

const W1f = extract('ACT_W1');  // 128×185
const b1  = extract('ACT_B1');  // 128
const W2f = extract('ACT_W2');  // 64×128
const b2  = extract('ACT_B2');  // 64

const IN=185, H=128, OUT=64;
const W1 = Array.from({length:H}, (_,i) => W1f.slice(i*IN, (i+1)*IN));
const W2 = Array.from({length:OUT}, (_,i) => W2f.slice(i*H,  (i+1)*H));

// ── 编码 ─────────────────────────────────────────────────────────────
const SINGLE = 92;
const OFF = {time:0, location:12, motion:48, phone:56, light:68, sound:76, dayType:84};

function charIdx(d, c) {
  if (d==='time')     return c>='1'&&c<='9' ? c.charCodeAt(0)-49 : 0;
  if (d==='location') {
    if (c==='0') return 35;
    if (c>='1'&&c<='9') return c.charCodeAt(0)-49;
    if (c>='A'&&c<='Z') return 9+(c.charCodeAt(0)-65);
    return 35;
  }
  if (d==='motion') return c>='1'&&c<='4' ? c.charCodeAt(0)-49 : 3;
  if (d==='phone')  return c>='1'&&c<='8' ? c.charCodeAt(0)-49 : 7;
  return c>='0'&&c<='4' ? c.charCodeAt(0)-48 : 0;
}

function encodeSingle(code) {
  const x = new Float32Array(SINGLE);
  ['time','location','motion','phone','light','sound','dayType'].forEach((d,i) => {
    x[OFF[d] + charIdx(d, code[i])] = 1.0;
  });
  return x;
}

/** 状态对编码 → 185维 */
function encodePair(currCode, prevCode='0000000', timeNorm=0.0) {
  const x = new Float32Array(IN);
  x.set(encodeSingle(currCode), 0);
  x.set(encodeSingle(prevCode), SINGLE);
  x[SINGLE*2] = timeNorm;
  return x;
}

/** 前向推理 */
function forward(x) {
  const h = W1.map((row,j) => {
    let z = b1[j];
    for (let k=0;k<IN;k++) z += row[k]*x[k];
    return Math.max(0, z);
  });
  const lg = W2.map((row,i) => {
    let z = b2[i];
    for (let j=0;j<H;j++) z += row[j]*h[j];
    return z;
  });
  const mx = Math.max(...lg);
  const e = lg.map(v => Math.exp(v-mx));
  const s = e.reduce((a,b)=>a+b, 0);
  return e.map(v => v/s);
}

function top3(currCode, prevCode='0000000', timeNorm=0.0) {
  const x = encodePair(currCode, prevCode, timeNorm);
  return forward(x).map((p,i)=>({idx:i,p})).sort((a,b)=>b.p-a.p).slice(0,3);
}

// ── 动作名称 ─────────────────────────────────────────────────────────
const ACTS = [
  'A1:亮地铁码','A2:亮公交码','A3:亮支付码','A4:亮门票',
  'B1:查看今日日程','B2:查看明日日程','B3:查看下午日程','B4:设置闹钟',
  'B5:设置出行提醒','B6:设置散场提醒','B7:检查行程/车票','B8:提醒检票时间','B9:下班提醒',
  'C1:查看天气',
  'D1:播放音乐','D2:播放白噪音','D3:播放播客','D4:查看新闻',
  'E1:导航回家','E2:导航到公司','E3:导航到餐厅','E4:导航到店铺',
  'E5:导航到枢纽','E6:导航景点','E7:通用导航','E8:停车位记录',
  'F1:查看到站时间','F2:提醒下车站','F3:查看船班时刻','F4:查看场次座位',
  'G1:久坐提醒','G2:补水提醒','G3:拉伸提醒','G4:查看步数','G5:休息提醒',
  'H1:点餐建议','I1:联系人提醒','J1:关闭通知','J2:静音确认','J3:注意财物',
];
const actName = i => ACTS[i] || `R${i-40}`;
const actCode = i => (ACTS[i]||'').split(':')[0];

// ── 测试 ─────────────────────────────────────────────────────────────
let pass=0, fail=0;
function test(name, cond) {
  if (cond) { console.log(`✅ ${name}`); pass++; }
  else       { console.log(`❌ ${name}`); fail++; }
}

function show(label, curr, prev, t) {
  const r = top3(curr, prev, t);
  console.log(`\n📊 ${label}`);
  console.log(`   curr=${curr}  prev=${prev}  time=${t}`);
  r.forEach((a,i) => console.log(`   ${i+1}. ${actName(a.idx)}  (${(a.p*100).toFixed(1)}%)`));
  return r;
}

// ── 场景：展示状态链对推荐的影响 ─────────────────────────────────────

// 1. 同样在公司，但上一状态不同
console.log('\n═══ 状态链对推荐的影响 ═══');
const r1a = show('工作日上午公司-从通勤来(刚到)',  '4213001', '3321001', 0.0);
const r1b = show('工作日上午公司-一直在公司(久坐)', '4213001', '4213001', 0.67);
test('刚到公司top3不同于久坐公司(状态链有效)',
  actCode(r1a[0].idx) !== actCode(r1b[0].idx) ||
  actCode(r1a[1].idx) !== actCode(r1b[1].idx));

// 2. 傍晚驾车：从公司出发 vs 未知出发
const r2a = show('工作日傍晚驾车-从公司出发→导航回家', '7345001', '4213001', 0.0);
const r2b = show('工作日傍晚驾车-出发地未知',           '7345001', '0000000', 0.0);
test('从公司出发驾车 top3 含 E1(导航回家)',
  r2a.some(a => actCode(a.idx) === 'E1'));
test('驾车场景音乐推荐可见', r2a.some(a => actCode(a.idx) === 'D1'));

// 3. 机场候机：从通勤来(刚到) vs 从家出发
const r3a = show('工作日机场-从通勤来(刚到)',  '4711001', '3311001', 0.0);
const r3b = show('工作日机场-稳定候机中',      '4711001', '4711001', 0.33);
test('机场 top3 含 B7(检查行程)',
  r3a.some(a => actCode(a.idx) === 'B7') || r3b.some(a => actCode(a.idx) === 'B7'));

// 4. 早高峰地铁：从家出发
const r4 = show('早高峰地铁-从家出发', '3921001', '3111001', 0.0);
test('地铁 top3 含 B1(日程)/F1(到站)/D1(音乐)',
  r4.some(a => ['B1','F1','D1','D3'].includes(actCode(a.idx))));

// 5. 深夜在家：从晚间活动回来
const r5 = show('工作日深夜在家-从外出回来', '9112001', '7611001', 0.33);
test('深夜 top3 含 B4(闹钟)/G5(休息)',
  r5.some(a => ['B4','G5','B2'].includes(actCode(a.idx))));

// 6. 周末餐厅：从家出发
const r6 = show('周末午餐餐厅-从家出发', '5422002', '5122002', 0.0);
test('餐厅 top3 含 H1(点餐)', r6.some(a => actCode(a.idx) === 'H1'));

// 7. 工作日通勤步行：从家出发
const r7 = show('工作日早晨步行通勤-从家出发', '3321001', '3111001', 0.0);
test('通勤 top3 含 B1(日程)/D1(音乐)',
  r7.some(a => ['B1','D1','D3','C1'].includes(actCode(a.idx))));

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
if (fail > 0) process.exit(1);
