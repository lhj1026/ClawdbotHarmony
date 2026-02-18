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
  m.set('chat.sharedContent', '收到分享内容');
  m.set('chat.sharedImage', '收到分享图片');
  m.set('chat.playingAudio', '正在播放音频...');
  m.set('chat.audioPlayed', '音频已播放');
  m.set('chat.audioFailed', '音频播放失败');
  m.set('chat.audioReady', '点击播放录音');
  m.set('chat.audioPlaying', '正在播放...');
  m.set('chat.recording', '正在录音...');
  m.set('chat.voiceMessage', '语音消息');
  m.set('chat.copy', '复制');
  m.set('chat.reply', '引用回复');
  m.set('chat.newSession', '新建会话');
  m.set('chat.you', '你');
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
  m.set('settings.aiEngine', 'AI 引擎');
  m.set('settings.aiEngineDesc', '语音识别、向量嵌入、意图识别');
  m.set('settings.aiEngineGatewayHint', '已接入网关，默认使用网关模型');
  m.set('settings.aiEngineInheritHint', '使用上方 AI 提供商的 API Key');
  m.set('settings.asrModel', '语音识别模型');
  m.set('settings.asrModelPlaceholder', '留空使用网关模型');
  m.set('settings.asrModelHint', '留空=使用网关大模型，填写=使用指定 ASR 模型');
  m.set('settings.asrMode', '语音识别');
  m.set('settings.asrModeDesc', '选择语音识别方式');
  m.set('settings.asrModeAuto', '自动');
  m.set('settings.asrModeLocal', '仅本地');
  m.set('settings.asrModeCloud', '仅云端');
  m.set('settings.asrModeAutoDesc', '优先云端识别，无API时使用本地');
  m.set('settings.asrModeLocalDesc', '使用本地离线识别（仅中文）');
  m.set('settings.asrModeCloudDesc', '使用云端语音识别服务');
  m.set('settings.embeddingMode', '语义嵌入');
  m.set('settings.embeddingModeDesc', '记忆搜索使用的嵌入方式');
  m.set('settings.embeddingModeAuto', '自动');
  m.set('settings.embeddingModeLocal', '仅本地');
  m.set('settings.embeddingModeCloud', '仅云端');
  m.set('settings.embeddingModeAutoDesc', '优先本地 MiniLM 模型，失败时使用云端');
  m.set('settings.embeddingModeLocalDesc', '使用本地 MiniLM 模型（无需网络）');
  m.set('settings.embeddingModeCloudDesc', '使用 SiliconFlow bge-m3 云端嵌入');
  m.set('settings.intentMode', '意图识别');
  m.set('settings.intentModeDesc', '用户意图的识别方式');
  m.set('settings.intentModeAuto', '自动');
  m.set('settings.intentModeLocal', '仅本地');
  m.set('settings.intentModeCloud', '仅云端');
  m.set('settings.intentModeAutoDesc', '本地关键词匹配 + LLM 工具调用');
  m.set('settings.intentModeLocalDesc', '仅使用本地关键词匹配（快速，离线）');
  m.set('settings.intentModeCloudDesc', '完全依赖 LLM 识别意图并调用工具');

  // SettingsPage - Unread message notification
  m.set('settings.unreadNotification', '未读消息通知');
  m.set('settings.unreadNotificationDesc', '当应用在后台时，新消息将显示在状态栏');

  // SettingsPage - TTS auto-read
  m.set('settings.ttsAutoRead', '语音朗读');
  m.set('settings.ttsAutoReadDesc', '自动朗读 AI 回复（使用本地 TTS）');

  // SettingsPage - Auto memory inject
  m.set('settings.autoMemoryInject', '智能记忆注入');
  m.set('settings.autoMemoryInjectDesc', '发消息时自动匹配相关记忆注入上下文');

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

  // ExperiencePage
  m.set('experience.title', '经验');
  m.set('experience.tabExperience', '经验包');
  m.set('experience.tabSkills', '技能');
  m.set('experience.tabMemory', '记忆');
  m.set('experience.countExp', '条经验');
  m.set('experience.countSkill', '个技能');
  m.set('experience.countMemory', '条记忆');
  m.set('experience.lastSync', '上次同步');
  m.set('experience.levelPublic', '公开');
  m.set('experience.levelSummary', '摘要');
  m.set('experience.levelPrivate', '私密');
  m.set('experience.empty', '暂无经验');
  m.set('experience.emptyHint', '经验会在与 AI 交互过程中自动学习');
  m.set('experience.skills', '技能');
  m.set('experience.memories', '记忆');
  m.set('experience.noSkills', '暂无技能');
  m.set('experience.noMemory', '暂无记忆');
  m.set('experience.createdAt', '创建时间');
  m.set('experience.updatedAt', '更新时间');

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
  m.set('memory.searchPlaceholder', '搜索记忆...');
  m.set('memory.placeholder', 'ClawdBot 需要记住什么？');
  m.set('memory.clearTitle', '清除所有记忆');
  m.set('memory.clearMessage', '确定要永久删除所有存储的记忆吗？');
  m.set('memory.cancel', '取消');
  m.set('memory.clear', '清除');
  m.set('memory.extractFromChat', '从对话提取');
  m.set('memory.extracting', '正在分析...');
  m.set('memory.syncFromServer', '从服务器同步');
  m.set('memory.syncing', '正在同步...');
  m.set('memory.syncDone', '同步完成，新增 {0} 条');
  m.set('memory.syncFailed', '同步失败');
  m.set('memory.noMessages', '当前对话为空');
  m.set('memory.tabMemory', '记忆');
  m.set('memory.tabHistory', '对话历史');
  m.set('memory.noSessions', '暂无对话记录');
  m.set('memory.messages', '条消息');
  m.set('memory.backToList', '返回列表');

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
  m.set('settings.gateway', '网关 / 节点接入');
  m.set('settings.gatewayConnect', '接入网关');
  m.set('settings.gatewayConnectDesc', '连接到 OpenClaw 网关进行 AI 对话');
  m.set('settings.nodeMode', '节点接入');
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
  m.set('settings.connected', '已连接');
  m.set('settings.connecting', '连接中...');
  m.set('settings.disconnected', '未连接');
  m.set('settings.reconnecting', '重连中...');
  m.set('settings.connectionError', '连接错误');
  m.set('settings.pairingPending', '等待批准配对');
  m.set('settings.parallelSessions', '并行会话数');
  m.set('settings.parallelSessionsDesc', '⚠️ 增大此值会加快 Token 消耗速度');
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
  m.set('settings.appName', '应用名称');
  m.set('settings.version', '版本');
  m.set('settings.developer', '开发者');
  m.set('settings.basedOn', '基于');
  m.set('settings.platform', '平台');
  m.set('settings.systemStatus', '系统状态');
  m.set('settings.gatewayStatus', '网关状态');
  m.set('settings.activeSessions', '活动会话');
  m.set('settings.memoryUsage', '内存占用');
  m.set('settings.tokenUsage', 'Token 消耗');
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
  m.set('settings.gatewayBot', '网关 Bot（已连接）');

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
  m.set('chat.talkRecognizing', '语音识别');
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
  m.set('settings.tabOperator', 'AI助理');
  m.set('settings.tabNode', '节点接入');
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

  // Sessions
  m.set('session.title', '对话');
  m.set('session.new', '新对话');
  m.set('session.default', '默认对话');
  m.set('session.close', '关闭');
  m.set('session.closeConfirm', '关闭此对话？对话历史将保留。');
  m.set('session.closed', '已关闭');
  m.set('session.closedTag', '已关闭');
  m.set('session.delete', '删除');
  m.set('session.deleteConfirm', '确定删除此对话？');
  m.set('session.deleted', '已删除');
  m.set('session.rename', '重命名');
  m.set('session.renameTitle', '重命名对话');
  m.set('session.renamePlaceholder', '输入新名称...');
  m.set('session.pin', '置顶');
  m.set('session.unpin', '取消置顶');
  m.set('session.clear', '清空消息');
  m.set('session.clearConfirm', '确定清空此对话的所有消息？');
  m.set('session.cleared', '已清空');
  m.set('session.cannotDeleteLast', '无法删除最后一个对话');
  m.set('memory.deleteSession', '删除对话');
  m.set('memory.deleteSessionConfirm', '确定永久删除此对话及所有历史消息？此操作不可恢复。');

  // Queue
  m.set('queue.pending', '排队中');
  m.set('queue.failed', '发送失败');
  m.set('queue.resend', '重新发送');
  m.set('queue.delete', '删除');
  m.set('queue.resendAll', '全部重发');
  m.set('queue.clearAll', '全部清除');
  m.set('queue.banner', '有 {0} 条排队消息');

  // Session Management
  m.set('settings.sessionManagement', '会话管理');
  m.set('settings.parallelSessions', '并行会话');
  m.set('settings.parallelSessionsDesc', '允许多个会话同时与 AI 对话');
  m.set('settings.idleTimeout', '闲置关闭');
  m.set('settings.idleTimeoutDesc', '超过此时间未活动的会话将自动关闭');
  m.set('settings.minutes', '分钟');

  // Voiceprint
  m.set('voiceprint.title', '声纹管理');
  m.set('voiceprint.speakerCount', '位说话人');
  m.set('voiceprint.empty', '暂无注册声纹');
  m.set('voiceprint.samples', '个样本');
  m.set('voiceprint.remove', '删除');
  m.set('voiceprint.enroll', '注册新声纹');
  m.set('voiceprint.enterName', '请输入说话人名称');
  m.set('voiceprint.namePlaceholder', '例如：小明');
  m.set('voiceprint.nameExists', '该名称已注册');
  m.set('voiceprint.next', '下一步');
  m.set('voiceprint.cancel', '取消');
  m.set('voiceprint.recordStep', '录制语音样本');
  m.set('voiceprint.readAloud', '请朗读以下文字：');
  m.set('voiceprint.recording', '录音中...');
  m.set('voiceprint.startRecord', '开始录音');
  m.set('voiceprint.tooShort', '录音太短，请重试');
  m.set('voiceprint.sampleOk', '样本录制成功');
  m.set('voiceprint.processing', '正在处理...');
  m.set('voiceprint.success', '声纹注册成功');
  m.set('voiceprint.enrollFailed', '声纹注册失败');
  m.set('voiceprint.recordFailed', '录音失败');
  m.set('voiceprint.done', '完成');
  m.set('voiceprint.deleteConfirm', '确定删除 {0} 的声纹？');
  m.set('voiceprint.confirmDelete', '确认删除');
  m.set('voiceprint.removed', '声纹已删除');
  m.set('settings.voiceprint', '声纹识别');
  m.set('settings.voiceprintDesc', '本地声纹注册与识别');

  // Silent Mode
  m.set('silent.title', '静默记录');
  m.set('silent.start', '开始记录');
  m.set('silent.stop', '停止记录');
  m.set('silent.recording', '正在记录中...');
  m.set('silent.empty', '暂无对话记录');
  m.set('silent.entries', '条语音');
  m.set('silent.summary', '摘要');
  m.set('silent.transcript', '对话记录');
  m.set('silent.participants', '参与者');
  m.set('silent.duration', '时长');
  m.set('silent.deleteConfirm', '确定删除此对话记录？');
  m.set('silent.deleted', '已删除');
  m.set('silent.noSpeech', '未检测到语音');
  m.set('silent.summarizing', '正在生成摘要...');
  m.set('silent.completed', '已完成');
  m.set('silent.error', '记录出错');
  m.set('settings.silentMode', '静默记录');
  m.set('settings.silentModeDesc', '后台录音，自动识别说话人并转写');

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
  m.set('chat.sharedContent', 'Shared content received');
  m.set('chat.sharedImage', 'Shared image received');
  m.set('chat.playingAudio', 'Playing audio...');
  m.set('chat.audioPlayed', 'Audio played');
  m.set('chat.audioFailed', 'Audio playback failed');
  m.set('chat.audioReady', 'Tap to play recording');
  m.set('chat.audioPlaying', 'Playing...');
  m.set('chat.recording', 'Recording...');
  m.set('chat.voiceMessage', 'Voice message');
  m.set('chat.copy', 'Copy');
  m.set('chat.reply', 'Reply');
  m.set('chat.newSession', 'New Session');
  m.set('chat.you', 'You');
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
  m.set('settings.aiEngine', 'AI Engine');
  m.set('settings.aiEngineDesc', 'ASR, Embedding, Intent Recognition');
  m.set('settings.aiEngineGatewayHint', 'Gateway connected, using gateway models');
  m.set('settings.aiEngineInheritHint', 'Uses API Key from AI Provider above');
  m.set('settings.asrModel', 'ASR Model');
  m.set('settings.asrModelPlaceholder', 'Empty = use gateway model');
  m.set('settings.asrModelHint', 'Empty = gateway LLM, filled = dedicated ASR model');
  m.set('settings.asrMode', 'Speech Recognition');
  m.set('settings.asrModeDesc', 'Choose speech recognition method');
  m.set('settings.asrModeAuto', 'Auto');
  m.set('settings.asrModeLocal', 'Local Only');
  m.set('settings.asrModeCloud', 'Cloud Only');
  m.set('settings.asrModeAutoDesc', 'Cloud first, local fallback when offline');
  m.set('settings.asrModeLocalDesc', 'Use local offline recognition (Chinese only)');
  m.set('settings.asrModeCloudDesc', 'Use cloud speech recognition service');
  m.set('settings.embeddingMode', 'Embedding');
  m.set('settings.embeddingModeDesc', 'Embedding method for memory search');
  m.set('settings.embeddingModeAuto', 'Auto');
  m.set('settings.embeddingModeLocal', 'Local Only');
  m.set('settings.embeddingModeCloud', 'Cloud Only');
  m.set('settings.embeddingModeAutoDesc', 'Local MiniLM first, cloud fallback');
  m.set('settings.embeddingModeLocalDesc', 'Use local MiniLM model (offline)');
  m.set('settings.embeddingModeCloudDesc', 'Use SiliconFlow bge-m3 cloud embedding');
  m.set('settings.intentMode', 'Intent Detection');
  m.set('settings.intentModeDesc', 'User intent recognition method');
  m.set('settings.intentModeAuto', 'Auto');
  m.set('settings.intentModeLocal', 'Local Only');
  m.set('settings.intentModeCloud', 'Cloud Only');
  m.set('settings.intentModeAutoDesc', 'Local keyword match + LLM tool calls');
  m.set('settings.intentModeLocalDesc', 'Local keyword matching only (fast, offline)');
  m.set('settings.intentModeCloudDesc', 'Rely on LLM for intent recognition and tool calls');

  // SettingsPage - Unread message notification
  m.set('settings.unreadNotification', 'Unread Notifications');
  m.set('settings.unreadNotificationDesc', 'Show new messages in status bar when app is in background');

  // SettingsPage - TTS auto-read
  m.set('settings.ttsAutoRead', 'Auto Read Aloud');
  m.set('settings.ttsAutoReadDesc', 'Auto read AI responses aloud (local TTS)');

  // SettingsPage - Auto memory inject
  m.set('settings.autoMemoryInject', 'Smart Memory Inject');
  m.set('settings.autoMemoryInjectDesc', 'Auto-inject relevant memories when sending messages');

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

  // ExperiencePage
  m.set('experience.title', 'Experience');
  m.set('experience.tabExperience', 'Experience');
  m.set('experience.tabSkills', 'Skills');
  m.set('experience.tabMemory', 'Memory');
  m.set('experience.countExp', ' experiences');
  m.set('experience.countSkill', ' skills');
  m.set('experience.countMemory', ' memories');
  m.set('experience.lastSync', 'Last sync');
  m.set('experience.levelPublic', 'Public');
  m.set('experience.levelSummary', 'Summary');
  m.set('experience.levelPrivate', 'Private');
  m.set('experience.empty', 'No experiences');
  m.set('experience.emptyHint', 'Experiences will be learned during AI interactions');
  m.set('experience.skills', 'Skills');
  m.set('experience.memories', 'Memories');
  m.set('experience.noSkills', 'No skills');
  m.set('experience.noMemory', 'No memories');
  m.set('experience.createdAt', 'Created');
  m.set('experience.updatedAt', 'Updated');

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
  m.set('memory.searchPlaceholder', 'Search memories...');
  m.set('memory.placeholder', 'What should ClawdBot remember?');
  m.set('memory.clearTitle', 'Clear All Memory');
  m.set('memory.clearMessage', 'Permanently delete all stored memories?');
  m.set('memory.cancel', 'Cancel');
  m.set('memory.clear', 'Clear');
  m.set('memory.extractFromChat', 'Extract from Chat');
  m.set('memory.extracting', 'Analyzing...');
  m.set('memory.syncFromServer', 'Sync from Server');
  m.set('memory.syncing', 'Syncing...');
  m.set('memory.syncDone', 'Synced, {0} new items');
  m.set('memory.syncFailed', 'Sync failed');
  m.set('memory.noMessages', 'No messages in current chat');
  m.set('memory.tabMemory', 'Memory');
  m.set('memory.tabHistory', 'Chat History');
  m.set('memory.noSessions', 'No conversations yet');
  m.set('memory.messages', ' messages');
  m.set('memory.backToList', 'Back');

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
  m.set('settings.connected', 'Connected');
  m.set('settings.connecting', 'Connecting...');
  m.set('settings.disconnected', 'Disconnected');
  m.set('settings.reconnecting', 'Reconnecting...');
  m.set('settings.connectionError', 'Connection Error');
  m.set('settings.pairingPending', 'Awaiting Pairing Approval');
  m.set('settings.parallelSessions', 'Parallel Sessions');
  m.set('settings.parallelSessionsDesc', '⚠️ Higher values increase token consumption rate');
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
  m.set('settings.appName', 'App Name');
  m.set('settings.version', 'Version');
  m.set('settings.developer', 'Developer');
  m.set('settings.basedOn', 'Based on');
  m.set('settings.platform', 'Platform');
  m.set('settings.systemStatus', 'System Status');
  m.set('settings.gatewayStatus', 'Gateway');
  m.set('settings.activeSessions', 'Active Sessions');
  m.set('settings.memoryUsage', 'Memory');
  m.set('settings.tokenUsage', 'Tokens');
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
  m.set('settings.gatewayBot', 'Gateway Bot (Connected)');

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
  m.set('chat.talkRecognizing', 'Recognizing');
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

  // Sessions
  m.set('session.title', 'Chats');
  m.set('session.new', 'New Chat');
  m.set('session.default', 'Default Chat');
  m.set('session.close', 'Close');
  m.set('session.closeConfirm', 'Close this conversation? History will be preserved.');
  m.set('session.closed', 'Closed');
  m.set('session.closedTag', 'Closed');
  m.set('session.delete', 'Delete');
  m.set('session.deleteConfirm', 'Delete this conversation?');
  m.set('session.deleted', 'Deleted');
  m.set('session.rename', 'Rename');
  m.set('session.renameTitle', 'Rename Conversation');
  m.set('session.renamePlaceholder', 'Enter new name...');
  m.set('session.pin', 'Pin');
  m.set('session.unpin', 'Unpin');
  m.set('session.clear', 'Clear Messages');
  m.set('session.clearConfirm', 'Clear all messages in this conversation?');
  m.set('session.cleared', 'Cleared');
  m.set('session.cannotDeleteLast', 'Cannot delete the last conversation');
  m.set('memory.deleteSession', 'Delete Conversation');
  m.set('memory.deleteSessionConfirm', 'Permanently delete this conversation and all its messages? This cannot be undone.');

  // Queue
  m.set('queue.pending', 'Pending');
  m.set('queue.failed', 'Failed');
  m.set('queue.resend', 'Resend');
  m.set('queue.delete', 'Delete');
  m.set('queue.resendAll', 'Resend All');
  m.set('queue.clearAll', 'Clear All');
  m.set('queue.banner', '{0} queued message(s)');

  // Session Management
  m.set('settings.sessionManagement', 'SESSION');
  m.set('settings.parallelSessions', 'Parallel Sessions');
  m.set('settings.parallelSessionsDesc', 'Allow multiple sessions to chat with AI simultaneously');
  m.set('settings.idleTimeout', 'Idle Timeout');
  m.set('settings.idleTimeoutDesc', 'Sessions inactive for this duration will auto-close');
  m.set('settings.minutes', 'min');

  // Voiceprint
  m.set('voiceprint.title', 'Voiceprint');
  m.set('voiceprint.speakerCount', 'speaker(s)');
  m.set('voiceprint.empty', 'No registered voiceprints');
  m.set('voiceprint.samples', 'sample(s)');
  m.set('voiceprint.remove', 'Remove');
  m.set('voiceprint.enroll', 'Register New Voiceprint');
  m.set('voiceprint.enterName', 'Enter speaker name');
  m.set('voiceprint.namePlaceholder', 'e.g. John');
  m.set('voiceprint.nameExists', 'Name already registered');
  m.set('voiceprint.next', 'Next');
  m.set('voiceprint.cancel', 'Cancel');
  m.set('voiceprint.recordStep', 'Record Voice Sample');
  m.set('voiceprint.readAloud', 'Please read the following text aloud:');
  m.set('voiceprint.recording', 'Recording...');
  m.set('voiceprint.startRecord', 'Start Recording');
  m.set('voiceprint.tooShort', 'Recording too short, please retry');
  m.set('voiceprint.sampleOk', 'Sample recorded successfully');
  m.set('voiceprint.processing', 'Processing...');
  m.set('voiceprint.success', 'Voiceprint registered');
  m.set('voiceprint.enrollFailed', 'Voiceprint registration failed');
  m.set('voiceprint.recordFailed', 'Recording failed');
  m.set('voiceprint.done', 'Done');
  m.set('voiceprint.deleteConfirm', 'Delete voiceprint for {0}?');
  m.set('voiceprint.confirmDelete', 'Confirm Delete');
  m.set('voiceprint.removed', 'Voiceprint removed');
  m.set('settings.voiceprint', 'VOICEPRINT');
  m.set('settings.voiceprintDesc', 'Local voiceprint enrollment & identification');

  // Silent Mode
  m.set('silent.title', 'Silent Recorder');
  m.set('silent.start', 'Start Recording');
  m.set('silent.stop', 'Stop Recording');
  m.set('silent.recording', 'Recording...');
  m.set('silent.empty', 'No conversations recorded');
  m.set('silent.entries', 'segment(s)');
  m.set('silent.summary', 'Summary');
  m.set('silent.transcript', 'Transcript');
  m.set('silent.participants', 'Participants');
  m.set('silent.duration', 'Duration');
  m.set('silent.deleteConfirm', 'Delete this conversation record?');
  m.set('silent.deleted', 'Deleted');
  m.set('silent.noSpeech', 'No speech detected');
  m.set('silent.summarizing', 'Generating summary...');
  m.set('silent.completed', 'Completed');
  m.set('silent.error', 'Recording error');
  m.set('settings.silentMode', 'SILENT RECORDER');
  m.set('settings.silentModeDesc', 'Background recording with speaker ID and transcription');

  return m;
}

const zhMap: Map<string, string> = buildZh();
const enMap: Map<string, string> = buildEn();

const heartbeatGreetingsZh: string[] = [
  '你怎么样呀？',
  '一切都好吗？',
  '在忙什么呢？',
  '今天过得怎么样？',
  '有什么需要帮忙的吗？',
];

const heartbeatGreetingsEn: string[] = [
  "How's it going?",
  'Everything okay?',
  "What's up?",
  'How are you doing?',
  'Need any help?',
];

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

  /** Check if text is a HEARTBEAT_OK message and return a friendly greeting, or empty string if not. */
  static getHeartbeatGreeting(text: string): string {
    let trimmed = text.trim();
    if (trimmed === 'HEARTBEAT_OK' || trimmed === 'heartbeat_ok') {
      let greetings = I18n.currentLang === 'zh' ? heartbeatGreetingsZh : heartbeatGreetingsEn;
      let idx = Math.floor(Math.random() * greetings.length);
      return greetings[idx];
    }
    return '';
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
