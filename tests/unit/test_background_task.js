'use strict';
/**
 * Unit test: Background task management logic.
 *
 * Mirrors the startBackgroundTask / stopBackgroundTask logic from
 * NodeRuntime.ets (lines 825-893) and setForegroundState (lines 352-376).
 *
 * Validates:
 *   - DATA_TRANSFER task starts when going to background with active connection
 *   - LOCATION task starts only when context listeners are registered
 *   - Both tasks stop when returning to foreground
 *   - Guard conditions prevent double-start
 *   - stopBackgroundTask resets both flags
 *   - Standalone mode: LOCATION-only task starts when no gateway connection but context aware
 *   - fallbackContext used when _context unavailable
 *   - module.json5 declares all required backgroundModes
 */

const { describe, it, beforeEach } = require('../lib/test-runner');
const {
  assertEqual, assertTrue, assertFalse, assertIncludes, assertDeepEqual,
} = require('../lib/assert');
const fs = require('fs');
const path = require('path');

// --- Mirror of background task state from NodeRuntime.ets lines 254-255 ---

const BackgroundMode = {
  DATA_TRANSFER: 'dataTransfer',
  LOCATION: 'location',
  AUDIO_RECORDING: 'audioRecording',
};

/**
 * Minimal mirror of NodeRuntime background task logic.
 * Tracks which BackgroundModes have been started/stopped via mock calls.
 */
class BackgroundTaskSimulator {
  constructor() {
    this._backgroundTaskRunning = false;   // line 254
    this._locationTaskRunning = false;     // line 255
    this._contextListenersRegistered = false; // line 240
    this._isInForeground = true;           // line 246
    this._fallbackContext = false;         // line 210
    this.connectionConnected = false;
    this.hasContext = false;               // mirrors _context !== undefined

    // Mock tracking
    this.startedModes = [];
    this.stopCount = 0;
  }

  // Mirror of registerContextListeners (line 566-570)
  registerContextListeners() {
    this._contextListenersRegistered = true;
  }

  // Mirror of startBackgroundTask (lines 849-899)
  async startBackgroundTask() {
    if (this._backgroundTaskRunning) {
      return; // line 850-852
    }

    // DATA_TRANSFER (line 865)
    this.startedModes.push(BackgroundMode.DATA_TRANSFER);
    this._backgroundTaskRunning = true;

    // LOCATION (lines 879-898) — only if context listeners registered
    if (this._contextListenersRegistered && !this._locationTaskRunning) {
      this.startedModes.push(BackgroundMode.LOCATION);
      this._locationTaskRunning = true;
    }
  }

  // Mirror of startLocationOnlyTask (lines 901-921)
  async startLocationOnlyTask() {
    if (this._locationTaskRunning) {
      return;
    }
    this.startedModes.push(BackgroundMode.LOCATION);
    this._locationTaskRunning = true;
  }

  // Mirror of stopBackgroundTask (lines 923-940)
  async stopBackgroundTask() {
    if (!this._backgroundTaskRunning && !this._locationTaskRunning) {
      return;
    }
    let hasCtx = this.hasContext || this._fallbackContext;
    if (!hasCtx) return;
    this.stopCount++;
    this._backgroundTaskRunning = false;
    this._locationTaskRunning = false;
  }

  // Mirror of setForegroundState (lines 352-384)
  async setForegroundState(inForeground) {
    this._isInForeground = inForeground;
    if (inForeground) {
      // line 369
      await this.stopBackgroundTask();
    } else {
      // line 370-383
      let bgCtx = this.hasContext || this._fallbackContext;
      if (bgCtx) {
        if (this.connectionConnected) {
          // 网关模式：启动 DATA_TRANSFER + LOCATION
          await this.startBackgroundTask();
        } else if (this._contextListenersRegistered) {
          // 单机模式但情景智能运行中：仅启动 LOCATION
          await this.startLocationOnlyTask();
        }
      }
    }
  }
}

// --- Tests ---

describe('Background task - startBackgroundTask', function () {
  let sim;
  beforeEach(function () {
    sim = new BackgroundTaskSimulator();
  });

  it('starts DATA_TRANSFER when called', async function () {
    await sim.startBackgroundTask();
    assertTrue(sim._backgroundTaskRunning, 'DATA_TRANSFER should be running');
    assertIncludes(sim.startedModes, BackgroundMode.DATA_TRANSFER);
  });

  it('does NOT start LOCATION when context listeners not registered', async function () {
    await sim.startBackgroundTask();
    assertFalse(sim._locationTaskRunning, 'LOCATION should not run without context listeners');
    assertEqual(sim.startedModes.length, 1, 'only DATA_TRANSFER should start');
  });

  it('starts LOCATION when context listeners ARE registered', async function () {
    sim.registerContextListeners();
    await sim.startBackgroundTask();
    assertTrue(sim._locationTaskRunning, 'LOCATION should be running');
    assertIncludes(sim.startedModes, BackgroundMode.LOCATION);
    assertEqual(sim.startedModes.length, 2, 'both DATA_TRANSFER and LOCATION should start');
  });

  it('does not double-start if already running', async function () {
    sim.registerContextListeners();
    await sim.startBackgroundTask();
    assertEqual(sim.startedModes.length, 2);

    // Second call should be no-op (guard at line 826)
    await sim.startBackgroundTask();
    assertEqual(sim.startedModes.length, 2, 'should not add more modes on second call');
  });
});

describe('Background task - stopBackgroundTask', function () {
  let sim;
  beforeEach(function () {
    sim = new BackgroundTaskSimulator();
    sim.hasContext = true;  // stopBackgroundTask needs context to proceed
  });

  it('resets both flags when stopping', async function () {
    sim.registerContextListeners();
    await sim.startBackgroundTask();
    assertTrue(sim._backgroundTaskRunning);
    assertTrue(sim._locationTaskRunning);

    await sim.stopBackgroundTask();
    assertFalse(sim._backgroundTaskRunning, 'DATA_TRANSFER flag should be reset');
    assertFalse(sim._locationTaskRunning, 'LOCATION flag should be reset');
  });

  it('is no-op when nothing is running', async function () {
    await sim.stopBackgroundTask();
    assertEqual(sim.stopCount, 0, 'should not call stop when nothing running');
  });

  it('stops even if only LOCATION is running (edge case)', async function () {
    // Simulate edge case where _locationTaskRunning=true but _backgroundTaskRunning=false
    sim._locationTaskRunning = true;
    await sim.stopBackgroundTask();
    assertFalse(sim._locationTaskRunning, 'LOCATION should be reset');
    assertEqual(sim.stopCount, 1);
  });
});

describe('Background task - setForegroundState lifecycle', function () {
  let sim;
  beforeEach(function () {
    sim = new BackgroundTaskSimulator();
    sim.connectionConnected = true;
    sim.hasContext = true;
    sim.registerContextListeners();
  });

  it('going to background starts both tasks', async function () {
    await sim.setForegroundState(false);
    assertTrue(sim._backgroundTaskRunning, 'DATA_TRANSFER should start on background');
    assertTrue(sim._locationTaskRunning, 'LOCATION should start on background');
    assertFalse(sim._isInForeground);
  });

  it('returning to foreground stops both tasks', async function () {
    await sim.setForegroundState(false);
    await sim.setForegroundState(true);
    assertFalse(sim._backgroundTaskRunning, 'DATA_TRANSFER should stop on foreground');
    assertFalse(sim._locationTaskRunning, 'LOCATION should stop on foreground');
    assertTrue(sim._isInForeground);
  });

  it('background → foreground → background restarts tasks', async function () {
    await sim.setForegroundState(false);
    await sim.setForegroundState(true);
    await sim.setForegroundState(false);
    assertTrue(sim._backgroundTaskRunning);
    assertTrue(sim._locationTaskRunning);
    assertEqual(sim.startedModes.length, 4, 'should have 2 starts per background transition');
  });

  it('no connection but context listeners → LOCATION-only (standalone mode)', async function () {
    sim.connectionConnected = false;
    await sim.setForegroundState(false);
    assertFalse(sim._backgroundTaskRunning, 'DATA_TRANSFER should not start without connection');
    assertTrue(sim._locationTaskRunning, 'LOCATION should start for standalone context awareness');
    assertIncludes(sim.startedModes, BackgroundMode.LOCATION);
    assertEqual(sim.startedModes.length, 1, 'only LOCATION should start');
  });

  it('no connection AND no context listeners → nothing starts', async function () {
    sim.connectionConnected = false;
    sim._contextListenersRegistered = false;
    await sim.setForegroundState(false);
    assertFalse(sim._backgroundTaskRunning, 'should not start without connection or context');
    assertFalse(sim._locationTaskRunning, 'should not start LOCATION without context listeners');
    assertEqual(sim.startedModes.length, 0);
  });

  it('no context listeners → background starts only DATA_TRANSFER', async function () {
    sim._contextListenersRegistered = false;
    await sim.setForegroundState(false);
    assertTrue(sim._backgroundTaskRunning, 'DATA_TRANSFER should start');
    assertFalse(sim._locationTaskRunning, 'LOCATION should not start without context');
  });
});

describe('Background task - standalone mode (no gateway)', function () {
  let sim;
  beforeEach(function () {
    sim = new BackgroundTaskSimulator();
    sim.connectionConnected = false;
    sim.hasContext = false;
    sim._fallbackContext = true;  // fallback context from setContextAwarenessEnabled
    sim.registerContextListeners();
  });

  it('standalone + context aware → LOCATION-only on background', async function () {
    await sim.setForegroundState(false);
    assertFalse(sim._backgroundTaskRunning, 'no DATA_TRANSFER in standalone mode');
    assertTrue(sim._locationTaskRunning, 'LOCATION should run for sensor keepalive');
  });

  it('standalone foreground→background→foreground→background cycle', async function () {
    await sim.setForegroundState(false);
    assertTrue(sim._locationTaskRunning);
    assertEqual(sim.startedModes.length, 1);

    await sim.setForegroundState(true);
    assertFalse(sim._locationTaskRunning, 'LOCATION should stop on foreground');

    await sim.setForegroundState(false);
    assertTrue(sim._locationTaskRunning, 'LOCATION should restart on background');
    assertEqual(sim.startedModes.length, 2, 'LOCATION started twice across two background transitions');
  });

  it('startLocationOnlyTask does not double-start', async function () {
    await sim.startLocationOnlyTask();
    assertTrue(sim._locationTaskRunning);
    assertEqual(sim.startedModes.length, 1);

    await sim.startLocationOnlyTask();
    assertEqual(sim.startedModes.length, 1, 'guard prevents double-start');
  });

  it('no fallbackContext AND no _context → nothing starts', async function () {
    sim._fallbackContext = false;
    sim.hasContext = false;
    await sim.setForegroundState(false);
    assertFalse(sim._locationTaskRunning, 'no context available, cannot start');
    assertEqual(sim.startedModes.length, 0);
  });

  it('stopBackgroundTask uses fallbackContext', async function () {
    await sim.setForegroundState(false);
    assertTrue(sim._locationTaskRunning);

    await sim.stopBackgroundTask();
    assertFalse(sim._locationTaskRunning, 'should stop using fallbackContext');
    assertEqual(sim.stopCount, 1);
  });
});

// --- module.json5 backgroundModes validation ---

describe('module.json5 - backgroundModes configuration', function () {
  it('declares all required backgroundModes', function () {
    const moduleJsonPath = path.resolve(__dirname, '../../entry/src/main/module.json5');
    const raw = fs.readFileSync(moduleJsonPath, 'utf-8');
    // json5: strip // comments and trailing commas for JSON.parse
    const cleaned = raw
      .replace(/\/\/.*$/gm, '')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/,(\s*[}\]])/g, '$1');
    const parsed = JSON.parse(cleaned);

    const abilities = parsed.module.abilities;
    assertTrue(Array.isArray(abilities) && abilities.length > 0, 'should have abilities');

    const entryAbility = abilities[0];
    const modes = entryAbility.backgroundModes;
    assertTrue(Array.isArray(modes), 'backgroundModes should be an array');

    assertIncludes(modes, 'dataTransfer', 'must include dataTransfer for WebSocket');
    assertIncludes(modes, 'location', 'must include location for GPS/WiFi background sensing');
    assertIncludes(modes, 'audioRecording', 'must include audioRecording for SilentMode');
  });

  it('declares KEEP_BACKGROUND_RUNNING permission', function () {
    const moduleJsonPath = path.resolve(__dirname, '../../entry/src/main/module.json5');
    const raw = fs.readFileSync(moduleJsonPath, 'utf-8');
    const cleaned = raw
      .replace(/\/\/.*$/gm, '')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/,(\s*[}\]])/g, '$1');
    const parsed = JSON.parse(cleaned);

    const perms = parsed.module.requestPermissions;
    assertTrue(Array.isArray(perms), 'should have requestPermissions');
    const permNames = perms.map(p => p.name);
    assertIncludes(permNames, 'ohos.permission.KEEP_BACKGROUND_RUNNING');
  });

  it('declares LOCATION permission', function () {
    const moduleJsonPath = path.resolve(__dirname, '../../entry/src/main/module.json5');
    const raw = fs.readFileSync(moduleJsonPath, 'utf-8');
    const cleaned = raw
      .replace(/\/\/.*$/gm, '')
      .replace(/\/\*[\s\S]*?\*\//g, '')
      .replace(/,(\s*[}\]])/g, '$1');
    const parsed = JSON.parse(cleaned);

    const perms = parsed.module.requestPermissions;
    const permNames = perms.map(p => p.name);
    assertIncludes(permNames, 'ohos.permission.LOCATION');
  });
});
