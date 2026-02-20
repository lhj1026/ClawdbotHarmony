'use strict';
/**
 * 位置编码器测试
 * 对应设计文档: §5.1 感知域架构, §6.2 软匹配策略 - 位置多源融合
 * 覆盖: GPS编码/WiFi编码/蓝牙编码/多源融合/缺失/分布格式
 */

const { describe, it } = require('../../lib/test-runner');
const {
  assertEqual, assertTrue, assertGreaterThan, assertLessThan,
  assertDefined, assertUndefined
} = require('../../lib/assert');

// ── JS 镜像：位置编码器 ──

/** Haversine 距离(米) */
function haversine(lat1, lon1, lat2, lon2) {
  const R = 6371000;
  const dLat = (lat2 - lat1) * Math.PI / 180;
  const dLon = (lon2 - lon1) * Math.PI / 180;
  const a = Math.sin(dLat/2)**2 + Math.cos(lat1*Math.PI/180)*Math.cos(lat2*Math.PI/180)*Math.sin(dLon/2)**2;
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1-a));
}

/** GPS → 已知地点概率分布 */
function encodeGPS(lat, lon, accuracy, knownPlaces) {
  if (lat == null || lon == null) return { distribution: {}, quality: 0 };
  const dist = {};
  const q = Math.min(1.0, 50 / Math.max(accuracy || 50, 1));
  for (const p of knownPlaces) {
    const d = haversine(lat, lon, p.lat, p.lon);
    const radius = p.radius || 100;
    if (d <= radius) {
      dist[p.id] = 1.0 * q;
    } else {
      const decay = Math.exp(-0.5 * ((d - radius) / 100) ** 2);
      if (decay > 0.05) dist[p.id] = parseFloat((decay * q).toFixed(4));
    }
  }
  return { distribution: dist, quality: q };
}

/** WiFi SSID → 地点概率 */
function encodeWiFi(ssid, knownWiFi) {
  if (!ssid) return { distribution: {}, quality: 0 };
  for (const w of knownWiFi) {
    if (w.ssid === ssid) return { distribution: { [w.placeId]: 0.95 }, quality: 0.9 };
  }
  return { distribution: {}, quality: 0.3 };
}

/** 蓝牙设备 → 地点概率 */
function encodeBluetooth(devices, knownBT) {
  if (!devices || devices.length === 0) return { distribution: {}, quality: 0 };
  const dist = {};
  for (const d of devices) {
    for (const b of knownBT) {
      if (b.mac === d.mac) {
        dist[b.placeId] = Math.max(dist[b.placeId] || 0, 0.8);
      }
    }
  }
  return { distribution: dist, quality: Object.keys(dist).length > 0 ? 0.8 : 0.2 };
}

/** 多源融合：取每个地点各源最高置信度 */
function fuseLocation(sources) {
  const merged = {};
  let maxQuality = 0;
  for (const src of sources) {
    maxQuality = Math.max(maxQuality, src.quality);
    for (const [k, v] of Object.entries(src.distribution)) {
      merged[k] = Math.max(merged[k] || 0, v);
    }
  }
  return { distribution: merged, quality: maxQuality };
}

// ── 已知地点/WiFi/蓝牙配置 ──
const PLACES = [
  { id: 'home', lat: 39.9042, lon: 116.4074, radius: 50 },
  { id: 'office', lat: 39.9142, lon: 116.4174, radius: 100 },
  { id: 'market', lat: 39.9242, lon: 116.4274, radius: 200 },
];
const WIFI = [
  { ssid: 'HomeWiFi', placeId: 'home' },
  { ssid: 'OfficeNet', placeId: 'office' },
];
const BT = [
  { mac: 'AA:BB:CC:DD:EE:01', placeId: 'home' },
  { mac: 'AA:BB:CC:DD:EE:02', placeId: 'office' },
];

// ── 测试 ──

describe('LocationEncoder - GPS编码', function () {
  it('精确匹配家 → home=1.0', function () {
    const r = encodeGPS(39.9042, 116.4074, 10, PLACES);
    assertEqual(r.distribution.home, 1.0);
  });

  it('距家200m → home衰减', function () {
    // 偏移约200m
    const r = encodeGPS(39.9060, 116.4074, 10, PLACES);
    assertDefined(r.distribution.home);
    assertLessThan(r.distribution.home, 1.0);
  });

  it('精度差(500m) → quality降低', function () {
    const r = encodeGPS(39.9042, 116.4074, 500, PLACES);
    assertLessThan(r.quality, 0.2);
  });

  it('缺失GPS → quality=0', function () {
    const r = encodeGPS(null, null, null, PLACES);
    assertEqual(r.quality, 0);
  });

  it('远离所有地点 → 空分布', function () {
    const r = encodeGPS(40.0, 117.0, 10, PLACES);
    assertEqual(Object.keys(r.distribution).length, 0);
  });

  it('所有分布值在 [0,1]', function () {
    const r = encodeGPS(39.9100, 116.4100, 30, PLACES);
    for (const v of Object.values(r.distribution)) {
      assertTrue(v >= 0 && v <= 1.0, `val=${v}`);
    }
  });
});

describe('LocationEncoder - WiFi编码', function () {
  it('已知WiFi → 高置信度', function () {
    const r = encodeWiFi('HomeWiFi', WIFI);
    assertEqual(r.distribution.home, 0.95);
    assertEqual(r.quality, 0.9);
  });

  it('未知WiFi → 空分布', function () {
    const r = encodeWiFi('StrangerWiFi', WIFI);
    assertEqual(Object.keys(r.distribution).length, 0);
  });

  it('无WiFi → quality=0', function () {
    const r = encodeWiFi(null, WIFI);
    assertEqual(r.quality, 0);
  });
});

describe('LocationEncoder - 蓝牙编码', function () {
  it('已知蓝牙设备 → 地点概率', function () {
    const r = encodeBluetooth([{ mac: 'AA:BB:CC:DD:EE:01' }], BT);
    assertEqual(r.distribution.home, 0.8);
  });

  it('无设备 → quality=0', function () {
    const r = encodeBluetooth([], BT);
    assertEqual(r.quality, 0);
  });

  it('未知设备 → 空分布', function () {
    const r = encodeBluetooth([{ mac: 'FF:FF:FF:FF:FF:FF' }], BT);
    assertEqual(Object.keys(r.distribution).length, 0);
  });
});

describe('LocationEncoder - 多源融合', function () {
  it('GPS+WiFi融合 → 取max', function () {
    const gps = encodeGPS(39.9042, 116.4074, 10, PLACES);
    const wifi = encodeWiFi('HomeWiFi', WIFI);
    const fused = fuseLocation([gps, wifi]);
    assertEqual(fused.distribution.home, 1.0); // GPS给1.0
  });

  it('仅WiFi可用时仍有结果', function () {
    const gps = encodeGPS(null, null, null, PLACES);
    const wifi = encodeWiFi('OfficeNet', WIFI);
    const fused = fuseLocation([gps, wifi]);
    assertEqual(fused.distribution.office, 0.95);
    assertEqual(fused.quality, 0.9);
  });

  it('全部缺失 → 空结果', function () {
    const fused = fuseLocation([
      encodeGPS(null, null, null, PLACES),
      encodeWiFi(null, WIFI),
      encodeBluetooth([], BT),
    ]);
    assertEqual(Object.keys(fused.distribution).length, 0);
    assertEqual(fused.quality, 0);
  });

  it('三源融合 → 覆盖率更高', function () {
    const gps = encodeGPS(39.9042, 116.4074, 100, PLACES); // quality=0.5
    const wifi = encodeWiFi('HomeWiFi', WIFI);
    const bt = encodeBluetooth([{ mac: 'AA:BB:CC:DD:EE:01' }], BT);
    const fused = fuseLocation([gps, wifi, bt]);
    assertGreaterThan(fused.distribution.home, 0.9);
    assertEqual(fused.quality, 0.9);
  });
});
