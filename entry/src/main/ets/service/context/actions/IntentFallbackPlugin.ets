/**
 * IntentFallbackPlugin — 意图关键词兜底插件
 *
 * 处理无 function 标签的 suggestion 类推荐（包括 LLM 生成的规则）。
 * 根据 target 文本中的意图关键词匹配，构建 Want 打开对应 App。
 * 两级策略：地图类先尝试 implicit Want，失败后 fallback 到 explicit bundleName。
 */
import { UserAction, ActionType } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';
import { LogService } from '../../../common/LogService';
import { common, Want } from '@kit.AbilityKit';

const TAG = 'IntentFallbackPlugin';

interface IntentMapping {
  keywords: string[];
  label: string;
  emoji: string;
  bundleName: string;
  implicitUri?: string;  // 如果有，先尝试 implicit Want
}

const INTENT_MAPPINGS: IntentMapping[] = [
  {
    keywords: ['餐厅', '美食', '附近', '餐馆', '吃饭', '饭店', '外卖'],
    label: '地图搜索',
    emoji: '🗺️',
    bundleName: 'com.huawei.hmos.maps',
    implicitUri: 'geo:0,0?q=餐厅'
  },
  {
    keywords: ['路线', '导航', '回家', '怎么走'],
    label: '地图导航',
    emoji: '🧭',
    bundleName: 'com.huawei.hmos.maps',
    implicitUri: 'geo:0,0?q=导航'
  },
  {
    keywords: ['天气', '温度', '下雨'],
    label: '天气',
    emoji: '🌤️',
    bundleName: 'com.huawei.hmos.weather'
  },
  {
    keywords: ['音乐', '歌', '播放', '听', '播客'],
    label: '音乐',
    emoji: '🎵',
    bundleName: 'com.huawei.hmos.music'
  },
  {
    keywords: ['日历', '日程', '会议', '待办'],
    label: '日历',
    emoji: '📅',
    bundleName: 'com.huawei.hmos.calendar'
  },
  {
    keywords: ['闹钟', '提醒', '定时'],
    label: '时钟',
    emoji: '⏰',
    bundleName: 'com.huawei.hmos.clock'
  },
  {
    keywords: ['运动', '步数', '健康', '锻炼'],
    label: '运动健康',
    emoji: '💪',
    bundleName: 'com.huawei.hmos.health'
  }
];

export class IntentFallbackPlugin implements ActionPlugin {
  readonly name = 'IntentFallbackPlugin';
  readonly supportedTypes: ActionType[] = ['show_notification', 'show_info', 'quick_action'];
  private context: common.UIAbilityContext | undefined;
  private log: LogService = LogService.getInstance();

  setContext(context: common.UIAbilityContext): void {
    this.context = context;
  }

  canHandle(action: UserAction): boolean {
    // 仅在无 function 标签时接管
    let func = action.params?.['function'] ?? '';
    if (func.length > 0) return false;

    // target 文本包含已知意图关键词
    let target = action.target ?? '';
    return this.matchIntent(target) !== undefined;
  }

  async execute(action: UserAction): Promise<ActionResult> {
    let target = action.target ?? '';
    let mapping = this.matchIntent(target);

    if (!mapping) {
      return { success: false, message: '⚠️ 未匹配到意图', actionType: action.type };
    }

    if (!this.context) {
      this.log.warn(TAG, 'UIAbilityContext not set');
      return { success: false, message: '⚠️ 无法打开应用（上下文未初始化）', actionType: action.type };
    }

    this.log.info(TAG, `意图匹配: "${target}" → ${mapping.label} (${mapping.bundleName})`);

    // 两级 Want 策略
    if (mapping.implicitUri) {
      try {
        let implicitWant: Want = {
          action: 'ohos.want.action.viewData',
          uri: mapping.implicitUri
        };
        await this.context.startAbility(implicitWant);
        return {
          success: true,
          message: `${mapping.emoji} 已打开${mapping.label}`,
          actionType: 'intent_fallback'
        };
      } catch (err) {
        this.log.info(TAG, `Implicit Want 失败，fallback 到 explicit: ${(err as Error).message}`);
      }
    }

    // Explicit bundleName fallback
    try {
      let explicitWant: Want = {
        bundleName: mapping.bundleName,
        action: 'ohos.want.action.home'
      };
      await this.context.startAbility(explicitWant);
      return {
        success: true,
        message: `${mapping.emoji} 已打开${mapping.label}`,
        actionType: 'intent_fallback'
      };
    } catch (err) {
      this.log.warn(TAG, `打开 ${mapping.bundleName} 失败: ${(err as Error).message}`);
      return {
        success: false,
        message: `⚠️ 无法打开${mapping.label}: ${(err as Error).message}`,
        actionType: 'intent_fallback'
      };
    }
  }

  getDisplayInfo(action: UserAction): ActionDisplayInfo {
    let target = action.target ?? '';
    let mapping = this.matchIntent(target);
    return {
      title: mapping ? `打开${mapping.label}` : '执行操作',
      emoji: mapping?.emoji ?? '🚀'
    };
  }

  private matchIntent(text: string): IntentMapping | undefined {
    for (let i = 0; i < INTENT_MAPPINGS.length; i++) {
      let mapping = INTENT_MAPPINGS[i];
      for (let j = 0; j < mapping.keywords.length; j++) {
        if (text.indexOf(mapping.keywords[j]) >= 0) {
          return mapping;
        }
      }
    }
    return undefined;
  }
}
