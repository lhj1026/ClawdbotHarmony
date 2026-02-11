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
  m.set('chat.playingAudio', '正在播放音频...');
  m.set('chat.audioPlayed', '音频已播放');
  m.set('chat.audioFailed', '音频播放失败');
  m.set('chat.audioReady', '点击播放录音');
  m.set('chat.audioPlaying', '正在播放...');
  m.set('chat.recording', '正在录音...');
  m.set('chat.speechError', '语音识别失败');
  m.set('chat.rateLimited', '免费模型已达到速率限制，请稍后重试。\n\n如需更稳定的服务，请注册自己的 API Key：\n\n📝 OpenRouter 注册步骤：\n1. 打开 openrouter.ai 并点击注册\n2. 使用 Google 账号或邮箱注册\n3. 注册后进入 openrouter.ai/settings/keys\n4. 点击 "Create Key" 创建一个新密钥\n5. 复制密钥，回到本 App 的设置页\n6. 在 "AI 提供商" 选择 OpenRouter\n7. 将密钥粘贴到 "API Key" 输入框\n\n💡 OpenRouter 提供免费和付费模型，注册后免费额度更高，也可按需充值使用 GPT-4o、Claude 等高级模型。');
  m.set('chat.ttsReading', '🔊 正在朗读...');
  m.set('chat.ttsReadDone', '🔊 已朗读');
  m.set('chat.ttsReadFailed', '朗读失败');

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
  m.set('settings.caps', '节点能力');
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

  // LoginPage
  m.set('login.signUpTitle', '首次配置');
  m.set('login.signInTitle', '登录');
  m.set('login.address', '网关地址');
  m.set('login.addressPlaceholder', '192.168.1.100:18789');
  m.set('login.token', '令牌');
  m.set('login.tokenPlaceholder', '管理员分配的共享令牌');
  m.set('login.setPassword', '设置密码');
  m.set('login.setPasswordPlaceholder', '设置登录密码');
  m.set('login.confirmPassword', '确认密码');
  m.set('login.confirmPasswordPlaceholder', '再次输入密码');
  m.set('login.password', '密码');
  m.set('login.passwordPlaceholder', '输入登录密码');
  m.set('login.signUpButton', '注册并连接');
  m.set('login.signInButton', '登录');
  m.set('login.connecting', '连接中...');
  m.set('login.switchToSignIn', '已有密码？直接登录');
  m.set('login.switchToSignUp', '重新配置网关');
  m.set('login.error.emptyAddress', '请输入网关地址');
  m.set('login.error.emptyToken', '请输入令牌');
  m.set('login.error.emptyPassword', '请输入密码');
  m.set('login.error.passwordMismatch', '两次输入的密码不一致');
  m.set('login.error.wrongPassword', '密码错误');
  m.set('login.error.authFailed', '认证失败，请检查令牌');
  m.set('login.error.connectionFailed', '连接失败，请检查地址');
  m.set('login.error.timeout', '连接超时，请检查网络');

  // Settings - Logout
  m.set('settings.logout', '退出登录');
  m.set('settings.logoutConfirmTitle', '退出登录');
  m.set('settings.logoutConfirmMessage', '退出后需要重新输入密码登录，确定退出？');
  m.set('settings.cancel', '取消');
  m.set('settings.confirm', '确定');
  m.set('settings.gatewayAddress', '网关地址');

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
  m.set('chat.playingAudio', 'Playing audio...');
  m.set('chat.audioPlayed', 'Audio played');
  m.set('chat.audioFailed', 'Audio playback failed');
  m.set('chat.audioReady', 'Tap to play recording');
  m.set('chat.audioPlaying', 'Playing...');
  m.set('chat.recording', 'Recording...');
  m.set('chat.speechError', 'Speech recognition failed');
  m.set('chat.rateLimited', 'Free model rate limited. Please retry shortly.\n\nFor stable service, register your own API Key:\n\n📝 OpenRouter Registration:\n1. Go to openrouter.ai and sign up\n2. Register with Google or email\n3. After sign-up, go to openrouter.ai/settings/keys\n4. Click "Create Key" to generate a new key\n5. Copy the key, then open Settings in this app\n6. Select "OpenRouter" as AI Provider\n7. Paste the key into the "API Key" field\n\n💡 OpenRouter offers free and paid models. After registration you get higher free limits, and can top up to use premium models like GPT-4o, Claude, etc.');
  m.set('chat.ttsReading', '🔊 Reading aloud...');
  m.set('chat.ttsReadDone', '🔊 Read aloud');
  m.set('chat.ttsReadFailed', 'TTS read failed');

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

  // LoginPage
  m.set('login.signUpTitle', 'First-time Setup');
  m.set('login.signInTitle', 'Sign In');
  m.set('login.address', 'Gateway Address');
  m.set('login.addressPlaceholder', '192.168.1.100:18789');
  m.set('login.token', 'Token');
  m.set('login.tokenPlaceholder', 'Shared token from admin');
  m.set('login.setPassword', 'Set Password');
  m.set('login.setPasswordPlaceholder', 'Set a login password');
  m.set('login.confirmPassword', 'Confirm Password');
  m.set('login.confirmPasswordPlaceholder', 'Enter password again');
  m.set('login.password', 'Password');
  m.set('login.passwordPlaceholder', 'Enter your password');
  m.set('login.signUpButton', 'Register & Connect');
  m.set('login.signInButton', 'Sign In');
  m.set('login.connecting', 'Connecting...');
  m.set('login.switchToSignIn', 'Already set up? Sign in');
  m.set('login.switchToSignUp', 'Reconfigure gateway');
  m.set('login.error.emptyAddress', 'Please enter gateway address');
  m.set('login.error.emptyToken', 'Please enter token');
  m.set('login.error.emptyPassword', 'Please enter password');
  m.set('login.error.passwordMismatch', 'Passwords do not match');
  m.set('login.error.wrongPassword', 'Wrong password');
  m.set('login.error.authFailed', 'Authentication failed, check token');
  m.set('login.error.connectionFailed', 'Connection failed, check address');
  m.set('login.error.timeout', 'Connection timed out, check network');

  // Settings - Logout
  m.set('settings.logout', 'Logout');
  m.set('settings.logoutConfirmTitle', 'Logout');
  m.set('settings.logoutConfirmMessage', 'You will need to re-enter password to login. Are you sure?');
  m.set('settings.cancel', 'Cancel');
  m.set('settings.confirm', 'Confirm');
  m.set('settings.gatewayAddress', 'Gateway Address');

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
