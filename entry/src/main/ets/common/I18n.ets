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
  m.set('chat.placeholder', '向 ClawdBot 提问...');
  m.set('chat.empty.subtitle', '你的私人AI助手。\n随时提问或分配任务。');
  m.set('chat.quick.whatCanYouDo', '你能做什么？');
  m.set('chat.quick.setReminder', '设置提醒');
  m.set('chat.quick.searchWeb', '搜索网页');
  m.set('chat.quick.smartHome', '智能家居状态');
  m.set('chat.toolResult', '结果');

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
  m.set('settings.caps', '节点能力：');
  m.set('settings.capsDetail', '  定位 (GPS)  /  通知');
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
  m.set('chat.placeholder', 'Ask ClawdBot anything...');
  m.set('chat.empty.subtitle', 'Your personal AI assistant.\nAsk me anything or give me a task.');
  m.set('chat.quick.whatCanYouDo', 'What can you do?');
  m.set('chat.quick.setReminder', 'Set a reminder');
  m.set('chat.quick.searchWeb', 'Search the web');
  m.set('chat.quick.smartHome', 'Smart home status');
  m.set('chat.toolResult', 'result');

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
  m.set('settings.caps', 'Node Capabilities:');
  m.set('settings.capsDetail', '  Location (GPS)  /  Notifications');
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
