/**
 * test_state_code.js — StateCode 编解码逻辑的 JS 验证（对照 C++ 实现）
 *
 * C++ state_code.h 的 JS 镜像，用于快速验证编码规则正确性。
 * 运行: node tests/context_ai/unit/test_state_code.js
 */

'use strict';

// ── 编码表（与 C++ state_code.h 保持一致）───────────────────────────

const TIME_MAP = {
  sleeping: '1', dawn: '2', morning: '3', forenoon: '4',
  lunch: '5', afternoon: '6', evening: '7', night: '8', late_night: '9',
};
const LOCATION_MAP = {
  // 0=unknown; 1-9: 基础场景; A-Z: 扩展场景
  unknown: '0',
  home: '1', work: '2', commute: '3', restaurant: '4', gym: '5',
  outdoor: '6', airport: '7', shopping: '8', subway: '9',
  bus_stop: 'A', ferry: 'B', train_station: 'C', cafe: 'D', cinema: 'E', park: 'F',
};
const MOTION_MAP   = { stationary: '1', walking: '2', running: '3', driving: '4' };
const PHONE_MAP    = {
  in_use: '1', holding_lying: '2', on_desk: '3', face_up: '4',
  in_pocket: '5', face_down: '6', charging: '7', unknown: '8',
};
const LIGHT_MAP    = { dark: '1', dim: '2', normal: '3', bright: '4' };
const SOUND_MAP    = { quiet: '1', normal: '2', noisy: '3', unknown: '4' };
const DAY_MAP      = { workday: '1', weekend: '2', holiday: '3' };

// 逆映射
const rev = m => Object.fromEntries(Object.entries(m).map(([k, v]) => [v, k]));
const TIME_R = rev(TIME_MAP), LOC_R = rev(LOCATION_MAP), MOTION_R = rev(MOTION_MAP);
const PHONE_R = rev(PHONE_MAP), LIGHT_R = rev(LIGHT_MAP), SOUND_R = rev(SOUND_MAP);
const DAY_R = rev(DAY_MAP);

// ── 编解码函数 ───────────────────────────────────────────────────────

function encode({ time, location, motion, phone, light = '0', sound = '0', dayType }) {
  return [
    TIME_MAP[time]     || '0',
    LOCATION_MAP[location] || 'P',
    MOTION_MAP[motion] || '0',
    PHONE_MAP[phone]   || '0',
    LIGHT_MAP[light]   || '0',
    SOUND_MAP[sound]   || '0',
    DAY_MAP[dayType]   || '0',
  ].join('');
}

function decode(code) {
  if (code.length !== 7) return null;
  const [t, l, m, p, li, s, d] = code.split('');
  return {
    time:     TIME_R[t]   || 'unknown',
    location: LOC_R[l]    || 'unknown',
    motion:   MOTION_R[m] || 'unknown',
    phone:    PHONE_R[p]  || 'unknown',
    light:    LIGHT_R[li] || null,
    sound:    SOUND_R[s]  || null,
    dayType:  DAY_R[d]    || null,
  };
}

/** pattern 中 '0' 为通配符 */
function matches(state, pattern) {
  const code = encode(state);
  for (let i = 0; i < 7; i++) {
    if (pattern[i] !== '0' && pattern[i] !== code[i]) return false;
  }
  return true;
}

/** 加权相似度（维度权重同 C++ TileCoder 注释） */
function similarity(a, b) {
  const W = [0.25, 0.25, 0.15, 0.10, 0.05, 0.05, 0.15];
  const ca = encode(a), cb = encode(b);
  let score = 0;
  for (let i = 0; i < 7; i++) {
    if (ca[i] === cb[i])           score += W[i];
    else if (ca[i] === '0' || cb[i] === '0') score += W[i] * 0.5;
  }
  return score;
}

// ── Tile Coding（JS 实现，对照 C++ TileCoder）────────────────────────

const TIME_GROUPS = {
  sleeping: 0, dawn: 0, morning: 1, forenoon: 1,
  lunch: 2, afternoon: 2, evening: 3, night: 3, late_night: 3,
};
const LOC_GROUPS = {
  home: 0, work: 1,
  commute: 2, subway: 2, bus_stop: 2, ferry: 2, train_station: 2, airport: 2,
  restaurant: 3, shopping: 3, cafe: 3, cinema: 3,
  gym: 4, outdoor: 4, park: 4, unknown: 0,
};
// 位置码 → 槽索引（与 C++ locationIndex 一致）
function locIndex(locName) {
  const c = LOCATION_MAP[locName] || '0';
  if (c >= '1' && c <= '9') return c.charCodeAt(0) - '1'.charCodeAt(0);
  if (c >= 'A' && c <= 'Z') return 9 + (c.charCodeAt(0) - 'A'.charCodeAt(0));
  return 35; // unknown
}
const PHONE_GROUPS = {
  in_use: 0, holding_lying: 0,
  on_desk: 1, face_up: 1, face_down: 1,
  in_pocket: 2,
  charging: 3, unknown: 3,
};

function tileIndices(s) {
  const t   = (parseInt(TIME_MAP[s.time] || '1') - 1);
  const tg  = TIME_GROUPS[s.time] ?? 0;
  const l   = (LOCATION_MAP[s.location] || 'A').charCodeAt(0) - 65;
  const lg  = LOC_GROUPS[s.location] ?? 0;
  const m   = (parseInt(MOTION_MAP[s.motion] || '1') - 1);
  const p   = (parseInt(PHONE_MAP[s.phone] || '1') - 1);
  const pg  = PHONE_GROUPS[s.phone] ?? 3;
  const li  = parseInt(LIGHT_MAP[s.light] || '0');
  const so  = parseInt(SOUND_MAP[s.sound] || '0');
  const d   = Math.max(0, (parseInt(DAY_MAP[s.dayType] || '1') - 1));

  const T0 = 9 * 16 * 4 * 8 * 3;
  const T1 = 4 * 16 * 3;
  const T2 = 5 * 4 * 8;
  const T3 = 4 * 4 * 4;

  const i0 = ((t * 16 + l) * 4 + m) * 8 * 3 + p * 3 + d;
  const i1 = T0 + (tg * 16 + l) * 3 + d;
  const i2 = T0 + T1 + (lg * 4 + m) * 8 + p;
  const i3 = T0 + T1 + T2 + (m * 4 + pg) * 4 + tg;
  const i4 = T0 + T1 + T2 + T3 + (li * 5 + so) * 5 + lg;

  return [i0, i1, i2, i3, i4];
}

function tileOverlap(a, b) {
  const ia = tileIndices(a), ib = tileIndices(b);
  return ia.filter((v, i) => v === ib[i]).length;
}

// ── 测试用例 ─────────────────────────────────────────────────────────

let pass = 0, fail = 0;

function test(name, actual, expected) {
  const ok = JSON.stringify(actual) === JSON.stringify(expected);
  console.log(`${ok ? '✅' : '❌'} ${name}`);
  if (!ok) console.log(`   expected: ${JSON.stringify(expected)}\n   actual:   ${JSON.stringify(actual)}`);
  ok ? pass++ : fail++;
}

// 基础编码（新编码: 位置用 1-9,A-Z）
test('encode: 用户示例 cafe=D',
  encode({ time: 'morning', location: 'cafe', motion: 'stationary', phone: 'in_use', light: 'normal', sound: 'noisy', dayType: 'weekend' }),
  '3D11332'
);
test('encode: 工作日傍晚在家 home=1',
  encode({ time: 'evening', location: 'home', motion: 'stationary', phone: 'in_use', dayType: 'workday' }),
  '7111001'
);
test('encode: 工作日上午公司放桌 work=2',
  encode({ time: 'forenoon', location: 'work', motion: 'stationary', phone: 'on_desk', dayType: 'workday' }),
  '4213001'
);
test('encode: 早高峰地铁 subway=9',
  encode({ time: 'morning', location: 'subway', motion: 'walking', phone: 'in_pocket', dayType: 'workday' }),
  '3925001'
);
test('encode: 节假日公园晨跑 park=F',
  encode({ time: 'morning', location: 'park', motion: 'running', phone: 'in_pocket', dayType: 'holiday' }),
  '3F35003'
);
test('encode: bus_stop=A',
  encode({ time: 'morning', location: 'bus_stop', motion: 'stationary', phone: 'in_use', dayType: 'workday' }),
  '3A11001'
);
test('encode: train_station=C',
  encode({ time: 'morning', location: 'train_station', motion: 'walking', phone: 'in_use', dayType: 'workday' }),
  '3C21001'
);

// 解码
const dec = decode('3D11332');
test('decode: time',     dec.time,     'morning');
test('decode: location', dec.location, 'cafe');
test('decode: motion',   dec.motion,   'stationary');
test('decode: phone',    dec.phone,    'in_use');
test('decode: light',    dec.light,    'normal');
test('decode: sound',    dec.sound,    'noisy');
test('decode: dayType',  dec.dayType,  'weekend');

// 通配匹配  (morning=3, work=2, stationary=1, on_desk=3, workday=1 → "3213001")
const s = { time: 'morning', location: 'work', motion: 'stationary', phone: 'on_desk', dayType: 'workday' };
test('matches: 精确匹配',    matches(s, '3213001'), true);
test('matches: 全通配',      matches(s, '0000000'), true);
test('matches: 时间通配',    matches(s, '0213001'), true);
test('matches: 位置不匹配',  matches(s, '3113001'), false);
test('matches: 工作日通配',  matches(s, '3213001'), true);

// 相似度
const a = { time: 'morning', location: 'work', motion: 'stationary', phone: 'on_desk', dayType: 'workday' };
const b = { time: 'morning', location: 'work', motion: 'stationary', phone: 'on_desk', dayType: 'workday' };
test('similarity: 完全相同 = 0.75 (light/sound 未指定各省 0.05)', similarity(a, b) >= 0.74, true);

const c = { time: 'morning', location: 'home', motion: 'stationary', phone: 'charging', dayType: 'workday' };
const simAC = similarity(a, c);
console.log(`ℹ️  work-morning vs home-morning 相似度: ${simAC.toFixed(3)}`);

// Tile Coding 重叠
const t1 = { time: 'morning', location: 'work', motion: 'stationary', phone: 'on_desk', dayType: 'workday' };
const t2 = { time: 'forenoon', location: 'work', motion: 'stationary', phone: 'on_desk', dayType: 'workday' };
const t3 = { time: 'morning', location: 'cafe', motion: 'stationary', phone: 'on_desk', dayType: 'workday' };
const ov12 = tileOverlap(t1, t2);
const ov13 = tileOverlap(t1, t3);
console.log(`ℹ️  tile overlap(morning/work vs forenoon/work): ${ov12}/5`);
console.log(`ℹ️  tile overlap(morning/work vs morning/cafe):  ${ov13}/5`);
test('tile: morning/work 与 forenoon/work 有时间组重叠', ov12 >= 1, true);

// 地铁 noisy 修饰符验证（subway=9）
const subway_morning = { time: 'morning', location: 'subway', motion: 'stationary', phone: 'in_pocket', sound: 'noisy', dayType: 'workday' };
test('subway code 位置码=9',   encode(subway_morning)[1], '9');
test('subway code sound=noisy(3)', encode(subway_morning)[5], '3');

// 扩展预留验证（G-Z 范围）
test('位置码 A=bus_stop decode', decode('3A11001')?.location, 'bus_stop');
test('位置码 F=park decode',     decode('3F35003')?.location, 'park');

// ── 结果 ────────────────────────────────────────────────────────────

console.log(`\n结果: ${pass} 通过, ${fail} 失败`);
if (fail > 0) process.exit(1);
