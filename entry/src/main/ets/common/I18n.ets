/**
 * Internationalization (i18n) support.
 * Provides Chinese and English translations for all UI strings.
 * Uses Map<string, string> for ArkTS compatibility (no indexed signatures).
 */

export type LangCode = 'zh' | 'en';

function buildZh(): Map<string, string> {
  let m = new Map<string, string>();
  // Tab bar
  m.set('tab.chat', '聊天');
  m.set('tab.skills', '技能');
  m.set('tab.memory', '记忆');
  m.set('tab.settings', '设置');

  // ChatPage
  m.set('chat.title', 'ClawdBot');
  m.set('chat.thinking', '思考中...');
  m.set('chat.online', '在线');
  m.set('chat.gatewayMode', '网关模式');
  m.set('chat.placeholder', '向 ClawdBot 提问...');
  m.set('chat.empty.subtitle', '你的私人AI助手。\n随时提问或分配任务。');
  m.set('chat.quick.whatCanYouDo', '你能做什么？');
  m.set('chat.quick.setReminder', '设置提醒');
  m.set('chat.quick.searchWeb', '搜索网页');
  m.set('chat.quick.smartHome', '智能家居状态');
  m.set('chat.toolResult', '结果');
  m.set('chat.notificationReceived', '收到网关通知');
  m.set('chat.notificationFrom', '来自');
  m.set('chat.approval.title', '工具审批请求');
  m.set('chat.approval.command', '命令');
  m.set('chat.approval.host', '主机');
  m.set('chat.approval.agent', 'Agent');
  m.set('chat.approval.allowOnce', '允许一次');
  m.set('chat.approval.allowAlways', '始终允许');
  m.set('chat.approval.deny', '拒绝');
  m.set('chat.approval.approved', '已批准');
  m.set('chat.approval.denied', '已拒绝');
  m.set('chat.approval.expired', '已过期');
  m.set('chat.playingAudio', '正在播放音频...');
  m.set('chat.audioPlayed', '音频已播放');
  m.set('chat.audioFailed', '音频播放失败');
  m.set('chat.audioReady', '点击播放录音');
  m.set('chat.audioPlaying', '正在播放...');
  m.set('chat.recording', '正在录音...');
  m.set('chat.voiceMessage', '语音消息');
  m.set('chat.voiceNoText', '[语音消息]');
  m.set('chat.speechError', '语音识别失败');
  m.set('chat.rateLimited', '免费模型已达到速率限制，请稍后重试。\n\n如需更稳定的服务，请注册自己的 API Key：\n\n📝 OpenRouter 注册步骤：\n1. 打开 openrouter.ai 并点击注册\n2. 使用 Google 账号或邮箱注册\n3. 注册后进入 openrouter.ai/settings/keys\n4. 点击 "Create Key" 创建一个新密钥\n5. 复制密钥，回到本 App 的设置页\n6. 在 "AI 提供商" 选择 OpenRouter\n7. 将密钥粘贴到 "API Key" 输入框\n\n💡 OpenRouter 提供免费和付费模型，注册后免费额度更高，也可按需充值使用 GPT-4o、Claude 等高级模型。');
  m.set('chat.ttsReading', '🔊 正在朗读...');
  m.set('chat.ttsReadDone', '🔊 已朗读');
  m.set('chat.ttsReadFailed', '朗读失败');
  m.set('chat.conversationSaved', '对话已保存');
  m.set('chat.memoryUpdated', '记忆已更新');
  m.set('chat.history', '对话历史');
  m.set('chat.historyEmpty', '暂无历史对话');
  m.set('chat.back', '返回');
  m.set('chat.deleteConfirm', '确定删除这条对话记录？');
  m.set('chat.deleted', '已删除');
  m.set('chat.extractMemory', '提取记忆');
  m.set('chat.extracting', '正在分析对话...');
  m.set('chat.memoryExtracted', '提取了 {0} 条新记忆');
  m.set('chat.noNewMemory', '未发现新记忆');
  m.set('chat.extractFailed', '提取失败');
  m.set('chat.exported', '已复制到剪贴板');
  m.set('chat.compressing', '正在压缩对话...');
  m.set('chat.compressed', '对话已压缩');
  m.set('chat.compressFailed', '压缩失败');
  m.set('chat.deleteHistoryConfirm', '确定删除这条历史对话？');
  m.set('chat.historyDeleted', '已删除');

  // Attachment & media
  m.set('chat.attachTitle', '添加附件');
  m.set('chat.attachPhoto', '选择图片');
  m.set('chat.attachFile', '选择文件');
  m.set('chat.sentImage', '[图片]');
  m.set('chat.describeImage', '请描述这张图片');
  m.set('chat.fileTooLarge', '文件过大（最大512KB）');

  // Custom provider & ASR
  m.set('settings.customProvider', '定制化');
  m.set('settings.asrEnabled', '云端 ASR');
  m.set('settings.asrEnabledDesc', '使用云端语音识别服务（如不启用则使用本地离线识别）');

  // SettingsPage - TTS auto-read
  m.set('settings.ttsAutoRead', '语音朗读');
  m.set('settings.ttsAutoReadDesc', '自动朗读 AI 回复（使用本地 TTS）');

  // SkillsPage
  m.set('skills.title', '技能');
  m.set('skills.subtitle', '开启内置技能以扩展 ClawdBot 的能力。');
  m.set('skills.all', '全部');
  m.set('skills.automation', '自动化');
  m.set('skills.productivity', '效率');
  m.set('skills.smartHome', '智能家居');
  m.set('skills.media', '媒体');
  m.set('skills.countSkills', '项技能');
  m.set('skills.countEnabled', '已启用');
  m.set('skills.countTools', '个工具');
  m.set('skills.builtin', '内置');

  // MemoryPage
  m.set('memory.title', '记忆');
  m.set('memory.subtitle', 'ClawdBot 可以跨会话记住事实、偏好和指令。');
  m.set('memory.add', '+ 添加');
  m.set('memory.save', '保存');
  m.set('memory.all', '全部');
  m.set('memory.fact', '事实');
  m.set('memory.preference', '偏好');
  m.set('memory.instruction', '指令');
  m.set('memory.entries', '条记录');
  m.set('memory.empty', '暂无记忆');
  m.set('memory.placeholder', 'ClawdBot 需要记住什么？');
  m.set('memory.clearTitle', '清除所有记忆');
  m.set('memory.clearMessage', '确定要永久删除所有存储的记忆吗？');
  m.set('memory.cancel', '取消');
  m.set('memory.clear', '清除');

  // SettingsPage - Soul
  m.set('settings.soul', '人格 / Soul');
  m.set('settings.soulDesc', '定义 AI 助手的行为风格和人格特征，注入 system prompt');
  m.set('settings.soulReset', '恢复默认');
  m.set('settings.soulResetDone', '已恢复默认人格');

  // SettingsPage
  m.set('settings.title', '设置');
  m.set('settings.aiProvider', 'AI 服务提供商');
  m.set('settings.provider', '提供商');
  m.set('settings.apiKey', 'API 密钥');
  m.set('settings.apiKeyPlaceholder', '输入你的 API 密钥');
  m.set('settings.apiKeyNotRequired', '无需填写');
  m.set('settings.show', '显示');
  m.set('settings.hide', '隐藏');
  m.set('settings.model', '模型');
  m.set('settings.modelPlaceholder', '模型名称');
  m.set('settings.baseUrl', '基础 URL');
  m.set('settings.baseUrlDesc', '留空使用官方 API，填写可用于代理/中转服务');
  m.set('settings.generation', '生成参数');
  m.set('settings.temperature', '温度');
  m.set('settings.gateway', '网关 / 节点模式');
  m.set('settings.nodeMode', '节点模式');
  m.set('settings.nodeModeDesc', '连接到 OpenClaw 网关');
  m.set('settings.gatewayHost', '网关主机');
  m.set('settings.gatewayHostPlaceholder', '192.168.1.100 或主机名');
  m.set('settings.port', '端口');
  m.set('settings.useTls', '使用 TLS (wss://)');
  m.set('settings.token', '令牌');
  m.set('settings.tokenDesc', 'OpenClaw 网关的共享令牌');
  m.set('settings.tokenPlaceholder', '例如 d71a61ab...');
  m.set('settings.password', '密码（可选）');
  m.set('settings.passwordPlaceholder', '网关密码');
  m.set('settings.status', '状态');
  m.set('settings.connect', '连接');
  m.set('settings.disconnect', '断开');
  m.set('settings.caps', '本机能力');
  m.set('settings.capLocation', '定位 (GPS)');
  m.set('settings.capCamera', '相机 (拍照/录像)');
  m.set('settings.capCanvas', '画布 (WebView)');
  m.set('settings.capScreen', '截屏/录屏');
  m.set('settings.capNotification', '通知');
  m.set('settings.capMicrophone', '麦克风 (录音)');
  m.set('settings.capSpeaker', '音箱 (朗读/播放)');
  m.set('settings.capEmail', '邮件 (发送)');
  m.set('settings.about', '关于');
  m.set('settings.app', '应用');
  m.set('settings.appValue', 'ClawdBot for HarmonyOS');
  m.set('settings.version', '版本');
  m.set('settings.basedOn', '基于');
  m.set('settings.platform', '平台');
  m.set('settings.save', '保存设置');
  m.set('settings.saved', '设置已保存');
  m.set('settings.saveFailed', '保存失败：');
  m.set('settings.enterHost', '请输入网关主机');
  m.set('settings.language', '语言');
  m.set('settings.languageDesc', '界面显示语言');
  m.set('settings.langZh', '中文');
  m.set('settings.langEn', 'English');

  // Settings - Assistant
  m.set('settings.assistant', 'AI 助手');
  m.set('settings.assistantName', '助手名字');
  m.set('settings.assistantNamePlaceholder', '输入助手名字');
  m.set('settings.assistantAvatar', '头像');
  m.set('settings.assistantAvatarChange', '点击更换头像');

  // LogPage
  m.set('tab.logs', '日志');
  m.set('log.title', '运行日志');
  m.set('log.clear', '清除');
  m.set('log.entries', '条');
  m.set('log.empty', '暂无日志');
  m.set('log.copy', '复制');
  m.set('log.export', '导出');
  m.set('log.copied', '已复制到剪贴板');
  m.set('log.exported', '已导出到文件');
  m.set('log.exportFail', '导出失败');
  m.set('log.recording', '记录中');
  m.set('log.readMore', '展开');
  m.set('log.showLess', '收起');
  m.set('log.filePath', '文件路径');

  m.set('settings.gatewayAddress', '网关地址');

  // Cron
  m.set('cron.executing', '正在执行定时任务...');
  m.set('cron.created', '定时任务已创建');
  m.set('cron.cancelled', '定时任务已取消');
  m.set('cron.notFound', '未找到该定时任务');
  m.set('cron.noTasks', '暂无定时任务');

  // Talk Mode
  m.set('chat.talkMode', '对话模式');
  m.set('chat.talkModeOn', '对话模式已开启');
  m.set('chat.talkModeOff', '对话模式已关闭');
  m.set('chat.talkListening', '正在聆听...');
  m.set('chat.talkThinking', '正在思考...');
  m.set('chat.talkSpeaking', '正在说话...');
  m.set('chat.talkSilence', '静默超时，对话模式已关闭');

  // Custom Skills
  m.set('skills.custom', '自定义');
  m.set('skills.customSkill', '自定义技能');
  m.set('skills.created', '技能已创建');
  m.set('skills.updated', '技能已更新');
  m.set('skills.deleted', '技能已删除');

  // Email / IMAP
  m.set('settings.email', '邮箱 / IMAP & SMTP');
  m.set('settings.emailEnabled', '启用邮箱');
  m.set('settings.emailEnabledDesc', '通过 IMAP 读取邮件，SMTP 发送邮件');
  m.set('settings.imapHost', 'IMAP 服务器');
  m.set('settings.imapPort', '端口');
  m.set('settings.imapUser', '邮箱地址');
  m.set('settings.imapPass', '密码 / 应用专用密码');
  m.set('settings.smtpHost', 'SMTP 服务器');
  m.set('settings.smtpPort', '端口');
  m.set('settings.emailTest', '测试连接');
  m.set('settings.emailTesting', '连接中...');
  m.set('settings.emailTestOk', '连接成功');
  m.set('settings.emailTestFail', '连接失败：');

  // Settings tabs
  m.set('settings.tabStandalone', '单机模式');
  m.set('settings.tabNode', '节点模式');
  m.set('settings.tabService', '服务模式');
  m.set('settings.tabModel', '模型');

  // Profiles
  m.set('settings.profiles', '配置方案');
  m.set('settings.profileSave', '保存当前配置');
  m.set('settings.profileLoad', '加载');
  m.set('settings.profileDelete', '删除');
  m.set('settings.profileName', '配置名称');
  m.set('settings.profileNamePlaceholder', '输入配置名称...');
  m.set('settings.profileSaved', '配置已保存');
  m.set('settings.profileLoaded', '配置已加载');
  m.set('settings.profileDeleted', '配置已删除');
  m.set('settings.profileEmpty', '暂无保存的配置');

  // Feishu Bot
  m.set('settings.feishu', '飞书机器人');
  m.set('settings.feishuEnabled', '启用飞书机器人');
  m.set('settings.feishuEnabledDesc', '通过WebSocket接收飞书消息并自动回复');
  m.set('settings.feishuAppId', 'App ID');
  m.set('settings.feishuAppSecret', 'App Secret');
  m.set('settings.feishuTest', '测试连接');
  m.set('settings.feishuTesting', '正在连接...');
  m.set('settings.feishuTestOk', '连接成功');
  m.set('settings.feishuTestFail', '连接失败：');
  m.set('chat.feishuMessage', '飞书消息');
  m.set('chat.feishuReply', '飞书回复');

  // Connection states
  m.set('state.offline', '离线');
  m.set('state.connecting', '连接中...');
  m.set('state.connected', '已连接');
  m.set('state.reconnecting', '重连中...');
  m.set('state.error', '错误');

  return m;
}

function buildEn(): Map<string, string> {
  let m = new Map<string, string>();
  // Tab bar
  m.set('tab.chat', 'Chat');
  m.set('tab.skills', 'Skills');
  m.set('tab.memory', 'Memory');
  m.set('tab.settings', 'Settings');

  // ChatPage
  m.set('chat.title', 'ClawdBot');
  m.set('chat.thinking', 'Thinking...');
  m.set('chat.online', 'Online');
  m.set('chat.gatewayMode', 'Gateway Mode');
  m.set('chat.placeholder', 'Ask ClawdBot anything...');
  m.set('chat.empty.subtitle', 'Your personal AI assistant.\nAsk me anything or give me a task.');
  m.set('chat.quick.whatCanYouDo', 'What can you do?');
  m.set('chat.quick.setReminder', 'Set a reminder');
  m.set('chat.quick.searchWeb', 'Search the web');
  m.set('chat.quick.smartHome', 'Smart home status');
  m.set('chat.toolResult', 'result');
  m.set('chat.notificationReceived', 'Gateway Notification');
  m.set('chat.notificationFrom', 'From');
  m.set('chat.approval.title', 'Tool Approval Required');
  m.set('chat.approval.command', 'Command');
  m.set('chat.approval.host', 'Host');
  m.set('chat.approval.agent', 'Agent');
  m.set('chat.approval.allowOnce', 'Allow once');
  m.set('chat.approval.allowAlways', 'Always allow');
  m.set('chat.approval.deny', 'Deny');
  m.set('chat.approval.approved', 'Approved');
  m.set('chat.approval.denied', 'Denied');
  m.set('chat.approval.expired', 'Expired');
  m.set('chat.playingAudio', 'Playing audio...');
  m.set('chat.audioPlayed', 'Audio played');
  m.set('chat.audioFailed', 'Audio playback failed');
  m.set('chat.audioReady', 'Tap to play recording');
  m.set('chat.audioPlaying', 'Playing...');
  m.set('chat.recording', 'Recording...');
  m.set('chat.voiceMessage', 'Voice message');
  m.set('chat.voiceNoText', '[Voice message]');
  m.set('chat.speechError', 'Speech recognition failed');
  m.set('chat.rateLimited', 'Free model rate limited. Please retry shortly.\n\nFor stable service, register your own API Key:\n\n📝 OpenRouter Registration:\n1. Go to openrouter.ai and sign up\n2. Register with Google or email\n3. After sign-up, go to openrouter.ai/settings/keys\n4. Click "Create Key" to generate a new key\n5. Copy the key, then open Settings in this app\n6. Select "OpenRouter" as AI Provider\n7. Paste the key into the "API Key" field\n\n💡 OpenRouter offers free and paid models. After registration you get higher free limits, and can top up to use premium models like GPT-4o, Claude, etc.');
  m.set('chat.ttsReading', '🔊 Reading aloud...');
  m.set('chat.ttsReadDone', '🔊 Read aloud');
  m.set('chat.ttsReadFailed', 'TTS read failed');
  m.set('chat.conversationSaved', 'Conversation saved');
  m.set('chat.memoryUpdated', 'Memory updated');
  m.set('chat.history', 'Chat History');
  m.set('chat.historyEmpty', 'No saved conversations');
  m.set('chat.back', 'Back');
  m.set('chat.deleteConfirm', 'Delete this conversation?');
  m.set('chat.deleted', 'Deleted');
  m.set('chat.extractMemory', 'Extract Memory');
  m.set('chat.extracting', 'Analyzing conversation...');
  m.set('chat.memoryExtracted', 'Extracted {0} new memories');
  m.set('chat.noNewMemory', 'No new memories found');
  m.set('chat.extractFailed', 'Extract failed');
  m.set('chat.exported', 'Copied to clipboard');
  m.set('chat.compressing', 'Compressing conversation...');
  m.set('chat.compressed', 'Conversation compressed');
  m.set('chat.compressFailed', 'Compress failed');
  m.set('chat.deleteHistoryConfirm', 'Delete this conversation?');
  m.set('chat.historyDeleted', 'Deleted');

  // Attachment & media
  m.set('chat.attachTitle', 'Add Attachment');
  m.set('chat.attachPhoto', 'Choose Photo');
  m.set('chat.attachFile', 'Choose File');
  m.set('chat.sentImage', '[Image]');
  m.set('chat.describeImage', 'Please describe this image');
  m.set('chat.fileTooLarge', 'File too large (max 512KB)');

  // Custom provider & ASR
  m.set('settings.customProvider', 'Custom');
  m.set('settings.asrEnabled', 'Cloud ASR');
  m.set('settings.asrEnabledDesc', 'Use cloud speech recognition (disable for local offline ASR)');

  // SettingsPage - TTS auto-read
  m.set('settings.ttsAutoRead', 'Auto Read Aloud');
  m.set('settings.ttsAutoReadDesc', 'Auto read AI responses aloud (local TTS)');

  // SkillsPage
  m.set('skills.title', 'Skills');
  m.set('skills.subtitle', "Toggle built-in skills to expand ClawdBot's capabilities.");
  m.set('skills.all', 'All');
  m.set('skills.automation', 'Automation');
  m.set('skills.productivity', 'Productivity');
  m.set('skills.smartHome', 'Smart Home');
  m.set('skills.media', 'Media');
  m.set('skills.countSkills', ' skills');
  m.set('skills.countEnabled', ' enabled');
  m.set('skills.countTools', ' tools');
  m.set('skills.builtin', 'Built-in');

  // MemoryPage
  m.set('memory.title', 'Memory');
  m.set('memory.subtitle', 'ClawdBot remembers facts, preferences, and instructions across sessions.');
  m.set('memory.add', '+ Add');
  m.set('memory.save', 'Save');
  m.set('memory.all', 'All');
  m.set('memory.fact', 'fact');
  m.set('memory.preference', 'preference');
  m.set('memory.instruction', 'instruction');
  m.set('memory.entries', ' entries');
  m.set('memory.empty', 'No memories yet');
  m.set('memory.placeholder', 'What should ClawdBot remember?');
  m.set('memory.clearTitle', 'Clear All Memory');
  m.set('memory.clearMessage', 'Permanently delete all stored memories?');
  m.set('memory.cancel', 'Cancel');
  m.set('memory.clear', 'Clear');

  // SettingsPage - Soul
  m.set('settings.soul', 'SOUL / PERSONALITY');
  m.set('settings.soulDesc', 'Define AI behavior style and personality, injected into system prompt');
  m.set('settings.soulReset', 'Reset to Default');
  m.set('settings.soulResetDone', 'Soul reset to default');

  // SettingsPage
  m.set('settings.title', 'Settings');
  m.set('settings.aiProvider', 'AI PROVIDER');
  m.set('settings.provider', 'Provider');
  m.set('settings.apiKey', 'API Key');
  m.set('settings.apiKeyPlaceholder', 'Enter your API key');
  m.set('settings.apiKeyNotRequired', 'Not required');
  m.set('settings.show', 'Show');
  m.set('settings.hide', 'Hide');
  m.set('settings.model', 'Model');
  m.set('settings.modelPlaceholder', 'Model name');
  m.set('settings.baseUrl', 'Base URL');
  m.set('settings.baseUrlDesc', 'Leave empty for official API, or enter proxy/relay URL');
  m.set('settings.generation', 'GENERATION');
  m.set('settings.temperature', 'Temperature');
  m.set('settings.gateway', 'GATEWAY / NODE MODE');
  m.set('settings.nodeMode', 'Node Mode');
  m.set('settings.nodeModeDesc', 'Connect to OpenClaw Gateway');
  m.set('settings.gatewayHost', 'Gateway Host');
  m.set('settings.gatewayHostPlaceholder', '192.168.1.100 or hostname');
  m.set('settings.port', 'Port');
  m.set('settings.useTls', 'Use TLS (wss://)');
  m.set('settings.token', 'Token');
  m.set('settings.tokenDesc', 'Shared token from your OpenClaw Gateway');
  m.set('settings.tokenPlaceholder', 'e.g. d71a61ab...');
  m.set('settings.password', 'Password (optional)');
  m.set('settings.passwordPlaceholder', 'Gateway password');
  m.set('settings.status', 'Status');
  m.set('settings.connect', 'Connect');
  m.set('settings.disconnect', 'Disconnect');
  m.set('settings.caps', 'Node Capabilities');
  m.set('settings.capLocation', 'Location (GPS)');
  m.set('settings.capCamera', 'Camera (Photo/Video)');
  m.set('settings.capCanvas', 'Canvas (WebView)');
  m.set('settings.capScreen', 'Screenshot/Recording');
  m.set('settings.capNotification', 'Notifications');
  m.set('settings.capMicrophone', 'Microphone (Record)');
  m.set('settings.capSpeaker', 'Speaker (TTS/Playback)');
  m.set('settings.capEmail', 'Email (Send)');
  m.set('settings.about', 'ABOUT');
  m.set('settings.app', 'App');
  m.set('settings.appValue', 'ClawdBot for HarmonyOS');
  m.set('settings.version', 'Version');
  m.set('settings.basedOn', 'Based on');
  m.set('settings.platform', 'Platform');
  m.set('settings.save', 'Save Settings');
  m.set('settings.saved', 'Settings saved');
  m.set('settings.saveFailed', 'Save failed: ');
  m.set('settings.enterHost', 'Please enter gateway host');
  m.set('settings.language', 'Language');
  m.set('settings.languageDesc', 'Interface display language');
  m.set('settings.langZh', '中文');
  m.set('settings.langEn', 'English');

  // Settings - Assistant
  m.set('settings.assistant', 'AI ASSISTANT');
  m.set('settings.assistantName', 'Assistant Name');
  m.set('settings.assistantNamePlaceholder', 'Enter assistant name');
  m.set('settings.assistantAvatar', 'Avatar');
  m.set('settings.assistantAvatarChange', 'Tap to change avatar');

  // LogPage
  m.set('tab.logs', 'Logs');
  m.set('log.title', 'Runtime Logs');
  m.set('log.clear', 'Clear');
  m.set('log.entries', 'entries');
  m.set('log.empty', 'No logs yet');
  m.set('log.copy', 'Copy');
  m.set('log.export', 'Export');
  m.set('log.copied', 'Copied to clipboard');
  m.set('log.exported', 'Exported to file');
  m.set('log.exportFail', 'Export failed');
  m.set('log.recording', 'Recording');
  m.set('log.readMore', 'Read more');
  m.set('log.showLess', 'Show less');
  m.set('log.filePath', 'File path');

  m.set('settings.gatewayAddress', 'Gateway Address');

  // Cron
  m.set('cron.executing', 'Executing scheduled task...');
  m.set('cron.created', 'Scheduled task created');
  m.set('cron.cancelled', 'Scheduled task cancelled');
  m.set('cron.notFound', 'Scheduled task not found');
  m.set('cron.noTasks', 'No scheduled tasks');

  // Talk Mode
  m.set('chat.talkMode', 'Talk Mode');
  m.set('chat.talkModeOn', 'Talk mode activated');
  m.set('chat.talkModeOff', 'Talk mode deactivated');
  m.set('chat.talkListening', 'Listening...');
  m.set('chat.talkThinking', 'Thinking...');
  m.set('chat.talkSpeaking', 'Speaking...');
  m.set('chat.talkSilence', 'Silence timeout, talk mode ended');

  // Custom Skills
  m.set('skills.custom', 'Custom');
  m.set('skills.customSkill', 'Custom Skill');
  m.set('skills.created', 'Skill created');
  m.set('skills.updated', 'Skill updated');
  m.set('skills.deleted', 'Skill deleted');

  // Email / IMAP
  m.set('settings.email', 'EMAIL / IMAP & SMTP');
  m.set('settings.emailEnabled', 'Enable Email');
  m.set('settings.emailEnabledDesc', 'Read emails via IMAP, send via SMTP');
  m.set('settings.imapHost', 'IMAP Server');
  m.set('settings.imapPort', 'Port');
  m.set('settings.imapUser', 'Email Address');
  m.set('settings.imapPass', 'Password / App Password');
  m.set('settings.smtpHost', 'SMTP Server');
  m.set('settings.smtpPort', 'Port');
  m.set('settings.emailTest', 'Test Connection');
  m.set('settings.emailTesting', 'Connecting...');
  m.set('settings.emailTestOk', 'Connection successful');
  m.set('settings.emailTestFail', 'Connection failed: ');

  // Settings tabs
  m.set('settings.tabStandalone', 'Standalone');
  m.set('settings.tabNode', 'Node Mode');
  m.set('settings.tabService', 'Service Mode');
  m.set('settings.tabModel', 'Model');

  // Profiles
  m.set('settings.profiles', 'Profiles');
  m.set('settings.profileSave', 'Save Current Config');
  m.set('settings.profileLoad', 'Load');
  m.set('settings.profileDelete', 'Delete');
  m.set('settings.profileName', 'Profile Name');
  m.set('settings.profileNamePlaceholder', 'Enter profile name...');
  m.set('settings.profileSaved', 'Profile saved');
  m.set('settings.profileLoaded', 'Profile loaded');
  m.set('settings.profileDeleted', 'Profile deleted');
  m.set('settings.profileEmpty', 'No saved profiles');

  // Feishu Bot
  m.set('settings.feishu', 'FEISHU BOT');
  m.set('settings.feishuEnabled', 'Enable Feishu Bot');
  m.set('settings.feishuEnabledDesc', 'Receive Feishu messages via WebSocket and auto-reply');
  m.set('settings.feishuAppId', 'App ID');
  m.set('settings.feishuAppSecret', 'App Secret');
  m.set('settings.feishuTest', 'Test Connection');
  m.set('settings.feishuTesting', 'Connecting...');
  m.set('settings.feishuTestOk', 'Connected');
  m.set('settings.feishuTestFail', 'Connection failed: ');
  m.set('chat.feishuMessage', 'Feishu Message');
  m.set('chat.feishuReply', 'Feishu Reply');

  // Connection states
  m.set('state.offline', 'Offline');
  m.set('state.connecting', 'Connecting…');
  m.set('state.connected', 'Connected');
  m.set('state.reconnecting', 'Reconnecting…');
  m.set('state.error', 'Error');

  return m;
}

const zhMap: Map<string, string> = buildZh();
const enMap: Map<string, string> = buildEn();

/**
 * Global language state singleton.
 * Pages observe lang changes via listener pattern.
 */
export class I18n {
  private static currentLang: LangCode = 'zh';
  private static listeners: Array<() => void> = [];

  static init(lang: LangCode): void {
    I18n.currentLang = lang;
  }

  static get lang(): LangCode {
    return I18n.currentLang;
  }

  static setLang(lang: LangCode): void {
    I18n.currentLang = lang;
    for (let listener of I18n.listeners) {
      try { listener(); } catch { /* ignore */ }
    }
  }

  static addListener(fn: () => void): void {
    I18n.listeners.push(fn);
  }

  static removeListener(fn: () => void): void {
    let idx = I18n.listeners.indexOf(fn);
    if (idx >= 0) {
      I18n.listeners.splice(idx, 1);
    }
  }

  /** Get translated string by key. */
  static t(key: string): string {
    let map: Map<string, string> = I18n.currentLang === 'zh' ? zhMap : enMap;
    let val = map.get(key);
    if (val !== undefined) {
      return val;
    }
    // Fallback to English
    let enVal = enMap.get(key);
    if (enVal !== undefined) {
      return enVal;
    }
    return key;
  }
}

/** Shorthand function for I18n.t() */
export function t(key: string): string {
  return I18n.t(key);
}
