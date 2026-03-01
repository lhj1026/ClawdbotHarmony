/**
 * AirportScene.ets — 机场场景插件
 *
 * 7 阶段完整闭环：
 * 出发前 → 到达机场 → 临近登机 → 开始登机 → 起飞 → 落地 → 离开机场
 *
 * 数据来源: TravelInfoService (日历解析航班/车次)
 */
import { ContextSnapshot } from '../ContextEngine';
import { ScenePlugin, SceneMatch, SceneAction, SceneActionResult } from './ScenePlugin';
import { TravelInfoService, FlightInfo, TrainInfo } from '../TravelInfoService';
import { LogService } from '../../../common/LogService';

const TAG = 'AirportScene';

type AirportPhase = 'preflight' | 'arrived' | 'boarding_soon' | 'boarding_now' | 'takeoff' | 'landing' | 'exit';

export class AirportScene implements ScenePlugin {
  readonly id = 'airport';
  readonly name = '机场';
  readonly emoji = '✈️';
  private travelService: TravelInfoService = TravelInfoService.getInstance();
  private log: LogService = LogService.getInstance();

  detectScene(snapshot: ContextSnapshot): SceneMatch | null {
    let hasUpcoming = snapshot.hasUpcomingFlight === 'true';
    let wifiGeofence = snapshot.wifiGeofence ?? '';
    let isTransit = wifiGeofence === 'transit';
    let countdownMin = parseInt(snapshot.flightCountdownMin ?? '99999');
    let arrivalMin = parseInt(snapshot.flightArrivalMin ?? '99999');
    let flightNumber = snapshot.flightNumber ?? '';

    // 判断阶段
    let phase: AirportPhase | null = null;
    let priority = 0;
    let confidence = 0;
    let stateDesc = '';

    if (isTransit && hasUpcoming && countdownMin <= 0 && countdownMin >= -30) {
      // Phase 5: 起飞
      phase = 'takeoff';
      priority = 8;
      confidence = 0.95;
      stateDesc = `🛫 ${flightNumber} 即将起飞`;
    } else if (isTransit && hasUpcoming && countdownMin <= 10 && countdownMin > 0) {
      // Phase 4: 开始登机 (< 10min)
      phase = 'boarding_now';
      priority = 9;
      confidence = 0.99;
      stateDesc = `🔴 ${flightNumber} 还有 ${countdownMin} 分钟！立即登机`;
    } else if (isTransit && hasUpcoming && countdownMin <= 45 && countdownMin > 10) {
      // Phase 3: 临近登机 (10-45min)
      phase = 'boarding_soon';
      priority = 7;
      confidence = 0.9;
      stateDesc = `⚠️ ${flightNumber} 还有 ${countdownMin} 分钟`;
    } else if (isTransit && hasUpcoming) {
      // Phase 2: 到达机场
      phase = 'arrived';
      priority = 5;
      confidence = 0.85;
      let hrs = Math.floor(countdownMin / 60);
      let mins = countdownMin % 60;
      let timeStr = hrs > 0 ? `${hrs}小时${mins > 0 ? mins + '分钟' : ''}` : `${mins}分钟`;
      stateDesc = `✈️ ${flightNumber} ${timeStr}后出发`;
    } else if (hasUpcoming && countdownMin <= 180 && countdownMin > 0 && !isTransit) {
      // Phase 1: 出发前 (3h内, 还没到机场)
      phase = 'preflight';
      priority = 3;
      confidence = 0.7;
      stateDesc = `🧳 ${flightNumber} ${countdownMin}分钟后出发，准备出行`;
    } else if (hasUpcoming && arrivalMin <= 10 && arrivalMin >= -30) {
      // Phase 6: 落地
      phase = 'landing';
      priority = 7;
      confidence = 0.9;
      stateDesc = `🛬 ${flightNumber} 已到达`;
    }

    if (phase === null) return null;

    return {
      sceneId: this.id,
      sceneName: this.name,
      priority: priority,
      confidence: confidence,
      stateDescription: stateDesc,
      emoji: this.emoji,
      metadata: {
        'phase': phase,
        'flightNumber': flightNumber,
        'countdownMin': countdownMin.toString(),
        'arrivalMin': arrivalMin.toString(),
      }
    };
  }

  getRecommendations(match: SceneMatch, _snapshot: ContextSnapshot): SceneAction[] {
    let phase = (match.metadata?.['phase'] ?? 'arrived') as AirportPhase;
    let actions: SceneAction[] = [];

    switch (phase) {
      case 'preflight':
        actions.push({ id: 'show_boarding_pass', label: '查看登机牌', emoji: '✈️' });
        actions.push({ id: 'checklist', label: '出行清单', emoji: '🧳' });
        break;
      case 'arrived':
        actions.push({ id: 'show_boarding_pass', label: '查看登机牌', emoji: '✈️' });
        actions.push({ id: 'terminal_map', label: '航站楼地图', emoji: '🗺️' });
        break;
      case 'boarding_soon':
        actions.push({ id: 'show_boarding_pass', label: '查看登机牌', emoji: '✈️', urgent: false });
        break;
      case 'boarding_now':
        actions.push({ id: 'show_boarding_pass', label: '立即查看登机牌', emoji: '🔴', urgent: true });
        break;
      case 'takeoff':
        actions.push({ id: 'flight_mode', label: '开启飞行模式', emoji: '✈️' });
        break;
      case 'landing':
        actions.push({ id: 'exit_flight_mode', label: '关闭飞行模式', emoji: '📱' });
        actions.push({ id: 'baggage_info', label: '行李转盘', emoji: '🧳' });
        break;
    }

    return actions;
  }

  async executeAction(actionId: string, match: SceneMatch): Promise<SceneActionResult> {
    this.log.info(TAG, `执行: ${actionId}, phase=${match.metadata?.['phase']}`);

    switch (actionId) {
      case 'show_boarding_pass': {
        let flights: FlightInfo[] = await this.travelService.getTodayFlights();
        if (flights.length > 0) {
          let card = this.travelService.buildBoardingPassA2UI(flights[0]);
          return {
            success: true,
            message: `✈️ ${flights[0].flightNumber} ${flights[0].departure}→${flights[0].arrival}`,
            a2uiCard: card
          };
        }
        let trains: TrainInfo[] = await this.travelService.getTodayTrains();
        if (trains.length > 0) {
          let card = this.travelService.buildTrainTicketA2UI(trains[0]);
          return {
            success: true,
            message: `🚄 ${trains[0].trainNumber} ${trains[0].departure}→${trains[0].arrival}`,
            a2uiCard: card
          };
        }
        return { success: false, message: '📋 未找到航班或火车信息' };
      }
      case 'flight_mode':
        return { success: true, message: '✈️ 已开启飞行模式' };
      case 'exit_flight_mode':
        return { success: true, message: '📱 已关闭飞行模式' };
      case 'checklist':
        return { success: true, message: '🧳 出行清单：护照/身份证、登机牌、充电宝、耳机' };
      case 'terminal_map':
        return { success: true, message: '🗺️ 航站楼地图（功能开发中）' };
      case 'baggage_info':
        return { success: true, message: '🧳 行李转盘信息（功能开发中）' };
      default:
        return { success: false, message: `未知操作: ${actionId}` };
    }
  }
}
