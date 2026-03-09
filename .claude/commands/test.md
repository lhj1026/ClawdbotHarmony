Run the project's JavaScript test suite.

## Test Framework

- **Runner**: Custom lightweight runner at `tests/lib/test-runner.js` (provides `describe`/`it`/`beforeEach`)
- **Assertions**: Custom assertion library at `tests/lib/assert.js` (provides `assertEqual`, `assertTrue`, `assertFalse`, `assertDefined`, `assertDeepEqual`, `assertIncludes`, `assertStartsWith`, `assertGreaterThan`, `assertMatch`, etc.)
- **Execution**: Plain Node.js — no build step needed, run each test file directly with `node <file>`
- **Pattern**: Tests mirror production `.ets` logic as plain JS classes/functions, then validate behavior

## Test Directory Structure

```
tests/
├── lib/                          # Test infrastructure
│   ├── test-runner.js            # describe/it/beforeEach
│   ├── assert.js                 # Assertion functions
│   └── mock-websocket.js         # WebSocket mock
├── unit/                         # Unit tests (pure logic)
├── functional/                   # Functional tests (integration logic)
├── scenario/                     # End-to-end scenario tests
└── context_ai/                   # Context awareness tests
    ├── unit/                     # Context AI unit tests
    ├── functional/               # Context AI functional tests
    └── scenario/                 # Context AI scenario tests
        └── _helpers.js           # Shared helpers (evaluate, loadRecording, buildSnapshotAtTime)
```

## How to Run

### Run all tests (recommended after any code change):
```bash
cd d:/code/AI/ClawdbotHarmony
for f in tests/unit/*.js tests/functional/*.js tests/scenario/*.js tests/context_ai/unit/*.js tests/context_ai/functional/*.js tests/context_ai/scenario/*.js; do echo "=== $f ===" && node "$f" 2>&1 | tail -3; done
```

### Run a specific test file:
```bash
node tests/unit/test_background_task.js
```

### Run a specific test category:
```bash
# Unit tests only
for f in tests/unit/*.js; do echo "=== $f ===" && node "$f" 2>&1 | tail -3; done

# Context AI tests only
for f in tests/context_ai/unit/*.js tests/context_ai/functional/*.js tests/context_ai/scenario/*.js; do echo "=== $f ===" && node "$f" 2>&1 | tail -3; done
```

## Writing New Tests

1. Create a JS file in the appropriate directory (`unit/`, `functional/`, `scenario/`, or `context_ai/*/`)
2. Import the test runner and assertions:
   ```js
   const { describe, it, beforeEach } = require('../lib/test-runner');
   const { assertEqual, assertTrue, assertFalse } = require('../lib/assert');
   ```
3. Mirror the production `.ets` logic as a plain JS class (the "Simulator" pattern):
   - Copy the core logic from the `.ets` file into a JS class
   - Strip HarmonyOS-specific APIs, replace with mock tracking (arrays, counters)
   - Add reference comments with original line numbers for traceability
4. Write `describe`/`it` blocks to test all code paths
5. Tests auto-run on `process.nextTick` — no explicit runner invocation needed

## Known Pre-existing Failures (not regressions)

- `test_i18n_completeness.js`: Duplicate keys in `en` locale (`settings.parallelSessions`)
- `test_auto_mute.js`, `test_delivery_arrival.js`, `test_lunch_recommend.js`: "位置缺失 → 置信度0.5" assertion expects > 0 but gets 0
