/**
 * TravelInfoPlugin — 出行信息动作
 *
 * 处理: show_info (target=travel/flight/train)
 * 在交通枢纽场景下显示登机牌/火车票 A2UI 卡片。
 * 数据来源: TravelInfoService（从日历解析航班/车次）
 */
import { UserAction, ActionType } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';
import { TravelInfoService, FlightInfo, TrainInfo } from '../TravelInfoService';
import { LogService } from '../../../common/LogService';

const TAG = 'TravelInfoPlugin';

export class TravelInfoPlugin implements ActionPlugin {
  readonly name = 'TravelInfoPlugin';
  readonly supportedTypes: ActionType[] = ['show_info'];
  private travelService: TravelInfoService;
  private log: LogService = LogService.getInstance();

  constructor() {
    this.travelService = TravelInfoService.getInstance();
  }

  canHandle(action: UserAction): boolean {
    if (action.type !== 'show_info') return false;
    let target = (action.target ?? '').toLowerCase();
    let category = action.params?.['category'] ?? '';
    return target.indexOf('travel') >= 0 || target.indexOf('flight') >= 0 ||
      target.indexOf('train') >= 0 || target.indexOf('登机') >= 0 ||
      target.indexOf('行程') >= 0 || category === 'travel';
  }

  async execute(action: UserAction): Promise<ActionResult> {
    let flights: FlightInfo[] = await this.travelService.getTodayFlights();
    let trains: TrainInfo[] = await this.travelService.getTodayTrains();

    this.log.info(TAG, `查询到 ${flights.length} 个航班, ${trains.length} 个火车`);

    if (flights.length === 0 && trains.length === 0) {
      return {
        success: true,
        message: '📋 未找到近24小时的航班或火车信息。请确认日历中已添加出行事件。',
        actionType: 'travel_info'
      };
    }

    // 构建 A2UI 卡片
    let cards: string[] = [];
    for (let i = 0; i < flights.length; i++) {
      cards.push(this.travelService.buildBoardingPassA2UI(flights[i]));
    }
    for (let i = 0; i < trains.length; i++) {
      cards.push(this.travelService.buildTrainTicketA2UI(trains[i]));
    }

    // 构建文字摘要
    let summaryParts: string[] = [];
    for (let i = 0; i < flights.length; i++) {
      let f = flights[i];
      summaryParts.push(`✈️ ${f.flightNumber} ${f.departure}→${f.arrival}`);
    }
    for (let i = 0; i < trains.length; i++) {
      let t = trains[i];
      summaryParts.push(`🚄 ${t.trainNumber} ${t.departure}→${t.arrival}`);
    }

    return {
      success: true,
      message: `🎫 出行信息\n${summaryParts.join('\n')}`,
      actionType: 'travel_info',
      a2uiCard: cards.join('\n')
    };
  }

  getDisplayInfo(_action: UserAction): ActionDisplayInfo {
    return {
      title: '查看出行信息',
      subtitle: '登机牌 / 火车票',
      emoji: '🎫'
    };
  }
}
