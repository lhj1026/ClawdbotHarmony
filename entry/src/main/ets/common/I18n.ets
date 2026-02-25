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
  m.set('memory.extractAll', '一键提取');
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
  m.set('settings.stop', '停止');
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
  m.set('app.exit', '退出');
  m.set('app.exitConfirm', '确定要退出应用吗？');
  m.set('error.insufficientBalance', 'API 余额不足，请充值后再试');
  m.set('error.invalidApiKey', 'API Key 无效，请检查设置');
  m.set('error.networkError', '网络连接失败，请检查网络');
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
  m.set('silent.monitoring', '监听中...');
  m.set('silent.listening', '检测语音...');
  m.set('silent.processing', '识别中...');
  m.set('settings.silentMode', '静默记录');
  m.set('settings.silentModeDesc', '后台录音，自动识别说话人并转写');
  m.set('silent.select', '选择');
  m.set('silent.selectAll', '全选');
  m.set('silent.deselectAll', '取消全选');
  m.set('settings.silentLocalAsr', '本地语音识别');
  m.set('settings.silentLocalAsrDesc', '使用系统内置 ASR 实时转写（效果较差，默认关闭）');
  m.set('settings.silentAudioModel', '音频摘要模型');
  m.set('settings.silentAudioModelDesc', '留空=使用主模型，填写=使用指定模型（如 Qwen/Qwen3-Omni-30B-A3B-Instruct）');
  m.set('silent.actionItems', '行动项');
  m.set('silent.addedToCalendar', '已添加到日历');
  m.set('silent.failedToAdd', '添加失败');
  m.set('silent.actionItemBadge', '项待办');

  // Place Discovery
  m.set('place.discoveredTitle', '发现新地点');
  m.set('place.confirmSave', '确认保存');
  m.set('place.ignore', '忽略');
  m.set('place.rename', '改名');
  m.set('place.saveAs', '保存为');
  m.set('place.stayedFor', '已停留');
  m.set('place.minutes', '分钟');
  m.set('place.clickToSave', '点击确认保存');
  m.set('place.nearbyTitle', '附近地点');
  m.set('place.lastVisit', '上次来过');
  m.set('place.distance', '距离');
  m.set('place.visits', '次访问');
  m.set('place.noPending', '暂无待确认地点');
  m.set('place.noDiscovered', '暂无已保存地点');
  m.set('place.visitHistory', '访问历史');
  m.set('place.today', '今天');
  m.set('place.yesterday', '昨天');
  m.set('place.thisWeek', '本周');
  m.set('place.thisMonth', '本月');
  m.set('place.earlier', '更早');

  // Place Categories - 中文
  m.set('place.category.home', '家');
  m.set('place.category.work', '公司');
  m.set('place.category.restaurant', '餐厅');
  m.set('place.category.shopping', '购物');
  m.set('place.category.transit', '交通');
  m.set('place.category.gym', '健身');
  m.set('place.category.cafe', '咖啡厅');
  m.set('place.category.hotel', '酒店');
  m.set('place.category.hospital', '医院');
  m.set('place.category.school', '学校');
  m.set('place.category.park', '公园');
  m.set('place.category.custom', '其他');

  // Time ago format
  m.set('time.minutesAgo', '{0}分钟前');
  m.set('time.hoursAgo', '{0}小时前');
  m.set('time.daysAgo', '{0}天前');
  m.set('time.justNow', '刚刚');

  // Settings - Place Discovery
  m.set('settings.placeDiscovery', '地点发现');
  m.set('settings.placeDiscoveryDesc', '自动识别常去地点并记录');
  m.set('settings.placeDiscoveryEnabled', '启用地点发现');
  m.set('settings.placeDiscoveryMinStay', '最小停留时间');
  m.set('settings.placeDiscoveryNotify', '发现新地点时通知');
  m.set('settings.placeCategories', '地点分类管理');
  m.set('settings.learnedSignals', '已学习信号');
  m.set('settings.clearLearnedSignals', '清除学习信号');
  m.set('settings.clearLearnedSignalsConfirm', '确定清除所有已学习的位置信号？需要重新学习。');

  // Context Awareness - New Place Discovery
  m.set('context.newPlace.title', '发现新地点');
  m.set('context.newPlace.wifi', 'WiFi');
  m.set('context.newPlace.saveAs', '保存为');
  m.set('context.newPlace.rename', '改名');
  m.set('context.newPlace.ignore', '忽略');
  m.set('context.newPlace.defaultName', '新地点');

  // Context Awareness - Suggestions
  m.set('context.suggestion.discovered', '发现你经常去这里');
  m.set('context.suggestion.goToSettings', '前往"情景智能设置"查看并添加围栏');

  // Context Awareness - Notifications
  m.set('context.notification.title', '情景智能');
  m.set('context.notification.discoveredPlace', '发现常去地点');
  m.set('context.notification.recommendation', '情景智能推荐');
  m.set('context.confidence', '置信度');
  m.set('context.feedback.useful', '有用');
  m.set('context.feedback.inaccurate', '不准');
  m.set('context.feedback.dismiss', '忽略');
  m.set('context.feedback.viewDetails', '查看详情');

  // Context Awareness - Discovery
  m.set('context.discovery.running', '正在分析位置历史...');
  m.set('context.discovery.found', '发现 {0} 个常去地点');
  m.set('context.discovery.noResult', '暂未发现新地点，继续积累位置数据');
  m.set('context.discovery.notEnoughData', '位置数据不足 (需要至少10个点)');

  // Context Awareness - Geofence Feature Learning
  m.set('context.geofence.learned', '地点特征已学习');
  m.set('context.geofence.newWifi', '关联WiFi');
  m.set('context.geofence.newBt', '关联蓝牙');
  m.set('context.geofence.saved', '已保存地点');
  m.set('context.geofence.category', '类型');

  // Context Awareness - Explore Mode
  m.set('context.explore.title', '积极探索模式');
  m.set('context.explore.desc', '遇到新情境时主动用AI生成建议，用户反馈后转化为规则');
  m.set('context.explore.fingerprints', '已探索状态');

  // App title
  m.set('app.title', 'OpenClaw 鸿蒙');

  // ContextSettingsPage
  m.set('ctx.settings.title', '情景智能设置');
  m.set('ctx.status.current', '当前状态');
  m.set('ctx.engine.title', '引擎状态');
  m.set('ctx.engine.ruleCount', 'C++ 规则数: {0}');
  m.set('ctx.engine.manageRules', '管理规则');
  m.set('ctx.engine.notInit', '情景智能未初始化');
  m.set('ctx.tray.title', '数据托盘');
  m.set('ctx.tray.refresh', '刷新');
  m.set('ctx.tray.autoRefresh', '每 5 秒自动刷新');
  m.set('ctx.tray.empty', '托盘为空（传感器未开始写入）');
  m.set('ctx.tray.physical', '物理世界');
  m.set('ctx.tray.digital', '数字世界');
  m.set('ctx.tray.noPlugin', '暂无插件数据');
  m.set('ctx.tray.colName', '名称');
  m.set('ctx.tray.colValue', '数值');
  m.set('ctx.tray.colAge', '龄');
  m.set('ctx.tray.colQuality', '质');
  m.set('ctx.geofence.title', '地理围栏');
  m.set('ctx.geofence.add', '＋ 添加');
  m.set('ctx.geofence.empty', '暂无围栏，点击右上角添加');
  m.set('ctx.geofence.delete', '删除');
  m.set('ctx.signal.title', '位置信号学习');
  m.set('ctx.signal.clearAll', '清除全部');
  m.set('ctx.signal.desc', 'GPS 高精度时自动学习 WiFi/蓝牙信号，用于室内定位增强');
  m.set('ctx.signal.empty', '暂无已学习信号，进入围栏区域后会自动学习');
  m.set('ctx.signal.observations', '观测 {0} 次');
  m.set('ctx.signal.clear', '清除');
  m.set('ctx.feedback.title', '反馈统计');
  m.set('ctx.feedback.refreshed', '反馈统计已刷新');
  m.set('ctx.feedback.total', '总反馈');
  m.set('ctx.feedback.positiveRate', '好评率');
  m.set('ctx.feedback.topRules', '最有效规则 Top {0}');
  m.set('ctx.mab.title', 'MAB 学习统计');
  m.set('ctx.mab.noData', '暂无数据');
  m.set('ctx.discovery.title', '位置自动发现');
  m.set('ctx.discovery.runNow', '立即发现');
  m.set('ctx.discovery.notStarted', '未启动');
  m.set('ctx.discovery.empty', '暂无发现，GPS 历史积累后会自动发现常去地点');
  m.set('ctx.discovery.statsTemplate', '历史点: {0} | 聚类: {1} | 上次发现: {2}');
  m.set('ctx.dialog.addGeofence', '添加地理围栏');
  m.set('ctx.dialog.namePlaceholder', '名称（如：家、公司）');
  m.set('ctx.dialog.latitude', '纬度');
  m.set('ctx.dialog.longitude', '经度');
  m.set('ctx.dialog.radiusPlaceholder', '半径（米），默认100');
  m.set('ctx.dialog.category', '类别');
  m.set('ctx.dialog.cancel', '取消');
  m.set('ctx.dialog.add', '添加');
  m.set('ctx.dialog.searchFailed', '未找到该地点');
  m.set('ctx.dialog.searchFirst', '请先输入地名并点击🔍搜索');
  m.set('ctx.dialog.invalidCoords', '坐标格式无效');
  m.set('ctx.status.morning', '上午');
  m.set('ctx.status.afternoon', '下午');
  m.set('ctx.status.evening', '傍晚');
  m.set('ctx.status.night', '晚上');
  m.set('ctx.status.stationary', '静止');
  m.set('ctx.status.walking', '步行');
  m.set('ctx.status.running', '跑步');
  m.set('ctx.status.cycling', '骑行');
  m.set('ctx.status.driving', '驾车');
  m.set('ctx.status.transit', '交通');
  m.set('ctx.status.pickup', '拿起手机');
  m.set('ctx.status.putdown', '放下手机');
  m.set('ctx.status.unknown', '未知');

  // SettingsPage - Context Awareness section
  m.set('settings.contextAwareness', '情景智能');
  m.set('settings.contextAwarenessDesc', '传感器+定位持续采集，耗电较高');
  m.set('settings.checkUpdate', '检查更新');
  m.set('settings.newVersion', '新版本 {0}');

  // SettingsPage - Experience Pack
  m.set('settings.expPack', '经验包');
  m.set('settings.expCount', '经验');
  m.set('settings.expItems', '{0} 条');
  m.set('settings.expSkills', '├ 技能');
  m.set('settings.expSkillItems', '{0} 个');
  m.set('settings.expMemory', '└ 记忆');
  m.set('settings.expLastSync', '上次同步');
  m.set('settings.expNeverSync', '从未同步');
  m.set('settings.expExport', '导出经验包');
  m.set('settings.expImport', '导入经验包');
  m.set('settings.expSyncUp', '同步到服务端');
  m.set('settings.expSyncDown', '从服务端拉取');
  m.set('settings.expClear', '清除经验');
  m.set('settings.expNoData', '没有经验数据可导出');
  m.set('settings.expExported', '已导出到: experience_pack.json');
  m.set('settings.expImported', '经验包导入成功');
  m.set('settings.expClearTitle', '确认清除');
  m.set('settings.expClearConfirm', '清除所有经验数据？此操作不可恢复。');
  m.set('settings.expCleared', '经验已清除');
  m.set('settings.expPushed', '经验包已推送到服务端');
  m.set('settings.expPulled', '已拉取 {0} 条经验');
  m.set('settings.expSyncing', '正在同步到服务端...');
  m.set('settings.expPulling', '正在从服务端拉取...');
  m.set('settings.expNoGateway', '未连接 Gateway，无法同步');
  m.set('settings.expImportFail', '导入失败: 数据格式无效');
  m.set('settings.expPullTimeout', '拉取超时或失败');

  // SettingsPage - Module Monitor
  m.set('settings.moduleMonitor', '模块监控');
  m.set('settings.moduleStatus', '显示模块状态');
  m.set('settings.moduleRefresh', '刷新状态');
  m.set('settings.moduleRefreshed', '已刷新');
  m.set('settings.moduleCalls', '调用: {0}次');
  m.set('settings.moduleLastActive', '最后活跃: {0}');

  // Built-in rule names
  m.set('rule.name.rule_morning_workday', '工作日早出门');
  m.set('rule.name.rule_low_battery', '低电量提醒');
  m.set('rule.name.rule_weekend_morning', '周末早上');
  m.set('rule.name.rule_long_stationary', '久坐提醒');
  m.set('rule.name.rule_home_sedentary_alert', '在家久坐提醒（1小时）');
  m.set('rule.name.rule_home_sedentary_wifi', '在家久坐提醒（WiFi检测）');
  m.set('rule.name.rule_commuting', '通勤路上');
  m.set('rule.name.rule_bedtime', '睡前提醒');
  m.set('rule.name.rule_evening_home', '到家放松');
  m.set('rule.name.rule_leave_home_morning', '早上离家');
  m.set('rule.name.rule_arrive_work', '到达公司');
  m.set('rule.name.rule_leave_work', '下班离开公司（围栏）');
  m.set('rule.name.rule_leave_work_wifi', '离开公司（WiFi丢失）');
  m.set('rule.name.rule_leave_work_music', '离开公司步行听音乐（围栏）');
  m.set('rule.name.rule_leave_work_music_wifi', '离开公司步行听音乐（WiFi丢失）');
  m.set('rule.name.rule_arrive_gym', '到达健身房');
  m.set('rule.name.rule_arrive_home', '到家（围栏）');
  m.set('rule.name.rule_arrive_home_wifi', '到家（WiFi连接）');
  m.set('rule.name.rule_leave_home_wifi', '离家（WiFi丢失）');
  m.set('rule.name.rule_arrive_work_wifi', '到达公司（WiFi连接）');
  m.set('rule.name.rule_arrive_gym_wifi', '到达健身房（WiFi连接）');

  // RuleManagementPage UI
  m.set('rules.title', '规则管理');
  m.set('rules.addRule', '+ 添加规则');
  m.set('rules.empty', '暂无规则');
  m.set('rules.custom', '自定义');
  m.set('rules.builtin', '内置');
  m.set('rules.notification', '通知');
  m.set('rules.suggestion', '建议');
  m.set('rules.delete', '删除');
  m.set('rules.addCustom', '添加自定义规则');
  m.set('rules.namePlaceholder', '规则名称');
  m.set('rules.conditions', '触发条件');
  m.set('rules.addCondition', '+ 添加条件');
  m.set('rules.actionType', '动作类型');
  m.set('rules.payloadPlaceholder', '提示文字（如：该喝水了）');
  m.set('rules.cooldown', '冷却时间');
  m.set('rules.cancel', '取消');
  m.set('rules.save', '保存');
  m.set('rules.value', '值');
  m.set('rules.cooldown30m', '30分钟');
  m.set('rules.cooldown1h', '1小时');
  m.set('rules.cooldown2h', '2小时');
  m.set('rules.cooldown4h', '4小时');
  m.set('rules.cooldown8h', '8小时');
  m.set('rules.cooldown24h', '24小时');
  m.set('rules.key.timeOfDay', '时段');
  m.set('rules.key.hour', '小时(0-23)');
  m.set('rules.key.dayOfWeek', '星期(0-6)');
  m.set('rules.key.isWeekend', '是否周末');
  m.set('rules.key.motionState', '运动状态');
  m.set('rules.key.batteryLevel', '电量(0-100)');
  m.set('rules.key.isCharging', '是否充电');
  m.set('rules.key.networkType', '网络类型');
  m.set('rules.key.geofence', '位置围栏');
  m.set('rules.key.timeOfDay.short', '时段');
  m.set('rules.key.hour.short', '小时');
  m.set('rules.key.dayOfWeek.short', '星期');
  m.set('rules.key.isWeekend.short', '周末');
  m.set('rules.key.motionState.short', '运动');
  m.set('rules.key.batteryLevel.short', '电量');
  m.set('rules.key.isCharging.short', '充电');
  m.set('rules.key.networkType.short', '网络');
  m.set('rules.key.geofence.short', '位置');
  m.set('rules.opContains', '∈(包含)');

  // Device classification & Sensor tier
  m.set('context.device.fixed', '固定设备');
  m.set('context.device.portable', '便携设备');
  m.set('context.device.vehicle', '车载设备');
  m.set('context.device.inVehicle', '检测到车载蓝牙');
  m.set('context.tier.escalated', '传感器升级到 T{0}');
  m.set('context.tier.deescalated', '传感器降级到 T{0}');
  m.set('context.geofence.autoCreated', '自动创建新地点');
  m.set('context.wifi.hotspot', '移动热点（跳过）');
  m.set('context.wifi.public', '公共WiFi（跳过）');
  m.set('context.exercise.detected', '运动心率，GPS追踪开启');
  m.set('rule.name.rule_vehicle_bt_detected', '车载蓝牙驾驶模式');
  m.set('rule.name.rule_exercise_heart_rate', '运动心率追踪');

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
  m.set('memory.extractAll', 'Extract All');
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
  m.set('settings.stop', 'Stop');
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
  m.set('app.exit', 'Exit');
  m.set('app.exitConfirm', 'Exit the app?');
  m.set('error.insufficientBalance', 'Insufficient API balance. Please top up.');
  m.set('error.invalidApiKey', 'Invalid API Key. Please check settings.');
  m.set('error.networkError', 'Network error. Please check connection.');
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
  m.set('silent.monitoring', 'Monitoring...');
  m.set('silent.listening', 'Detecting speech...');
  m.set('silent.processing', 'Recognizing...');
  m.set('settings.silentMode', 'SILENT RECORDER');
  m.set('settings.silentModeDesc', 'Background recording with speaker ID and transcription');
  m.set('silent.select', 'Select');
  m.set('silent.selectAll', 'Select All');
  m.set('silent.deselectAll', 'Deselect All');
  m.set('settings.silentLocalAsr', 'Local ASR');
  m.set('settings.silentLocalAsrDesc', 'Use built-in system ASR for real-time transcription (poor quality, off by default)');
  m.set('settings.silentAudioModel', 'Audio Summary Model');
  m.set('settings.silentAudioModelDesc', 'Empty=use main model, or specify (e.g. Qwen/Qwen3-Omni-30B-A3B-Instruct)');
  m.set('silent.actionItems', 'Action Items');
  m.set('silent.addedToCalendar', 'Added to calendar');
  m.set('silent.failedToAdd', 'Failed to add');
  m.set('silent.actionItemBadge', 'action items');

  // Place Discovery
  m.set('place.discoveredTitle', 'New Place Discovered');
  m.set('place.confirmSave', 'Confirm Save');
  m.set('place.ignore', 'Ignore');
  m.set('place.rename', 'Rename');
  m.set('place.saveAs', 'Save as');
  m.set('place.stayedFor', 'Stayed for');
  m.set('place.minutes', 'minutes');
  m.set('place.clickToSave', 'Tap to confirm and save');
  m.set('place.nearbyTitle', 'Nearby Place');
  m.set('place.lastVisit', 'Last visit');
  m.set('place.distance', 'Distance');
  m.set('place.visits', 'visits');
  m.set('place.noPending', 'No pending places');
  m.set('place.noDiscovered', 'No saved places');
  m.set('place.visitHistory', 'Visit History');
  m.set('place.today', 'Today');
  m.set('place.yesterday', 'Yesterday');
  m.set('place.thisWeek', 'This week');
  m.set('place.thisMonth', 'This month');
  m.set('place.earlier', 'Earlier');

  // Place Categories - English
  m.set('place.category.home', 'Home');
  m.set('place.category.work', 'Work');
  m.set('place.category.restaurant', 'Restaurant');
  m.set('place.category.shopping', 'Shopping');
  m.set('place.category.transit', 'Transit');
  m.set('place.category.gym', 'Gym');
  m.set('place.category.cafe', 'Cafe');
  m.set('place.category.hotel', 'Hotel');
  m.set('place.category.hospital', 'Hospital');
  m.set('place.category.school', 'School');
  m.set('place.category.park', 'Park');
  m.set('place.category.custom', 'Other');

  // Time ago format
  m.set('time.minutesAgo', '{0} min ago');
  m.set('time.hoursAgo', '{0} hr ago');
  m.set('time.daysAgo', '{0} days ago');
  m.set('time.justNow', 'Just now');

  // Settings - Place Discovery
  m.set('settings.placeDiscovery', 'PLACE DISCOVERY');
  m.set('settings.placeDiscoveryDesc', 'Auto-detect and remember frequent locations');
  m.set('settings.placeDiscoveryEnabled', 'Enable Place Discovery');
  m.set('settings.placeDiscoveryMinStay', 'Minimum Stay Duration');
  m.set('settings.placeDiscoveryNotify', 'Notify on New Place');
  m.set('settings.placeCategories', 'Manage Categories');
  m.set('settings.learnedSignals', 'Learned Signals');
  m.set('settings.clearLearnedSignals', 'Clear Learned Signals');
  m.set('settings.clearLearnedSignalsConfirm', 'Clear all learned location signals? They will need to be relearned.');

  // Context Awareness - New Place Discovery
  m.set('context.newPlace.title', 'New Place Discovered');
  m.set('context.newPlace.wifi', 'WiFi');
  m.set('context.newPlace.saveAs', 'Save as');
  m.set('context.newPlace.rename', 'Rename');
  m.set('context.newPlace.ignore', 'Ignore');
  m.set('context.newPlace.defaultName', 'New Place');

  // Context Awareness - Suggestions
  m.set('context.suggestion.discovered', 'You frequently visit this place');
  m.set('context.suggestion.goToSettings', 'Go to Context Settings to add geofence');

  // Context Awareness - Notifications
  m.set('context.notification.title', 'Context Intelligence');
  m.set('context.notification.discoveredPlace', 'Discovered Frequent Location');
  m.set('context.notification.recommendation', 'Context Recommendation');
  m.set('context.confidence', 'Confidence');
  m.set('context.feedback.useful', 'Useful');
  m.set('context.feedback.inaccurate', 'Inaccurate');
  m.set('context.feedback.dismiss', 'Dismiss');
  m.set('context.feedback.viewDetails', 'View Details');

  // Context Awareness - Discovery
  m.set('context.discovery.running', 'Analyzing location history...');
  m.set('context.discovery.found', 'Found {0} frequent locations');
  m.set('context.discovery.noResult', 'No new locations found, keep collecting data');
  m.set('context.discovery.notEnoughData', 'Not enough location data (need at least 10 points)');

  // Context Awareness - Geofence Feature Learning
  m.set('context.geofence.learned', 'Place feature learned');
  m.set('context.geofence.newWifi', 'Linked WiFi');
  m.set('context.geofence.newBt', 'Linked Bluetooth');
  m.set('context.geofence.saved', 'Place saved');
  m.set('context.geofence.category', 'Category');

  // Context Awareness - Explore Mode
  m.set('context.explore.title', 'Active Explore Mode');
  m.set('context.explore.desc', 'AI suggests actions for new contexts; your feedback becomes rules');
  m.set('context.explore.fingerprints', 'Explored states');

  // App title
  m.set('app.title', 'OpenClaw Harmony');

  // ContextSettingsPage
  m.set('ctx.settings.title', 'Context Intelligence Settings');
  m.set('ctx.status.current', 'Current Status');
  m.set('ctx.engine.title', 'Engine Status');
  m.set('ctx.engine.ruleCount', 'C++ Rules: {0}');
  m.set('ctx.engine.manageRules', 'Manage Rules');
  m.set('ctx.engine.notInit', 'Context Intelligence not initialized');
  m.set('ctx.tray.title', 'Data Tray');
  m.set('ctx.tray.refresh', 'Refresh');
  m.set('ctx.tray.autoRefresh', 'Auto-refresh every 5s');
  m.set('ctx.tray.empty', 'Tray empty (sensors not yet writing)');
  m.set('ctx.tray.physical', 'Physical World');
  m.set('ctx.tray.digital', 'Digital World');
  m.set('ctx.tray.noPlugin', 'No plugin data');
  m.set('ctx.tray.colName', 'Name');
  m.set('ctx.tray.colValue', 'Value');
  m.set('ctx.tray.colAge', 'Age');
  m.set('ctx.tray.colQuality', 'Q');
  m.set('ctx.geofence.title', 'Geofences');
  m.set('ctx.geofence.add', '+ Add');
  m.set('ctx.geofence.empty', 'No geofences. Tap + to add one.');
  m.set('ctx.geofence.delete', 'Delete');
  m.set('ctx.signal.title', 'Location Signal Learning');
  m.set('ctx.signal.clearAll', 'Clear All');
  m.set('ctx.signal.desc', 'Auto-learns WiFi/BT signals with high-accuracy GPS for indoor positioning');
  m.set('ctx.signal.empty', 'No learned signals yet. Enter a geofence area to start learning.');
  m.set('ctx.signal.observations', '{0} observations');
  m.set('ctx.signal.clear', 'Clear');
  m.set('ctx.feedback.title', 'Feedback Stats');
  m.set('ctx.feedback.refreshed', 'Feedback stats refreshed');
  m.set('ctx.feedback.total', 'Total');
  m.set('ctx.feedback.positiveRate', 'Positive %');
  m.set('ctx.feedback.topRules', 'Top {0} Effective Rules');
  m.set('ctx.mab.title', 'MAB Learning Stats');
  m.set('ctx.mab.noData', 'No data');
  m.set('ctx.discovery.title', 'Auto Location Discovery');
  m.set('ctx.discovery.runNow', 'Discover Now');
  m.set('ctx.discovery.notStarted', 'Not started');
  m.set('ctx.discovery.empty', 'No discoveries yet. Frequent places will be found as GPS data accumulates.');
  m.set('ctx.discovery.statsTemplate', 'History: {0} | Clusters: {1} | Last: {2}');
  m.set('ctx.dialog.addGeofence', 'Add Geofence');
  m.set('ctx.dialog.namePlaceholder', 'Name (e.g., Home, Office)');
  m.set('ctx.dialog.latitude', 'Latitude');
  m.set('ctx.dialog.longitude', 'Longitude');
  m.set('ctx.dialog.radiusPlaceholder', 'Radius (m), default 100');
  m.set('ctx.dialog.category', 'Category');
  m.set('ctx.dialog.cancel', 'Cancel');
  m.set('ctx.dialog.add', 'Add');
  m.set('ctx.dialog.searchFailed', 'Place not found');
  m.set('ctx.dialog.searchFirst', 'Enter a place name and tap 🔍 to search');
  m.set('ctx.dialog.invalidCoords', 'Invalid coordinates');
  m.set('ctx.status.morning', 'Morning');
  m.set('ctx.status.afternoon', 'Afternoon');
  m.set('ctx.status.evening', 'Evening');
  m.set('ctx.status.night', 'Night');
  m.set('ctx.status.stationary', 'Stationary');
  m.set('ctx.status.walking', 'Walking');
  m.set('ctx.status.running', 'Running');
  m.set('ctx.status.cycling', 'Cycling');
  m.set('ctx.status.driving', 'Driving');
  m.set('ctx.status.transit', 'Transit');
  m.set('ctx.status.pickup', 'Picked up');
  m.set('ctx.status.putdown', 'Put down');
  m.set('ctx.status.unknown', 'Unknown');

  // SettingsPage - Context Awareness section
  m.set('settings.contextAwareness', 'Context Intelligence');
  m.set('settings.contextAwarenessDesc', 'Continuous sensor + GPS collection, higher battery usage');
  m.set('settings.checkUpdate', 'Check for Updates');
  m.set('settings.newVersion', 'New version {0}');

  // SettingsPage - Experience Pack
  m.set('settings.expPack', 'Experience Pack');
  m.set('settings.expCount', 'Experience');
  m.set('settings.expItems', '{0} items');
  m.set('settings.expSkills', '├ Skills');
  m.set('settings.expSkillItems', '{0} items');
  m.set('settings.expMemory', '└ Memory');
  m.set('settings.expLastSync', 'Last Sync');
  m.set('settings.expNeverSync', 'Never synced');
  m.set('settings.expExport', 'Export Experience');
  m.set('settings.expImport', 'Import Experience');
  m.set('settings.expSyncUp', 'Sync to Server');
  m.set('settings.expSyncDown', 'Pull from Server');
  m.set('settings.expClear', 'Clear Experience');
  m.set('settings.expNoData', 'No experience data to export');
  m.set('settings.expExported', 'Exported to: experience_pack.json');
  m.set('settings.expImported', 'Experience imported successfully');
  m.set('settings.expClearTitle', 'Confirm Clear');
  m.set('settings.expClearConfirm', 'Clear all experience data? This cannot be undone.');
  m.set('settings.expCleared', 'Experience cleared');
  m.set('settings.expPushed', 'Experience pushed to server');
  m.set('settings.expPulled', 'Pulled {0} experiences');
  m.set('settings.expSyncing', 'Syncing to server...');
  m.set('settings.expPulling', 'Pulling from server...');
  m.set('settings.expNoGateway', 'Not connected to Gateway');
  m.set('settings.expImportFail', 'Import failed: invalid data format');
  m.set('settings.expPullTimeout', 'Pull timed out or failed');

  // SettingsPage - Module Monitor
  m.set('settings.moduleMonitor', 'Module Monitor');
  m.set('settings.moduleStatus', 'Show Module Status');
  m.set('settings.moduleRefresh', 'Refresh Status');
  m.set('settings.moduleRefreshed', 'Refreshed');
  m.set('settings.moduleCalls', 'Calls: {0}');
  m.set('settings.moduleLastActive', 'Last active: {0}');

  // Built-in rule names
  m.set('rule.name.rule_morning_workday', 'Workday Morning Commute');
  m.set('rule.name.rule_low_battery', 'Low Battery Warning');
  m.set('rule.name.rule_weekend_morning', 'Weekend Morning');
  m.set('rule.name.rule_long_stationary', 'Sedentary Reminder');
  m.set('rule.name.rule_home_sedentary_alert', 'Home Sedentary Alert (1hr)');
  m.set('rule.name.rule_home_sedentary_wifi', 'Home Sedentary Alert (WiFi)');
  m.set('rule.name.rule_commuting', 'Commuting');
  m.set('rule.name.rule_bedtime', 'Bedtime Reminder');
  m.set('rule.name.rule_evening_home', 'Arrived Home - Relax');
  m.set('rule.name.rule_leave_home_morning', 'Leaving Home Morning');
  m.set('rule.name.rule_arrive_work', 'Arrived at Work');
  m.set('rule.name.rule_leave_work', 'Leaving Work (Geofence)');
  m.set('rule.name.rule_leave_work_wifi', 'Leaving Work (WiFi Lost)');
  m.set('rule.name.rule_leave_work_music', 'Walking from Work - Music (Geofence)');
  m.set('rule.name.rule_leave_work_music_wifi', 'Walking from Work - Music (WiFi)');
  m.set('rule.name.rule_arrive_gym', 'Arrived at Gym');
  m.set('rule.name.rule_arrive_home', 'Arrived Home (Geofence)');
  m.set('rule.name.rule_arrive_home_wifi', 'Arrived Home (WiFi)');
  m.set('rule.name.rule_leave_home_wifi', 'Leaving Home (WiFi Lost)');
  m.set('rule.name.rule_arrive_work_wifi', 'Arrived at Work (WiFi)');
  m.set('rule.name.rule_arrive_gym_wifi', 'Arrived at Gym (WiFi)');

  // RuleManagementPage UI
  m.set('rules.title', 'Rule Management');
  m.set('rules.addRule', '+ Add Rule');
  m.set('rules.empty', 'No rules');
  m.set('rules.custom', 'Custom');
  m.set('rules.builtin', 'Built-in');
  m.set('rules.notification', 'Notification');
  m.set('rules.suggestion', 'Suggestion');
  m.set('rules.delete', 'Delete');
  m.set('rules.addCustom', 'Add Custom Rule');
  m.set('rules.namePlaceholder', 'Rule Name');
  m.set('rules.conditions', 'Conditions');
  m.set('rules.addCondition', '+ Add Condition');
  m.set('rules.actionType', 'Action Type');
  m.set('rules.payloadPlaceholder', 'Message (e.g., Time to drink water)');
  m.set('rules.cooldown', 'Cooldown');
  m.set('rules.cancel', 'Cancel');
  m.set('rules.save', 'Save');
  m.set('rules.value', 'Value');
  m.set('rules.cooldown30m', '30 min');
  m.set('rules.cooldown1h', '1 hour');
  m.set('rules.cooldown2h', '2 hours');
  m.set('rules.cooldown4h', '4 hours');
  m.set('rules.cooldown8h', '8 hours');
  m.set('rules.cooldown24h', '24 hours');
  m.set('rules.key.timeOfDay', 'Time of Day');
  m.set('rules.key.hour', 'Hour (0-23)');
  m.set('rules.key.dayOfWeek', 'Day (0-6)');
  m.set('rules.key.isWeekend', 'Weekend?');
  m.set('rules.key.motionState', 'Motion State');
  m.set('rules.key.batteryLevel', 'Battery (0-100)');
  m.set('rules.key.isCharging', 'Charging?');
  m.set('rules.key.networkType', 'Network Type');
  m.set('rules.key.geofence', 'Geofence');
  m.set('rules.key.timeOfDay.short', 'Time');
  m.set('rules.key.hour.short', 'Hour');
  m.set('rules.key.dayOfWeek.short', 'Day');
  m.set('rules.key.isWeekend.short', 'Wknd');
  m.set('rules.key.motionState.short', 'Motion');
  m.set('rules.key.batteryLevel.short', 'Batt');
  m.set('rules.key.isCharging.short', 'Chrg');
  m.set('rules.key.networkType.short', 'Net');
  m.set('rules.key.geofence.short', 'Place');
  m.set('rules.opContains', '∈(contains)');

  // Device classification & Sensor tier
  m.set('context.device.fixed', 'Fixed Device');
  m.set('context.device.portable', 'Portable Device');
  m.set('context.device.vehicle', 'Vehicle Device');
  m.set('context.device.inVehicle', 'Vehicle BT detected');
  m.set('context.tier.escalated', 'Sensors escalated to T{0}');
  m.set('context.tier.deescalated', 'Sensors de-escalated to T{0}');
  m.set('context.geofence.autoCreated', 'Auto-created new place');
  m.set('context.wifi.hotspot', 'Mobile hotspot (skipped)');
  m.set('context.wifi.public', 'Public WiFi (skipped)');
  m.set('context.exercise.detected', 'Exercise detected, GPS on');
  m.set('rule.name.rule_vehicle_bt_detected', 'Vehicle BT Driving Mode');
  m.set('rule.name.rule_exercise_heart_rate', 'Exercise Heart Rate Tracking');

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
