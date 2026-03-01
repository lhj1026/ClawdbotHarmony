/**
 * SmartActionPlugin — 智能功能执行插件
 *
 * 处理带 function 标签的动作，通过鸿蒙本机 API 执行：
 * - morning_briefing: 晨间播报（日程+天气）
 * - calendar_summary: 今日日程摘要
 * - calendar_tomorrow: 明日日程预览
 * - open_app:<target>: 打开指定应用
 */
import { UserAction, ActionType } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';
import { CalendarPlugin, EventInfo, EventConflict } from '../plugins/CalendarPlugin';
import { LogService } from '../../../common/LogService';
import { http } from '@kit.NetworkKit';

const TAG = 'SmartActionPlugin';

export class SmartActionPlugin implements ActionPlugin {
  readonly name = 'SmartActionPlugin';
  readonly supportedTypes: ActionType[] = ['show_notification', 'show_info', 'quick_action'];

  private calendarPlugin: CalendarPlugin | undefined;

  /** 设置日历插件引用 */
  setCalendarPlugin(plugin: CalendarPlugin | undefined): void {
    this.calendarPlugin = plugin;
  }

  canHandle(action: UserAction): boolean {
    let func = action.params?.['function'] ?? '';
    return func.length > 0;
  }

  async execute(action: UserAction): Promise<ActionResult> {
    let log = LogService.getInstance();
    let func = action.params?.['function'] ?? '';

    if (func.length === 0) {
      return { success: false, message: '⚠️ 未指定功能', actionType: action.type };
    }

    log.info(TAG, `执行功能: ${func}`);

    // open_app:<target> 特殊处理（由 AppLaunchPlugin 接管更好，这里 fallback）
    if (func.startsWith('open_app:')) {
      let appTarget = func.substring(9);
      return { success: true, message: `🚀 正在打开 ${appTarget}...`, actionType: 'open_app' };
    }

    switch (func) {
      case 'morning_briefing':
        return await this.morningBriefing();
      case 'calendar_summary':
        return await this.calendarSummary(24); // 今天+明天早上
      case 'calendar_tomorrow':
        return await this.calendarSummary(36); // 往后36小时覆盖明天
      default:
        log.warn(TAG, `未知功能: ${func}`);
        let message = action.target ?? '通知已发送';
        return { success: true, message: message, actionType: action.type };
    }
  }

  /** 晨间播报：日程 + 天气 */
  private async morningBriefing(): Promise<ActionResult> {
    let log = LogService.getInstance();
    let parts: string[] = [];

    // 1. 日程
    let calText = await this.getCalendarText(16);
    parts.push(calText);

    // 2. 天气（Open-Meteo API，免费无 key）
    let weatherText = await this.getWeatherText();
    parts.push(weatherText);

    let briefing = '🌅 *晨间播报*\n\n' + parts.join('\n\n');
    log.info(TAG, `晨间播报生成完成，长度=${briefing.length}`);

    return { success: true, message: briefing, actionType: 'morning_briefing' };
  }

  /** 日程摘要 */
  private async calendarSummary(hoursAhead: number): Promise<ActionResult> {
    let calText = await this.getCalendarText(hoursAhead);
    return { success: true, message: calText, actionType: 'calendar_summary' };
  }

  /** 获取日历文本 */
  private async getCalendarText(hoursAhead: number): Promise<string> {
    let log = LogService.getInstance();
    if (!this.calendarPlugin) {
      return '📅 日历未授权，无法获取日程';
    }
    try {
      let events: EventInfo[] = await this.calendarPlugin.getUpcomingEvents(hoursAhead);
      let conflicts: EventConflict[] = this.calendarPlugin.findConflicts(events);
      return this.calendarPlugin.formatEventsMarkdown(events, conflicts);
    } catch (err) {
      log.warn(TAG, `获取日程失败: ${(err as Error).message}`);
      return '📅 获取日程失败';
    }
  }

  /** 获取天气文本（Open-Meteo API） */
  private async getWeatherText(): Promise<string> {
    let log = LogService.getInstance();
    try {
      // 默认温哥华坐标，TODO: 从 GPS 获取当前位置
      let lat = 49.2827;
      let lon = -123.1207;

      let url = `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}` +
        `&current=temperature_2m,relative_humidity_2m,apparent_temperature,weather_code,wind_speed_10m` +
        `&daily=temperature_2m_max,temperature_2m_min,weather_code,precipitation_probability_max` +
        `&timezone=America/Vancouver&forecast_days=1`;

      let request = http.createHttp();
      let response = await request.request(url, {
        method: http.RequestMethod.GET,
        header: { 'User-Agent': 'ClawdBotHarmony/1.0' },
        connectTimeout: 8000,
        readTimeout: 8000,
      });
      request.destroy();

      if (response.responseCode !== 200) {
        return '🌤️ 天气获取失败';
      }

      let data = JSON.parse(response.result as string) as Record<string, Object>;
      let current = data['current'] as Record<string, Object>;
      let daily = data['daily'] as Record<string, Object>;

      let temp = Number(current['temperature_2m'] ?? 0);
      let feelsLike = Number(current['apparent_temperature'] ?? 0);
      let humidity = Number(current['relative_humidity_2m'] ?? 0);
      let windSpeed = Number(current['wind_speed_10m'] ?? 0);
      let weatherCode = Number(current['weather_code'] ?? 0);

      let maxTemps = daily['temperature_2m_max'] as number[];
      let minTemps = daily['temperature_2m_min'] as number[];
      let precipProbs = daily['precipitation_probability_max'] as number[];

      let weatherDesc = this.weatherCodeToDesc(weatherCode);
      let rainProb = precipProbs && precipProbs.length > 0 ? precipProbs[0] : 0;
      let maxTemp = maxTemps && maxTemps.length > 0 ? maxTemps[0] : temp;
      let minTemp = minTemps && minTemps.length > 0 ? minTemps[0] : temp;

      let lines: string[] = [];
      lines.push(`🌤️ *今日天气* — ${weatherDesc}`);
      lines.push(`🌡️ 当前 ${temp.toFixed(1)}°C（体感 ${feelsLike.toFixed(1)}°C）`);
      lines.push(`📊 ${minTemp.toFixed(0)}°C ~ ${maxTemp.toFixed(0)}°C`);
      lines.push(`💧 湿度 ${humidity}%  🌬️ 风速 ${windSpeed.toFixed(0)} km/h`);
      if (rainProb > 20) {
        lines.push(`🌧️ 降水概率 ${rainProb}%，建议带伞`);
      }

      return lines.join('\n');
    } catch (err) {
      log.warn(TAG, `天气API调用失败: ${(err as Error).message}`);
      return '🌤️ 天气信息暂时无法获取';
    }
  }

  /** WMO 天气码 → 中文描述 */
  private weatherCodeToDesc(code: number): string {
    if (code === 0) return '☀️ 晴';
    if (code <= 3) return '⛅ 多云';
    if (code <= 49) return '🌫️ 雾';
    if (code <= 59) return '🌧️ 小雨';
    if (code <= 69) return '🌧️ 雨';
    if (code <= 79) return '🌨️ 雪';
    if (code <= 82) return '🌧️ 阵雨';
    if (code <= 86) return '🌨️ 阵雪';
    if (code >= 95) return '⛈️ 雷暴';
    return '🌤️ 未知';
  }

  getDisplayInfo(action: UserAction): ActionDisplayInfo {
    let func = action.params?.['function'] ?? '';
    switch (func) {
      case 'morning_briefing': return { title: '晨间播报', emoji: '🌅' };
      case 'calendar_summary': return { title: '今日日程', emoji: '📅' };
      case 'calendar_tomorrow': return { title: '明日日程', emoji: '📅' };
      default: return { title: action.target ?? '执行', emoji: '⚡' };
    }
  }
}
