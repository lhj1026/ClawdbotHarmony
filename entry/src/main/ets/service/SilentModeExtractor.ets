// SilentMode Key Information Extractor
// Extracts time, location, person, event, and plan info from transcribed text

import { ExtractedInfo, TimeInfo, LocationInfo, PersonInfo, EventInfo, PlanInfo } from '../model/Models';
import { LogService } from '../common/LogService';

export class SilentModeExtractor {
  private static instance: SilentModeExtractor;
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'SilentExtractor';

  private constructor() {}

  static getInstance(): SilentModeExtractor {
    if (!SilentModeExtractor.instance) {
      SilentModeExtractor.instance = new SilentModeExtractor();
    }
    return SilentModeExtractor.instance;
  }

  extract(text: string): ExtractedInfo {
    let result: ExtractedInfo = {
      times: [],
      locations: [],
      persons: [],
      events: [],
      plans: []
    };

    if (!text || text.trim().length === 0) {
      return result;
    }

    result.times = this.extractTime(text);
    result.locations = this.extractLocation(text);
    result.persons = this.extractPerson(text);
    result.events = this.extractEvent(text);
    result.plans = this.extractPlan(text);

    return result;
  }

  private extractTime(text: string): TimeInfo[] {
    let times: TimeInfo[] = [];
    
    // 相对时间
    let relativePatterns: string[] = ['今天', '明天', '后天', '大后天', '昨天', '前天', '下周', '上周', '这周', '周末'];
    for (let pattern of relativePatterns) {
      if (text.includes(pattern)) {
        times.push({ raw: pattern, normalized: pattern, type: 'relative' });
      }
    }
    
    // 具体时间 - 简化版本
    let hourMatch = text.match(/(\d{1,2})[点时半]/);
    if (hourMatch) {
      times.push({ raw: hourMatch[0], normalized: hourMatch[1] + ':00', type: 'time' });
    }
    
    return times;
  }

  private extractLocation(text: string): LocationInfo[] {
    let locations: LocationInfo[] = [];
    
    // 常见地点关键词
    let placeKeywords: string[] = [
      '公司', '单位', '办公室', '会议室', '家', '家里', '学校', '医院', '银行', '超市', 
      '商场', '餐厅', '饭店', '咖啡', '星巴克', '麦当劳', '肯德基', '机场', '火车站', 
      '地铁站', '公交站', '公园', '健身房', '电影院'
    ];
    
    for (let keyword of placeKeywords) {
      if (text.includes(keyword)) {
        locations.push({ raw: keyword, normalized: keyword, type: 'place', confidence: 0.8 });
      }
    }
    
    return locations;
  }

  private extractPerson(text: string): PersonInfo[] {
    let persons: PersonInfo[] = [];
    
    // 亲属称呼
    let familyTerms: string[] = ['爸爸', '妈妈', '爷爷', '奶奶', '外公', '外婆', '哥哥', '姐姐', '弟弟', '妹妹', '叔叔', '阿姨', '舅舅', '姑姑', '老婆', '老公', '儿子', '女儿'];
    for (let term of familyTerms) {
      if (text.includes(term)) {
        persons.push({ raw: term, normalized: term, confidence: 0.95, role: 'family' });
      }
    }
    
    // 职务称呼
    let titlePatterns: string[] = ['总', '经理', '老板', '老师', '医生', '师傅', '主任', '教授'];
    for (let title of titlePatterns) {
      if (text.includes(title)) {
        let idx = text.indexOf(title);
        if (idx > 0) {
          let name = text.substring(Math.max(0, idx - 2), idx + title.length);
          persons.push({ raw: name, normalized: name, confidence: 0.85, role: 'professional' });
        }
      }
    }
    
    return persons;
  }

  private extractEvent(text: string): EventInfo[] {
    let events: EventInfo[] = [];
    
    let eventKeywords: string[][] = [
      ['开会', '会议', '讨论', '汇报'],
      ['吃饭', '聚餐', '请客', '约饭'],
      ['面试', '笔试', '考试', '答辩'],
      ['培训', '讲座', '学习', '上课'],
      ['出差', '旅行', '旅游'],
      ['看病', '体检', '挂号'],
      ['签约', '合同'],
      ['打电话', '通话', '视频', '电话会议'],
      ['健身', '运动', '跑步', '游泳', '瑜伽'],
      ['生日', '庆祝', '派对', '聚会'],
    ];
    let eventTypes: string[] = ['meeting', 'dining', 'interview', 'training', 'travel', 'medical', 'contract', 'call', 'exercise', 'celebration'];
    
    for (let i = 0; i < eventKeywords.length; i++) {
      for (let keyword of eventKeywords[i]) {
        if (text.includes(keyword)) {
          events.push({ type: eventTypes[i], keyword: keyword, confidence: 0.8, context: '' });
          break;
        }
      }
    }
    
    return events;
  }

  private extractPlan(text: string): PlanInfo[] {
    let plans: PlanInfo[] = [];
    
    // 计划关键词
    let planPatterns: string[] = ['打算', '准备', '计划', '想', '要', '需要', '即将', '想买', '打算买', '想学', '想去'];
    for (let pattern of planPatterns) {
      let idx = text.indexOf(pattern);
      if (idx >= 0) {
        let content = text.substring(idx + pattern.length, Math.min(text.length, idx + pattern.length + 20));
        // 简单截取到标点
        let endIdx = content.search(/[，。！？\s]/);
        if (endIdx > 0) {
          content = content.substring(0, endIdx);
        }
        if (content.length >= 2) {
          plans.push({ type: 'intent', content: content, confidence: 0.8, raw: pattern + content });
        }
      }
    }
    
    return plans;
  }

  hasImportantInfo(info: ExtractedInfo): boolean {
    return info.times.length > 0 || info.locations.length > 0 || info.persons.length > 0 || info.events.length > 0 || info.plans.length > 0;
  }

  formatForDisplay(info: ExtractedInfo): string {
    let parts: string[] = [];
    if (info.times.length > 0) parts.push('时间: ' + info.times.map(t => t.raw).join(', '));
    if (info.locations.length > 0) parts.push('地点: ' + info.locations.map(l => l.raw).join(', '));
    if (info.persons.length > 0) parts.push('人物: ' + info.persons.map(p => p.raw).join(', '));
    if (info.events.length > 0) parts.push('事件: ' + info.events.map(e => e.keyword).join(', '));
    if (info.plans.length > 0) parts.push('计划: ' + info.plans.map(p => p.content).join(', '));
    return parts.join('\n');
  }
}
