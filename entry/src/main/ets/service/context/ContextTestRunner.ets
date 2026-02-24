/**
 * ContextTestRunner.ets
 *
 * 情景智能集成测试框架
 * 从 rawfile/test/context_test_cases.json 读取测试用例,
 * 注入到 SensorTray, 运行引擎评估, 逐阶段输出调试信息。
 */
import { ContextEngineService, ContextSnapshot, MatchResult } from './ContextEngine';
import DataTray from './DataTray';
import { ContextAwarenessService } from './ContextAwarenessService';
import { LogService } from '../../common/LogService';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';

const TAG = 'ContextTestRunner';

// WiFi hotspot detection patterns (mirrors CAS.WIFI_HOTSPOT_PATTERNS)
const HOTSPOT_PATTERNS: string[] = [
  'iPhone', 'Android', 'Pixel', 'Galaxy', '的iPhone', 'HUAWEI-', '手机',
  'Hotspot', '热点', 'DIRECT-'
];
const PUBLIC_PREFIXES: string[] = ['CMCC', 'ChinaNet', 'ChinaUnicom', 'eduroam'];

/** 测试用例 */
export interface TestCase {
  id: string;
  name: string;
  description: string;
  input: Record<string, string | number | boolean>;
  expected: Record<string, string | number | boolean | string[]>;
}

/** 测试用例文件格式 */
interface TestCasesFile {
  version: number;
  description: string;
  cases: TestCase[];
}

/** 阶段调试输出 */
export interface StageOutput {
  stage: string;          // 'input' | 'tray' | 'tier' | 'engine' | 'llm' | 'output'
  timestamp: number;
  data: Record<string, string>;
}

/** 单个测试结果 */
export interface TestResult {
  caseId: string;
  caseName: string;
  passed: boolean;
  stages: StageOutput[];
  failures: string[];
  durationMs: number;
}

export class ContextTestRunner {
  private log: LogService = LogService.getInstance();

  /**
   * 从 rawfile 读取测试用例
   */
  async loadTestCases(context: common.UIAbilityContext): Promise<TestCase[]> {
    try {
      let mgr = context.resourceManager;
      let rawData = await mgr.getRawFileContent('test/context_test_cases.json');
      let decoder = new util.TextDecoder('utf-8');
      let jsonStr = decoder.decodeToString(rawData);
      let file = JSON.parse(jsonStr) as TestCasesFile;
      this.log.info(TAG, `Loaded ${file.cases.length} test cases (v${file.version})`);
      return file.cases;
    } catch (err) {
      this.log.error(TAG, `Failed to load test cases: ${(err as Error).message}`);
      return [];
    }
  }

  /**
   * 执行所有测试用例
   */
  async runAll(context: common.UIAbilityContext): Promise<TestResult[]> {
    let cases = await this.loadTestCases(context);
    if (cases.length === 0) {
      this.log.warn(TAG, 'No test cases found');
      return [];
    }

    let results: TestResult[] = [];
    for (let tc of cases) {
      let result = await this.runCase(tc);
      results.push(result);
    }
    return results;
  }

  /**
   * WiFi mobility classification (mirrors CAS.classifyWifi)
   */
  private classifyWifi(ssid: string): string {
    if (ssid.length === 0) return 'fixed';
    for (let p of HOTSPOT_PATTERNS) {
      if (ssid.indexOf(p) >= 0) return 'hotspot';
    }
    for (let p of PUBLIC_PREFIXES) {
      if (ssid.startsWith(p)) return 'public';
    }
    return 'fixed';
  }

  /**
   * 执行单个测试用例
   */
  async runCase(testCase: TestCase): Promise<TestResult> {
    let startTime = Date.now();
    let stages: StageOutput[] = [];
    let failures: string[] = [];

    let engine = ContextEngineService.getInstance();
    let input = testCase.input;

    // ═══ Stage 1: INPUT — 清除旧数据 + 注入测试数据到 SensorTray ═══
    let inputData: Record<string, string> = {};

    // Compute derived fields from hour
    let hour = Number(input['hour'] ?? 0);
    let dayOfWeek = Number(input['dayOfWeek'] ?? 0);
    let isWeekend = (dayOfWeek === 0 || dayOfWeek === 6);
    let timeOfDay: string;
    if (hour >= 5 && hour < 12) timeOfDay = 'morning';
    else if (hour >= 12 && hour < 17) timeOfDay = 'afternoon';
    else if (hour >= 17 && hour < 21) timeOfDay = 'evening';
    else timeOfDay = 'night';

    // Clear optional tray keys first to prevent stale data
    let clearKeys = ['geofence', 'wifiSsid', 'wifiGeofence', 'wifiLost', 'wifiLostCategory',
      'bt_device_names', 'bt_fixed_devices', 'bt_vehicle_devices', 'bt_in_vehicle',
      'latitude', 'longitude', 'stepCount', 'speed', 'transportMode',
      'sensorTier', 'heart_rate_status', 'wearing_state'];
    for (let k of clearKeys) {
      DataTray.put(k, '', 0.0, 'test_clear');
    }

    // Write all input fields to tray
    let trayKeys: Record<string, string> = {
      'hour': hour.toString(),
      'dayOfWeek': dayOfWeek.toString(),
      'isWeekend': isWeekend ? 'true' : 'false',
      'timeOfDay': timeOfDay,
      'motionState': (input['motionState'] ?? 'unknown') as string,
      'batteryLevel': (input['batteryLevel'] ?? '100').toString(),
      'isCharging': (input['isCharging'] ?? false).toString(),
      'networkType': (input['networkType'] ?? 'none') as string,
    };

    // Optional tray fields — only write non-empty values
    let wifiSsid = (input['wifiSsid'] ?? '') as string;
    if (wifiSsid.length > 0) {
      trayKeys['wifiSsid'] = wifiSsid;
    }
    let geofenceInput = (input['geofence'] ?? '') as string;
    if (geofenceInput.length > 0) {
      trayKeys['geofence'] = geofenceInput;
    }
    if (input['btDeviceNames'] !== undefined) {
      trayKeys['bt_device_names'] = input['btDeviceNames'] as string;
    }
    if (input['btFixedDevices'] !== undefined) {
      trayKeys['bt_fixed_devices'] = input['btFixedDevices'] as string;
    }
    if (input['btVehicleDevices'] !== undefined) {
      trayKeys['bt_vehicle_devices'] = input['btVehicleDevices'] as string;
    }
    if (input['btInVehicle'] !== undefined) {
      trayKeys['bt_in_vehicle'] = input['btInVehicle'] as string;
    }

    for (let key of Object.keys(trayKeys)) {
      DataTray.put(key, trayKeys[key], 1.0, 'test');
      inputData[key] = trayKeys[key];
    }

    stages.push({
      stage: 'input',
      timestamp: Date.now(),
      data: inputData,
    });

    // ═══ Stage 2: TRAY — 读取 tray snapshot ═══
    let snapshot = DataTray.getSnapshot();
    let trayData: Record<string, string> = {
      'keysWritten': Object.keys(trayKeys).length.toString(),
      'timeOfDay': snapshot.timeOfDay,
      'hour': snapshot.hour,
      'motionState': snapshot.motionState,
      'geofence': snapshot.geofence ?? '(none)',
      'wifiSsid': snapshot.wifiSsid ?? '(none)',
      'networkType': snapshot.networkType,
    };

    stages.push({
      stage: 'tray',
      timestamp: Date.now(),
      data: trayData,
    });

    // ═══ Stage 3: TIER — 根据输入推算层级 ═══
    // Compute expected tier from input (mirrors CAS tier logic):
    // Tier 1: stationary + known geofence
    // Tier 2: walking/driving/unknown location
    // Tier 3: significant change
    let motionState = (input['motionState'] ?? 'unknown') as string;
    let hasKnownGeofence = geofenceInput.length > 0;
    let computedTier: number;
    if (motionState === 'stationary' && hasKnownGeofence) {
      computedTier = 1;
    } else if (motionState === 'driving' || motionState === 'transit' || !hasKnownGeofence) {
      computedTier = 2;
    } else {
      computedTier = 1;
    }

    let tierData: Record<string, string> = {
      'computedTier': computedTier.toString(),
      'motionState': motionState,
      'hasKnownGeofence': hasKnownGeofence.toString(),
    };

    stages.push({
      stage: 'tier',
      timestamp: Date.now(),
      data: tierData,
    });

    // ═══ Stage 4: ENGINE — 规则引擎评估 ═══
    let results = engine.evaluate(snapshot, 5);
    let matchedRuleIds: string[] = [];
    let matchDetails: string[] = [];
    for (let r of results) {
      matchedRuleIds.push(r.ruleId);
      matchDetails.push(`${r.ruleId}(${(r.confidence * 100).toFixed(0)}%)`);
    }

    let engineData: Record<string, string> = {
      'matchCount': results.length.toString(),
      'matchedRuleIds': matchedRuleIds.length > 0 ? matchedRuleIds.join(',') : '(none)',
      'matchDetails': matchDetails.length > 0 ? matchDetails.join(', ') : '(no matches)',
    };

    stages.push({
      stage: 'engine',
      timestamp: Date.now(),
      data: engineData,
    });

    // ═══ Stage 5: LLM — LLM 兜底判断 ═══
    let llmWouldTrigger = results.length === 0;
    let llmData: Record<string, string> = {};
    if (llmWouldTrigger) {
      llmData['status'] = 'would_trigger';
      llmData['note'] = 'LLM skipped in test (no engine match)';
    } else {
      llmData['status'] = 'skipped';
      llmData['reason'] = `engine matched ${results.length} rules`;
    }

    stages.push({
      stage: 'llm',
      timestamp: Date.now(),
      data: llmData,
    });

    // ═══ Stage 6: OUTPUT — 构建 actual 并对比 expected ═══
    // Compute wifi mobility from test input
    let wifiMobility = this.classifyWifi(wifiSsid);

    // geofenceAssociated: based on what WE injected (not stale tray data)
    let geofenceAssociated = geofenceInput.length > 0;

    let actual: Record<string, string | number | boolean | string[]> = {
      'tier': computedTier,
      'motionState': snapshot.motionState,
      'engineMatchCount': results.length,
      'matchedRuleIds': matchedRuleIds,
      'hasEngineMatch': results.length > 0,
      'llmWouldTrigger': llmWouldTrigger,
      'wifiMobility': wifiMobility,
      'geofenceAssociated': geofenceAssociated,
      'timeOfDay': snapshot.timeOfDay,
      'hour': snapshot.hour,
    };

    // Top recommendation title from engine
    if (results.length > 0) {
      let topAction = results[0].action;
      if (topAction && topAction.payload) {
        try {
          let payload = JSON.parse(topAction.payload) as Record<string, string>;
          actual['recommendationTitle'] = payload['title'] ?? topAction.payload;
        } catch {
          actual['recommendationTitle'] = topAction.payload;
        }
      }
    }

    // Compare with expected
    failures = this.compareExpected(actual, testCase.expected);

    let outputData: Record<string, string> = {
      'passed': (failures.length === 0).toString(),
      'failureCount': failures.length.toString(),
      'engineMatches': results.length.toString(),
      'wifiMobility': wifiMobility,
      'geofenceAssociated': geofenceAssociated.toString(),
      'computedTier': computedTier.toString(),
    };
    if (failures.length > 0) {
      outputData['failures'] = failures.join('; ');
    }

    stages.push({
      stage: 'output',
      timestamp: Date.now(),
      data: outputData,
    });

    let durationMs = Date.now() - startTime;
    let passed = failures.length === 0;

    this.log.info(TAG, `Test ${testCase.id} "${testCase.name}": ${passed ? 'PASSED' : 'FAILED'} (${durationMs}ms)${failures.length > 0 ? ' - ' + failures.join('; ') : ''}`);

    return {
      caseId: testCase.id,
      caseName: testCase.name,
      passed,
      stages,
      failures,
      durationMs,
    };
  }

  /**
   * 对比 actual vs expected, 返回失败原因列表
   */
  private compareExpected(
    actual: Record<string, string | number | boolean | string[]>,
    expected: Record<string, string | number | boolean | string[]>
  ): string[] {
    let failures: string[] = [];

    for (let key of Object.keys(expected)) {
      let exp = expected[key];
      let act = actual[key];

      if (key === 'matchedRuleIds') {
        // Array containment check: expected IDs should be subset of actual
        let expIds = exp as string[];
        let actIds = (act as string[] ?? []);
        for (let expId of expIds) {
          if (actIds.indexOf(expId) < 0) {
            failures.push(`matchedRuleIds: "${expId}" not in [${actIds.join(',')}]`);
          }
        }
      } else if (key === 'recommendationTitleContains') {
        let title = (actual['recommendationTitle'] ?? '') as string;
        let needle = exp as string;
        if (title.indexOf(needle) < 0) {
          failures.push(`title "${title}" !contain "${needle}"`);
        }
      } else if (key === 'hasEngineMatch' || key === 'geofenceAssociated' ||
                 key === 'llmWouldTrigger') {
        let actBool = !!act;
        let expBool = !!exp;
        if (actBool !== expBool) {
          failures.push(`${key}: expected=${expBool}, got=${actBool}`);
        }
      } else if (key === 'engineMatchCountMin') {
        // Minimum match count check
        let actNum = Number(actual['engineMatchCount'] ?? 0);
        let expMin = Number(exp);
        if (actNum < expMin) {
          failures.push(`engineMatchCount: expected>=${expMin}, got=${actNum}`);
        }
      } else {
        // Direct equality
        if (act === undefined || act === null) {
          failures.push(`${key}: expected=${exp}, got=undefined`);
        } else if (act.toString() !== exp.toString()) {
          failures.push(`${key}: expected=${exp}, got=${act}`);
        }
      }
    }

    return failures;
  }

  /**
   * 格式化测试结果为聊天消息文本
   */
  formatResult(result: TestResult): string {
    let lines: string[] = [];
    let icon = result.passed ? '✅' : '❌';
    lines.push(`${icon} ${result.caseId} - ${result.caseName}`);

    for (let i = 0; i < result.stages.length; i++) {
      let s = result.stages[i];
      let stageNum = `[${i + 1}/${result.stages.length}]`;
      let kvParts: string[] = [];
      for (let k of Object.keys(s.data)) {
        let v = s.data[k];
        if (v.length > 50) v = v.substring(0, 47) + '...';
        kvParts.push(`${k}=${v}`);
      }
      lines.push(`${stageNum} ${s.stage} -> ${kvParts.join(', ')}`);
    }

    if (result.failures.length > 0) {
      for (let f of result.failures) {
        lines.push(`  FAIL: ${f}`);
      }
    }
    lines.push(`${icon} ${result.passed ? 'PASSED' : 'FAILED'} (${result.durationMs}ms)`);
    return lines.join('\n');
  }

  /**
   * 格式化所有测试结果的汇总
   */
  formatSummary(results: TestResult[]): string {
    let passed = 0;
    let failed = 0;
    for (let r of results) {
      if (r.passed) passed++;
      else failed++;
    }
    let total = results.length;
    let icon = failed === 0 ? '✅' : '⚠️';
    let lines: string[] = [];
    lines.push(`${icon} 测试汇总: ${passed}/${total} 通过`);
    if (failed > 0) {
      lines.push(`❌ ${failed} 个用例失败:`);
      for (let r of results) {
        if (!r.passed) {
          lines.push(`  - ${r.caseId}: ${r.failures.join('; ')}`);
        }
      }
    }
    return lines.join('\n');
  }
}
