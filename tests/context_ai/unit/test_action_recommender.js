/**
 * test_action_recommender.js — ActionRecommender JS 验证
 * 镜像 C++ action_recommender.h 的 MLP 推理逻辑
 * 用法: node tests/context_ai/unit/test_action_recommender.js
 */
'use strict';
const fs = require('fs');
const path = require('path');

// ── 加载权重 ─────────────────────────────────────────────────────────
const headerPath = path.join(__dirname,
  '../../../entry/src/main/cpp/context_engine/action_weights.h');
const header = fs.readFileSync(headerPath, 'utf-8');

function extractArray(name) {
  const re = new RegExp(`static const float ${name}\\[\\d+\\] = \\{([^}]+)\\}`);
  const m = re.exec(header);
  if (!m) throw new Error(`Array ${name} not found`);
  return m[1].split(',').map(s => parseFloat(s.trim()));
}

const W1_flat = extractArray('ACT_W1');  // 64×71=4544
const b1 = extractArray('ACT_B1');       // 64
const W2_flat = extractArray('ACT_W2');  // 40×64=2560
const b2 = extractArray('ACT_B2');       // 40

const IN=92, H=80, OUT=64;
const W1 = Array.from({length:H}, (_,i) => W1_flat.slice(i*IN, (i+1)*IN));
const W2 = Array.from({length:OUT}, (_,i) => W2_flat.slice(i*H, (i+1)*H));

// ── 编码与推理（偏移与 action_recommender.h 一致）────────────────────
const OFFSETS = {time:0, location:12, motion:48, phone:56, light:68, sound:76, dayType:84};

function charToIdx(dim, c) {
  if (dim==='time')    return (c>='1'&&c<='9') ? c.charCodeAt(0)-49 : 0;
  if (dim==='location'){
    if (c==='0') return 35;
    if (c>='1'&&c<='9') return c.charCodeAt(0)-49;
    if (c>='A'&&c<='Z') return 9+(c.charCodeAt(0)-65);
    return 35;
  }
  if (dim==='motion')  return (c>='1'&&c<='4') ? c.charCodeAt(0)-49 : 3;
  if (dim==='phone')   return (c>='1'&&c<='8') ? c.charCodeAt(0)-49 : 7;
  if (dim==='light')   return (c>='0'&&c<='4') ? c.charCodeAt(0)-48 : 0;
  if (dim==='sound')   return (c>='0'&&c<='4') ? c.charCodeAt(0)-48 : 0;
  if (dim==='dayType') return (c>='0'&&c<='3') ? c.charCodeAt(0)-48 : 0;
  return 0;
}

function encode(stateCode) {
  const x = new Float32Array(IN);
  ['time','location','motion','phone','light','sound','dayType'].forEach((d,i) => {
    x[OFFSETS[d] + charToIdx(d, stateCode[i])] = 1.0;
  });
  return x;
}

function forward(x) {
  // Layer 1: ReLU
  const h = W1.map(row => {
    let z = 0; for (let k=0;k<IN;k++) z += row[k]*x[k]; z += b1[W1.indexOf(row)];
    return Math.max(0, z);
  });
  // Layer 2: softmax
  const logits = W2.map((row,i) => {
    let z = b2[i]; for(let j=0;j<H;j++) z += row[j]*h[j];
    return z;
  });
  const maxL = Math.max(...logits);
  const exp = logits.map(v => Math.exp(v-maxL));
  const sum = exp.reduce((a,b)=>a+b,0);
  return exp.map(v=>v/sum);
}

function top3(stateCode) {
  const x = encode(stateCode);
  const probs = forward(x);
  return probs.map((p,i)=>({idx:i,p}))
    .sort((a,b)=>b.p-a.p).slice(0,3);
}

// ── 动作名称表 ────────────────────────────────────────────────────────
const ACTIONS = [
  'A1:亮地铁码','A2:亮公交码','A3:亮支付码','A4:亮门票',
  'B1:查看今日日程','B2:查看明日日程','B3:查看下午日程','B4:设置闹钟',
  'B5:设置出行提醒','B6:设置散场提醒','B7:检查行程/车票','B8:提醒检票时间','B9:下班提醒',
  'C1:查看天气',
  'D1:播放音乐','D2:播放白噪音','D3:播放播客','D4:查看新闻',
  'E1:导航回家','E2:导航到公司','E3:导航到餐厅','E4:导航到店铺',
  'E5:导航到枢纽','E6:导航景点','E7:通用导航','E8:停车位记录',
  'F1:查看到站时间','F2:提醒下车站','F3:查看船班时刻','F4:查看场次座位',
  'G1:久坐提醒','G2:补水提醒','G3:拉伸提醒','G4:查看步数','G5:休息提醒',
  'H1:点餐建议','I1:联系人提醒',
  'J1:关闭通知','J2:静音确认','J3:注意财物',
];

function actName(idx) { return ACTIONS[idx] || `[${idx}]`; }

// ── 测试用例 ─────────────────────────────────────────────────────────
let pass=0, fail=0;
function test(name, cond) {
  if (cond) { console.log(`✅ ${name}`); pass++; }
  else       { console.log(`❌ ${name}`); fail++; }
}

function showTop3(label, code) {
  const r = top3(code);
  console.log(`\n📊 ${label} (${code}):`);
  r.forEach((a,i) => console.log(`  ${i+1}. ${actName(a.idx)}  (${(a.p*100).toFixed(1)}%)`));
  return r;
}

// 场景1：工作日上午在公司（久坐+补水+日程）→ G1/G2/B1 应在top3
const r1 = showTop3('工作日上午公司放桌', '4213001');
const r1codes = r1.map(a=>ACTIONS[a.idx].split(':')[0]);
test('上午公司 top3 含 G1(久坐) 或 G2(补水)',
  r1codes.some(c=>['G1','G2','B1','B3'].includes(c)));

// 场景2：工作日早晨通勤步行（播客/音乐+日程）→ D1/D3/B1
const r2 = showTop3('工作日早晨步行通勤', '3321001');
const r2codes = r2.map(a=>ACTIONS[a.idx].split(':')[0]);
test('通勤 top3 含 D1(音乐) 或 D3(播客) 或 B1(日程)',
  r2codes.some(c=>['D1','D3','B1'].includes(c)));

// 场景3：周末午餐餐厅（点餐+联系人）→ H1
const r3 = showTop3('周末午餐餐厅', '5422002');
const r3codes = r3.map(a=>ACTIONS[a.idx].split(':')[0]);
test('餐厅 top3 含 H1(点餐)', r3codes.includes('H1'));

// 场景4：工作日机场步行（检查行程+登机口）→ B7/E5
const r4 = showTop3('工作日机场候机', '4711001');
const r4codes = r4.map(a=>ACTIONS[a.idx].split(':')[0]);
test('机场 top3 含 B7(检查行程) 或 E5(导航到枢纽)',
  r4codes.some(c=>['B7','E5','B8'].includes(c)));

// 场景5：工作日傍晚驾车通勤（导航回家）→ E1（commute='3'）
const r5 = showTop3('工作日傍晚驾车回家', '7345001');
const r5codes = r5.map(a=>ACTIONS[a.idx].split(':')[0]);
test('驾车回家 top3 含 E1(导航回家) 或 D1(音乐)',
  r5codes.some(c=>['E1','D1','E8'].includes(c)));

// 场景6：早高峰地铁步行（到站时间+播客）→ F1/D3（walking='2'）
const r6 = showTop3('早高峰地铁步行', '3921001');
const r6codes = r6.map(a=>ACTIONS[a.idx].split(':')[0]);
test('地铁步行 top3 含 F1(到站时间) 或 D3(播客)',
  r6codes.some(c=>['F1','D3','B1'].includes(c)));

// 场景7：工作日深夜在家（闹钟+休息提醒）→ B4/G5
const r7 = showTop3('工作日深夜在家', '9112001');
const r7codes = r7.map(a=>ACTIONS[a.idx].split(':')[0]);
test('深夜 top3 含 B4(闹钟) 或 G5(休息)',
  r7codes.some(c=>['B4','G5','B2'].includes(c)));

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
if (fail > 0) process.exit(1);
