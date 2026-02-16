# ClawdbotHarmony 自动化测试计划

## Context

项目基于 HarmonyOS NEXT (ArkUI/ArkTS)，代码引用 `@kit.*`/`@ohos.*` 模块，无法在 Node.js 中直接运行。

**解决方案**: 使用"逻辑镜像"模式 —— 将纯逻辑函数提取为独立 JS 进行测试，每个测试文件注释标注对应的源文件和行号。

## 目录结构

```
tests/
  run_all.sh                          # 主测试运行器
  TEST_PLAN.md                        # 本文件
  lib/
    assert.js                         # 轻量断言库（零依赖）
    test-runner.js                    # 简易测试框架 describe/it
    mock-websocket.js                 # Mock WebSocket 网关服务器
  unit/                               # 单元测试（15 文件，~131 用例）
    test_build_media_url.js           # URL 构建
    test_resolve_avatar_url.js        # 头像 URL 解析
    test_connection_state.js          # 连接状态组合
    test_update_status.js             # 状态文本计算
    test_build_node_options.js        # 能力→命令映射
    test_build_client_info.js         # 客户端信息构建
    test_extract_a2ui_content.js      # A2UI 内容提取
    test_handle_agent_event.js        # Agent 事件解析（文本提取+状态检测）
    test_handle_chat_event.js         # Chat 事件解析+去重
    test_i18n.js                      # 国际化翻译查找
    test_invoke_result.js             # InvokeResult 工厂方法
    test_models.js                    # 数据模型构造函数
    test_is_loopback.js               # 回环地址检测
    test_gateway_protocol.js          # 协议常量完整性
    test_constants.js                 # 配置常量验证
  functional/                         # 功能测试（6 文件，~157 用例）
    test_capability_mapping.js        # 完整能力开关→命令映射（20 tests）
    test_connection_state_machine.js  # 25种状态组合+状态文本（49 tests）
    test_agent_event_dedup.js         # Agent/Chat 事件去重逻辑（12 tests）
    test_event_state_detection.js     # 多信号字段状态判定（36 tests）
    test_version_consistency.sh       # 4处版本一致性+semver 格式（13 tests）
    test_i18n_completeness.js         # 中英文 key 完整性+命名空间覆盖（27 tests）
  scenario/                           # 场景测试（5 文件，~85 用例）
    test_gateway_connect_flow.js      # 网关连接握手流程（19 tests）
    test_chat_message_flow.js         # 聊天消息流 delta→final（18 tests）
    test_invoke_flow.js               # 设备能力调用流程（13 tests）
    test_reconnection.js              # 断线重连+指数退避（18 tests）
    test_dedup_agent_vs_chat.js       # Agent/Chat 去重端到端（17 tests）
```

## 测试覆盖的源文件

| 源文件 | 测试覆盖 |
|------|---------|
| `service/gateway/NodeRuntime.ets` | buildMediaUrl, resolveAvatarUrl, connectionState, updateStatus, buildNodeOptions, buildClientInfo, extractA2UIContent, handleOperatorEvent (agent/chat 事件解析) |
| `service/gateway/GatewaySession.ets` | isLoopback, WebSocket RPC 协议, 重连指数退避 |
| `service/gateway/GatewayModels.ets` | InvokeResult.success()/error(), ConnectionState 枚举 |
| `service/gateway/GatewayProtocol.ets` | VERSION=3, 12 Capability 常量, 23 Command 常量 |
| `common/I18n.ets` | 翻译查找 t(), 语言切换, zh/en key 对称性, 命名空间完整性 |
| `common/Constants.ets` | 端口/URL/重连参数/Token限制 |
| `model/Models.ets` | ChatMessage/MemoryItem/ChatSession 构造函数+默认值 |
| `AppScope/app.json5` + 3处 | 4处版本号一致性 |

## 测试规模（实际）

| 类别 | 文件数 | 测试用例数 |
|------|--------|-----------|
| 单元测试 | 15 | ~131 |
| 功能测试 | 6 | ~157 |
| 场景测试 | 5 | ~85 |
| **总计** | **26** | **~373** |

## 运行方法

```bash
# 运行全部测试
bash tests/run_all.sh

# 运行单个测试
node tests/unit/test_build_media_url.js

# 按类别运行
for f in tests/unit/test_*.js; do node "$f"; done
for f in tests/functional/test_*.js; do node "$f"; done
bash tests/functional/test_version_consistency.sh
for f in tests/scenario/test_*.js; do node "$f"; done
```

## 设计原则

- **零外部依赖**: 测试框架和断言库完全自包含（纯 JS），无需 npm install
- **逻辑镜像**: 每个测试文件复制对应源码纯逻辑并注释来源行号，与 ArkTS 源码保持同步
- **直接解析源文件**: I18n 完整性和版本一致性测试直接 regex 解析 .ets 文件，确保真实数据一致
- **场景测试用 Node.js 内置模块**: mock-websocket 基于 `http` + `crypto` 实现 WebSocket 升级握手，不需要 `ws` 包

## Pre-Commit 检查（scripts/pre-commit-tests.sh）

除测试套件外，还有 5 项预提交检查：

1. **版本一致性** — app.json5 / NodeRuntime.ets / Index.ets / SettingsPage.ets 四处版本号必须一致
2. **关键文件存在** — 13 个核心配置和源码文件必须存在
3. **UI 资源完整** — icon.png / startIcon.png / talkmode.jpg / ic_talk_mode.png / ic_hangup.png 必须存在且被 git 跟踪
4. **敏感数据检测** — 扫描 staged 文件中的 API key / AWS key / GitHub token 模式
5. **编译检查** — 通过 hvigor 构建验证代码可编译
