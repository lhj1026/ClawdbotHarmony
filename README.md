# ClawdBot for HarmonyOS

<p align="center">
  <strong>HarmonyOS NEXT AI Assistant</strong><br>
  多模态个人 AI 助手 · Multi-modal Personal AI Assistant
</p>

<p align="center">
  <img src="https://img.shields.io/badge/version-2.21.7-blue" alt="Version">
  <img src="https://img.shields.io/badge/HarmonyOS-NEXT-red" alt="HarmonyOS">
  <img src="https://img.shields.io/badge/API-12~22-green" alt="API Level">
</p>

---

## 中文

### 简介

ClawdBot 是一款运行在 HarmonyOS NEXT 上的全功能个人 AI 助手应用。支持双工作模式（单机模式 / 节点模式），集成 15 项设备能力、语音交互、持久记忆、定时任务、网页浏览、A2UI 动态表单等功能。

### 工作模式

| 模式 | 说明 |
|------|------|
| **单机模式** | 直接调用 LLM API（SiliconFlow、OpenAI、Anthropic、OpenRouter、Ollama），本地执行所有工具 |
| **节点模式** | 通过 WebSocket 连接 [OpenClaw](https://github.com/openclaw/openclaw) Gateway 服务端，双会话架构（operator + node），指数退避自动重连 |

### 核心特性

#### 🤖 AI 能力

**多模型支持**
- 提供商：Anthropic (Claude)、OpenAI、OpenRouter、SiliconFlow、本地 Ollama 及任意 OpenAI 兼容 API
- 每个提供商独立保存 API Key、模型名、Base URL
- Tool-use 循环（最多 8 轮），自动调用工具完成复杂任务
- 弱模型自动分发：当模型不调用 tool 时，根据关键词自动触发正确的工具
- Soul 人格系统：可自定义 AI 行为风格和语气

**语音交互**
- 按住录音，松手自动识别并发送
- ASR 引擎：sherpa-onnx + SenseVoice-Small INT8（离线识别，支持中英日韩粤）
- TTS 自动朗读 AI 回复（HarmonyOS CoreSpeechKit，在线/离线双引擎）
- 对话模式（Talk Mode）：连续语音对话，自动检测静默
- 语音消息气泡 UI，WAV 录音保存，支持点击播放

#### 📱 设备能力（15 项）

| 能力 | 命令 | 说明 |
|------|------|------|
| **定位** | `location.get` | GPS 定位；天气查询时自动附加位置 |
| **相机** | `camera.snap`, `camera.clip` | 前/后摄拍照、录制视频，自动压缩 |
| **截屏/录屏** | `screen.capture`, `screen.record` | App 窗口截图、屏幕录制 |
| **通知** | `notification.show`, `system.notify` | 系统通知推送 |
| **TTS/音频** | `speaker.speak`, `speaker.play`, `speaker.stop` | 文字转语音、播放音频 |
| **麦克风** | `mic.record` | 静默录音（后台录制环境音，无需用户操作） |
| **声纹识别** | 内置 | 本地说话人识别/验证（sherpa-onnx，离线） |
| **短信** | `sms.send` | 发送短信 |
| **邮件** | `email.send` | 发送邮件（SMTP） |
| **日历** | `calendar.add` | 创建日历事件、设置提醒 |
| **Canvas** | `canvas.present/hide/navigate/eval/snapshot` | WebView 浏览器，支持 JS 执行、截图 |
| **A2UI** | `canvas.a2ui.push/reset` | 动态表单渲染，用户交互事件回传 |
| **终端** | `exec.run` | Shell 命令执行（NAPI C++ popen） |
| **文件系统** | 内置 | 沙箱文件读写、目录列表、内容搜索 |
| **记忆** | 内置 | 持久化记忆存储与语义搜索 |
| **定时任务** | 内置 | 一次性或周期性定时任务 |

#### 🎨 A2UI 动态表单

支持 OpenClaw Gateway 推送的 A2UI 动态 UI：

- **组件支持**：Text、Button、TextField、CheckBox、ChoicePicker、Slider、DateTimeInput、Image、Video、Audio、Column、Row、Card、List、Tabs、Modal、Divider
- **交互事件**：用户点击按钮等交互会自动发送事件到 Gateway，触发 Agent 响应
- **内联渲染**：表单直接在聊天界面中渲染，无需跳转页面
- **简化格式兼容**：自动转换 WhatsApp/Telegram 发送的简化 JSON 格式

### 使用示例

```
用户: 今天天气怎么样？
→ 自动获取 GPS 位置，搜索当地天气并回复

用户: 拍张照片
→ 调用后置摄像头拍照，照片内联显示在聊天中

用户: 录一段 10 秒的视频
→ 录制视频并返回

用户: 截屏发给我
→ 截取当前 App 屏幕，图片内联显示

用户: 打开百度
→ 在内置浏览器中打开 baidu.com

用户: 帮我搜一下华为最新手机
→ 调用网页搜索，返回搜索结果摘要

用户: 明天下午3点提醒我开会
→ 创建日历提醒事件

用户: 发短信给 13800138000 说我晚点到
→ 发送短信

用户: 用语音说 "你好，世界"
→ TTS 朗读文字

用户: 我叫小明，我喜欢喝咖啡
→ 自动保存到记忆
```

### 智能功能

**记忆系统**
- 跨会话持久化：事实（fact）、偏好（preference）、指令（instruction）
- 对话中自动提取记忆，AI 主动保存用户信息
- 语义搜索匹配相关记忆
- Gateway 模式下双向同步

**上下文感知**
- 天气查询自动获取 GPS 位置
- 截屏/拍照结果自动内联显示，点击全屏预览
- 图片路径自动从文本中清除（不显示冗余路径）
- 对话历史浏览与管理（Markdown 格式保存）

**自动分发（单机模式）**
- 位置关键词 → 自动调用 `get_location`
- 截屏关键词 → 自动调用 `screen_capture`
- 天气关键词 → 自动附加 GPS 坐标
- 网页关键词 → 自动调用 `open_webpage`
- 邮件关键词 → 自动调用 `list_emails`

### 技术栈

| 组件 | 技术 |
|------|------|
| **平台** | HarmonyOS NEXT (API 12 ~ 22) |
| **语言** | ArkTS + C++ (NAPI) |
| **构建** | Hvigor |
| **UI** | ArkUI 声明式 |
| **ASR** | sherpa-onnx v1.12.24 + SenseVoice-Small INT8 |
| **TTS** | HarmonyOS CoreSpeechKit（在线 + 离线） |
| **WebSocket** | @kit.NetworkKit |
| **最低 SDK** | 5.0.0(12) |
| **目标 SDK** | 6.0.2(22) |

### 项目结构

```
entry/src/main/
├── ets/
│   ├── common/          # Constants, I18n, LogService
│   ├── components/      # MessageBubble, MarkdownText, SkillCard
│   ├── entryability/    # EntryAbility (应用入口)
│   ├── model/           # ChatMessage, MemoryItem 等数据模型
│   ├── pages/           # ChatPage, SettingsPage, SkillsPage, MemoryPage
│   ├── workers/         # SenseVoiceAsrWorker (离线 ASR)
│   └── service/
│       ├── AIService.ets       # LLM 调用 + Tool-use 循环
│       ├── MemoryService.ets   # 记忆持久化 + 语义搜索
│       └── gateway/            # 15 项 Capability 实现
│           ├── NodeRuntime.ets         # Gateway 双会话连接
│           ├── GatewaySession.ets      # WebSocket RPC
│           ├── CameraCapability.ets    # 拍照 + 录像
│           ├── ScreenCapability.ets    # 截屏 + 录屏
│           ├── SpeakerCapability.ets   # TTS + 音频播放
│           ├── MicrophoneCapability.ets # 麦克风录音
│           ├── CalendarCapability.ets  # 日历事件
│           ├── CanvasCapability.ets    # WebView + A2UI
│           ├── SmsCapability.ets       # 短信发送
│           ├── EmailCapability.ets     # 邮件发送
│           ├── LocationCapability.ets  # GPS 定位
│           ├── NotificationCapability.ets # 系统通知
│           └── ExecCapability.ets      # Shell 执行
├── resources/
│   └── rawfile/
│       └── a2ui/index.html    # A2UI 渲染引擎
└── cpp/
    └── napi_exec.cpp    # Shell 执行（popen）
```

### 构建与安装

```bash
# 需要安装 DevEco Studio
export DEVECO_SDK_HOME="/path/to/DevEco Studio/sdk"

# 构建
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon

# 安装到设备
hdc install entry/build/default/outputs/default/entry-default-signed.hap

# 启动应用
hdc shell aa start -a EntryAbility -b com.hongjieliu.clawdbot
```

### 已知问题

**本地 Embedding 模型暂时禁用**

项目包含本地 MiniLM-L6 embedding 模型（6层 Transformer），用于离线语义搜索。但由于 HarmonyOS 的 ANR（应用无响应）阈值为 3 秒，单层 Transformer 计算在主线程上就可能超时导致崩溃。

当前状态：`LocalEmbedding.isReady()` 返回 `false`，强制使用云端 API。

---

## English

### Introduction

ClawdBot is a full-featured personal AI assistant for HarmonyOS NEXT. It supports dual work modes (Standalone / Node), integrates 15 device capabilities, voice interaction, persistent memory, scheduled tasks, web browsing, A2UI dynamic forms, and more.

### Work Modes

| Mode | Description |
|------|-------------|
| **Standalone** | Direct LLM API calls (SiliconFlow, OpenAI, Anthropic, OpenRouter, Ollama), all tools executed locally |
| **Node** | WebSocket connection to [OpenClaw](https://github.com/openclaw/openclaw) Gateway server, dual-session architecture (operator + node), exponential backoff auto-reconnect |

### Core Features

#### 🤖 AI Capabilities

**Multi-Model Support**
- Providers: Anthropic (Claude), OpenAI, OpenRouter, SiliconFlow, local Ollama, and any OpenAI-compatible API
- Per-provider API key, model name, and base URL settings
- Tool-use loop (up to 8 rounds) for autonomous complex task execution
- Weak model auto-dispatch: automatically triggers correct tools when model fails to call them
- Soul personality system: customizable AI behavior and tone

**Voice Interaction**
- Press-and-hold to record, auto-transcribe and send
- ASR engine: sherpa-onnx + SenseVoice-Small INT8 (offline, supports Chinese/English/Japanese/Korean/Cantonese)
- TTS auto-read for AI responses (HarmonyOS CoreSpeechKit, online/offline dual engine)
- Talk Mode: continuous voice conversation with automatic silence detection
- Voice message bubble UI, WAV recording saved, tap to play

#### 📱 Device Capabilities (15)

| Capability | Commands | Description |
|------------|----------|-------------|
| **Location** | `location.get` | GPS positioning; auto-appended for weather queries |
| **Camera** | `camera.snap`, `camera.clip` | Front/back camera photo, video recording, auto-compression |
| **Screen** | `screen.capture`, `screen.record` | App window screenshot, screen recording |
| **Notification** | `notification.show`, `system.notify` | System push notifications |
| **TTS/Audio** | `speaker.speak`, `speaker.play`, `speaker.stop` | Text-to-speech, audio playback |
| **Microphone** | `mic.record` | Silent recording (background ambient audio capture, no user interaction) |
| **Voiceprint** | Built-in | Local speaker identification/verification (sherpa-onnx, offline) |
| **SMS** | `sms.send` | Send text messages |
| **Email** | `email.send` | Send emails (SMTP) |
| **Calendar** | `calendar.add` | Create calendar events, set reminders |
| **Canvas** | `canvas.present/hide/navigate/eval/snapshot` | WebView browser with JS execution, screenshots |
| **A2UI** | `canvas.a2ui.push/reset` | Dynamic form rendering with interaction events |
| **Exec** | `exec.run` | Shell command execution (NAPI C++ popen) |
| **File System** | Built-in | Sandbox file R/W, directory listing, content search |
| **Memory** | Built-in | Persistent memory storage and semantic search |
| **Scheduler** | Built-in | One-shot or recurring scheduled tasks |

#### 🎨 A2UI Dynamic Forms

Supports A2UI dynamic UI pushed from OpenClaw Gateway:

- **Components**: Text, Button, TextField, CheckBox, ChoicePicker, Slider, DateTimeInput, Image, Video, Audio, Column, Row, Card, List, Tabs, Modal, Divider
- **Interaction Events**: User interactions (button clicks, etc.) automatically send events to Gateway, triggering Agent responses
- **Inline Rendering**: Forms render directly in chat interface, no page navigation required
- **Simplified Format**: Auto-converts simplified JSON format from WhatsApp/Telegram

### Usage Examples

```
User: What's the weather today?
→ Auto-fetches GPS location, searches local weather and replies

User: Take a photo
→ Captures photo with rear camera, displays inline in chat

User: Record a 10-second video
→ Records video and returns

User: Take a screenshot
→ Captures current app screen, displays inline

User: Open Google
→ Opens google.com in built-in browser

User: Remind me about the meeting tomorrow at 3pm
→ Creates a calendar reminder event

User: Send a text to 13800138000 saying I'll be late
→ Sends SMS message

User: Say "Hello, world" out loud
→ TTS reads the text

User: My name is Alex, I like coffee
→ Auto-saves to memory
```

### Tech Stack

| Component | Technology |
|-----------|------------|
| **Platform** | HarmonyOS NEXT (API 12 ~ 22) |
| **Language** | ArkTS + C++ (NAPI) |
| **Build** | Hvigor |
| **UI** | ArkUI declarative |
| **ASR** | sherpa-onnx v1.12.24 + SenseVoice-Small INT8 |
| **TTS** | HarmonyOS CoreSpeechKit (online + offline) |
| **WebSocket** | @kit.NetworkKit |
| **Min SDK** | 5.0.0(12) |
| **Target SDK** | 6.0.2(22) |

### Build & Install

```bash
# Requires DevEco Studio
export DEVECO_SDK_HOME="/path/to/DevEco Studio/sdk"

# Build
hvigorw assembleHap --mode module -p product=default -p buildMode=release --no-daemon

# Install to device
hdc install entry/build/default/outputs/default/entry-default-signed.hap

# Launch app
hdc shell aa start -a EntryAbility -b com.hongjieliu.clawdbot
```

---

## Changelog

### v2.21.7 (2026-02-17)
- ✨ A2UI action events now sent back to Gateway
- ✨ A2UI simplified format auto-conversion
- 🐛 Fixed new session name to use standalone config
- 🐛 Added onConsole handler to CanvasView

### v2.21.0 ~ v2.21.6
- ✨ A2UI dynamic form rendering
- ✨ Speaker capability (TTS + audio playback)
- ✨ SMS sending capability
- ✨ Screen recording capability
- ✨ Microphone recording capability
- 🐛 Various bug fixes

---

## License

Apache-2.0

## Links

- **OpenClaw Gateway**: https://github.com/openclaw/openclaw
- **Issues**: https://github.com/lhj1026/ClawdbotHarmony/issues
