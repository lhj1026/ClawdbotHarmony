/**
 * Rule-based intent classifier.
 * Classifies user messages to determine which tool subsets
 * are needed, reducing unnecessary token usage on cloud API calls.
 */

export interface IntentResult {
  type: string;       // intent category
  skillIds: string[]; // skill IDs whose tools should be included
}

interface IntentRule {
  type: string;
  skillIds: string[];
  keywords: string[];
}

// Keyword lists per intent (Chinese + English, lowercase)
const INTENT_RULES: IntentRule[] = [
  // Check specific intents first (order matters — more specific before general)
  {
    type: 'email',
    skillIds: ['skill_email'],
    keywords: ['邮件', '邮箱', '收件箱', '未读邮件', '新邮件', '查邮件', '看邮件', '发邮件', '写邮件', '发送邮件',
      'email', 'inbox', 'mail', 'send mail', 'compose email', 'check email', 'read email'],
  },
  {
    type: 'calendar',
    skillIds: ['skill_calendar'],
    keywords: ['日程', '日历', '提醒我', '提醒一下', '设个提醒', '会议', '开会', '日历事件', '创建日历', '添加日历',
      'calendar', 'remind me', 'set reminder', 'create event', 'add event', 'schedule meeting', 'meeting'],
  },
  {
    type: 'media',
    skillIds: ['skill_media'],
    keywords: ['拍照', '照相', '拍一张', '拍张照', '自拍', '拍个照', '录音', '录一段', '录个音', '录制',
      'take photo', 'take a photo', 'capture photo', 'take picture', 'selfie', 'record audio', 'record sound'],
  },
  {
    type: 'smart_home',
    skillIds: ['skill_smart_home'],
    keywords: ['智能设备', '智能家居', '家电', '设备列表', '开灯', '关灯', '空调', '风扇', '电视',
      'smart home', 'smart device', 'iot device', 'list devices', 'turn on', 'turn off'],
  },
  {
    type: 'system',
    skillIds: ['skill_system'],
    keywords: ['截屏', '截图', '屏幕截图', '截个屏', '截个图',
      '读文件', '写文件', '文件列表', '查找文件', '选文件',
      '我在哪', '我的位置', '当前位置', '定位', '经纬度',
      'screenshot', 'screen capture', 'read file', 'write file', 'list files',
      'my location', 'where am i', 'gps', 'coordinates'],
  },
  {
    type: 'scheduler',
    skillIds: ['skill_scheduler'],
    keywords: ['定时', '计划任务', '定期', '每隔', '取消任务',
      'scheduled task', 'cron', 'cancel task'],
  },
  {
    type: 'skill_mgmt',
    skillIds: ['skill_management'],
    keywords: ['创建技能', '技能列表', '删除技能', '更新技能', '我的技能', '添加技能',
      'create skill', 'list skill', 'delete skill', 'update skill', 'my skills'],
  },
  {
    type: 'search',
    skillIds: ['skill_web'],
    keywords: ['搜索', '搜一下', '查一下', '查询', '百度', '谷歌',
      '打开网页', '打开网站', '浏览网页', '访问',
      'search', 'google', 'look up', 'find out',
      'open website', 'open webpage', 'browse'],
  },
];

// Chitchat patterns — greetings, thanks, meta questions
const CHITCHAT_KEYWORDS: string[] = [
  '你好', 'hello', 'hi', '嗨', 'hey', '早上好', '晚上好', '早安', '晚安',
  'good morning', 'good night', 'good evening', 'good afternoon',
  '谢谢', '感谢', 'thanks', 'thank you', 'thx',
  '再见', '拜拜', 'bye', 'goodbye', 'see you',
  '你是谁', '你叫什么', 'who are you', 'what is your name',
  '你能做什么', '你会什么', 'what can you do',
];

// Recurring schedule patterns like "每天 9点", "每小时", "every 30m"
const SCHEDULE_REGEX = /每\d+[分秒时天]|每天|每小时|每周|每月|every\s+\d+\s*[mhds]/i;

/**
 * Classify user intent from message text.
 * Returns which skill/tool subsets to include in the API call.
 *
 * @param text      User message text (already trimmed)
 * @param hasMedia  True if user attached images or files
 */
export function classifyIntent(text: string, hasMedia: boolean = false): IntentResult {
  // If media attached, always use general (model needs full context to decide)
  if (hasMedia) {
    return { type: 'general', skillIds: [] };
  }

  let lower = text.toLowerCase();

  // Count how many intent categories match
  let matches: IntentRule[] = [];
  for (let rule of INTENT_RULES) {
    for (let kw of rule.keywords) {
      if (lower.includes(kw)) {
        matches.push(rule);
        break; // one match per rule is enough
      }
    }
  }

  // Check scheduler regex separately
  if (SCHEDULE_REGEX.test(lower)) {
    let hasScheduler = matches.some(m => m.type === 'scheduler');
    if (!hasScheduler) {
      let schedulerRule = INTENT_RULES.find(r => r.type === 'scheduler');
      if (schedulerRule) {
        matches.push(schedulerRule);
      }
    }
  }

  // Multiple intents detected → general (ambiguous)
  if (matches.length > 1) {
    return { type: 'general', skillIds: [] };
  }

  // Single intent → use that category
  if (matches.length === 1) {
    return { type: matches[0].type, skillIds: matches[0].skillIds };
  }

  // No tool intent detected — check if it's chitchat
  for (let kw of CHITCHAT_KEYWORDS) {
    if (lower.includes(kw)) {
      return { type: 'chitchat', skillIds: [] };
    }
  }

  // Short messages without tool keywords are likely chitchat
  if (text.length <= 8) {
    return { type: 'chitchat', skillIds: [] };
  }

  // Fallback: general (send all tools)
  return { type: 'general', skillIds: [] };
}
