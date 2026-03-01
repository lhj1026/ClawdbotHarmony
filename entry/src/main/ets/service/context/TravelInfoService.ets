/**
 * TravelInfoService — Parse flight/train info from calendar events
 *
 * Scans upcoming 24h calendar events for flight numbers and train numbers.
 * Provides boarding pass / train ticket A2UI card builders.
 *
 * Flight regex: [A-Z]{2}\d{3,4} | [A-Z]\d{4,5}  (CA123, CZ3456, MU5678)
 * Train regex:  [GCDZTSPKLY]\d{1,4}              (G1234, D5678, K123)
 */
import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { I18n } from '../../common/I18n';

const TAG = 'TravelInfoService';
const LOOKAHEAD_MS = 24 * 60 * 60 * 1000;    // 24 hours ahead
const REFRESH_INTERVAL_MS = 30 * 60 * 1000;   // refresh every 30 min

// Airline: 2 uppercase letters + 3-4 digits, or 1 uppercase letter + 4-5 digits (e.g. AC8001)
const FLIGHT_PATTERN = /([A-Z]{2}\d{3,4}|[A-Z]\d{4,5})/;

// Train: one of G/C/D/Z/T/S/P/K/L/Y followed by 1-4 digits
const TRAIN_PATTERN = /\b([GCDZTSPKLY]\d{1,4})\b/;

/** 航班状态 */
export type FlightStatus = 'scheduled' | 'boarding' | 'departed' | 'arrived' | 'delayed' | 'cancelled';

/** 火车状态 */
export type TrainStatus = 'scheduled' | 'boarding' | 'departed' | 'arrived' | 'delayed';

/** 登机牌信息 */
export interface FlightInfo {
  flightNumber: string;     // e.g. CA123
  departure: string;        // departure city/airport
  arrival: string;          // arrival city/airport
  departureTime: number;    // Unix timestamp (ms)
  gate?: string;            // boarding gate e.g. "B23"
  seat?: string;            // seat e.g. "12C"
  terminal?: string;        // terminal e.g. "T3"
  status: FlightStatus;
  calendarEventId?: string;
  calendarEndTime?: number;   // calendar event end time (Unix ms), used as estimated arrival
}

/** 火车票信息 */
export interface TrainInfo {
  trainNumber: string;      // e.g. G1234
  departure: string;        // departure station
  arrival: string;          // arrival station
  departureTime: number;    // Unix timestamp (ms)
  coach?: string;           // coach/carriage e.g. "03"
  seat?: string;            // seat e.g. "12A"
  checkGate?: string;       // ticket check gate e.g. "8A"
  status: TrainStatus;
  calendarEventId?: string;
}

/** Parsed event data for internal use */
interface ParsedEventData {
  title: string;
  description: string;
  startTime: number;
  endTime: number;
  eventId?: string;
}

export class TravelInfoService {
  private static _instance: TravelInfoService | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private context: common.UIAbilityContext | undefined = undefined;
  private permissionGranted: boolean = false;
  private cachedFlights: FlightInfo[] = [];
  private cachedTrains: TrainInfo[] = [];
  private lastRefresh: number = 0;

  static getInstance(): TravelInfoService {
    if (!TravelInfoService._instance) {
      TravelInfoService._instance = new TravelInfoService();
    }
    return TravelInfoService._instance;
  }

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      let atManager = abilityAccessCtrl.createAtManager();
      let result = await atManager.requestPermissionsFromUser(context, ['ohos.permission.READ_CALENDAR']);
      if (result.authResults.length > 0 && result.authResults[0] === 0) {
        this.permissionGranted = true;
      }
      this.log.info(TAG, `Init: permission=${this.permissionGranted}`);
    } catch (err) {
      this.log.warn(TAG, `Permission request failed: ${(err as Error).message}`);
    }

    if (this.permissionGranted) {
      await this.refresh();
    }
  }

  /** Get today's flights (parsed from calendar, departing in next 24h) */
  async getTodayFlights(): Promise<FlightInfo[]> {
    await this.maybeRefresh();
    return this.cachedFlights;
  }

  /** Get today's trains (parsed from calendar, departing in next 24h) */
  async getTodayTrains(): Promise<TrainInfo[]> {
    await this.maybeRefresh();
    return this.cachedTrains;
  }

  /** Build boarding pass A2UI JSON string */
  buildBoardingPassA2UI(flight: FlightInfo): string {
    let now = Date.now();
    let countdownMs = flight.departureTime - now;
    let countdownStr = this.formatCountdown(countdownMs);
    let isUrgent = countdownMs < 45 * 60 * 1000; // < 45 minutes

    let safeFlight = this.escapeJson(flight.flightNumber);
    let safeDep = this.escapeJson(flight.departure);
    let safeArr = this.escapeJson(flight.arrival);
    let safeCountdown = this.escapeJson(countdownStr);

    let statusEmoji = this.flightStatusEmoji(flight.status);
    let statusLabel = this.escapeJson(I18n.t('travel.flight.status.' + flight.status));

    // Detail line: terminal | gate | seat
    let detailParts: string[] = [];
    if (flight.terminal && flight.terminal.length > 0) {
      detailParts.push(I18n.t('travel.terminal') + ' ' + flight.terminal);
    }
    if (flight.gate && flight.gate.length > 0) {
      detailParts.push(I18n.t('travel.gate') + ' ' + flight.gate);
    }
    if (flight.seat && flight.seat.length > 0) {
      detailParts.push(I18n.t('travel.seat') + ' ' + flight.seat);
    }
    let detailStr = detailParts.join(' | ');
    let safeDetail = this.escapeJson(detailStr);

    let departureTimeStr = this.formatTime(flight.departureTime);
    let countdownColor = isUrgent ? '#F44336' : '#2196F3';

    let ts = Date.now().toString();
    let safeDismissId = this.escapeJson(flight.flightNumber);

    let children = `{"type":"text","text":"✈️ ${I18n.t('travel.boarding.title')}","style":{"fontSize":20,"fontWeight":"bold"}},` +
      `{"type":"text","text":"${safeFlight}  ${statusEmoji} ${statusLabel}","style":{"fontSize":18}},` +
      `{"type":"text","text":"${safeDep} → ${safeArr}","style":{"fontSize":16,"fontWeight":"medium"}},` +
      `{"type":"text","text":"🕐 ${departureTimeStr}  ⏰ ${safeCountdown}","style":{"fontSize":14,"color":"${countdownColor}"}}`
      + (safeDetail.length > 0 ? `,"type":"text","text":"${safeDetail}","style":{"fontSize":13,"color":"#666"}` : '')
      + `,"type":"button","text":"✅ ${I18n.t('travel.dismiss')}","variant":"borderless","action":{"event":{"name":"travel_dismiss","context":{"type":"flight","id":"${safeDismissId}"}}}`;

    // Rebuild children correctly (avoid invalid JSON from conditional append)
    let childrenArr: string[] = [];
    childrenArr.push(`{"type":"text","text":"✈️ ${I18n.t('travel.boarding.title')}","style":{"fontSize":20,"fontWeight":"bold"}}`);
    childrenArr.push(`{"type":"text","text":"${safeFlight}  ${statusEmoji} ${statusLabel}","style":{"fontSize":18}}`);
    childrenArr.push(`{"type":"text","text":"${safeDep} → ${safeArr}","style":{"fontSize":16,"fontWeight":"medium"}}`);
    childrenArr.push(`{"type":"text","text":"🕐 ${departureTimeStr}  ⏰ ${safeCountdown}","style":{"fontSize":14,"color":"${countdownColor}"}}`);
    if (safeDetail.length > 0) {
      childrenArr.push(`{"type":"text","text":"${safeDetail}","style":{"fontSize":13,"color":"#666"}}`);
    }
    childrenArr.push(`{"type":"button","text":"✅ ${I18n.t('travel.dismiss')}","variant":"borderless","action":{"event":{"name":"travel_dismiss","context":{"type":"flight","id":"${safeDismissId}"}}}}`);

    return `{"type":"form","id":"boarding_pass_${ts}","children":[${childrenArr.join(',')}]}`;
  }

  /** Build train ticket A2UI JSON string */
  buildTrainTicketA2UI(train: TrainInfo): string {
    let now = Date.now();
    let countdownMs = train.departureTime - now;
    let countdownStr = this.formatCountdown(countdownMs);
    let isUrgent = countdownMs < 30 * 60 * 1000; // < 30 minutes

    let safeTrain = this.escapeJson(train.trainNumber);
    let safeDep = this.escapeJson(train.departure);
    let safeArr = this.escapeJson(train.arrival);
    let safeCountdown = this.escapeJson(countdownStr);

    let trainTypeLabel = this.trainTypeLabel(train.trainNumber);
    let statusEmoji = this.trainStatusEmoji(train.status);
    let statusLabel = this.escapeJson(I18n.t('travel.train.status.' + train.status));

    // Detail line: coach | seat | check gate
    let detailParts: string[] = [];
    if (train.coach && train.coach.length > 0) {
      detailParts.push(I18n.t('travel.coach') + ' ' + train.coach);
    }
    if (train.seat && train.seat.length > 0) {
      detailParts.push(I18n.t('travel.seat') + ' ' + train.seat);
    }
    if (train.checkGate && train.checkGate.length > 0) {
      detailParts.push(I18n.t('travel.checkGate') + ' ' + train.checkGate);
    }
    let detailStr = detailParts.join(' | ');
    let safeDetail = this.escapeJson(detailStr);

    let departureTimeStr = this.formatTime(train.departureTime);
    let countdownColor = isUrgent ? '#F44336' : '#4CAF50';

    let ts = Date.now().toString();
    let safeDismissId = this.escapeJson(train.trainNumber);

    let childrenArr: string[] = [];
    childrenArr.push(`{"type":"text","text":"🚄 ${I18n.t('travel.train.title')}","style":{"fontSize":20,"fontWeight":"bold"}}`);
    childrenArr.push(`{"type":"text","text":"${safeTrain} ${trainTypeLabel}  ${statusEmoji} ${statusLabel}","style":{"fontSize":18}}`);
    childrenArr.push(`{"type":"text","text":"${safeDep} → ${safeArr}","style":{"fontSize":16,"fontWeight":"medium"}}`);
    childrenArr.push(`{"type":"text","text":"🕐 ${departureTimeStr}  ⏰ ${safeCountdown}","style":{"fontSize":14,"color":"${countdownColor}"}}`);
    if (safeDetail.length > 0) {
      childrenArr.push(`{"type":"text","text":"${safeDetail}","style":{"fontSize":13,"color":"#666"}}`);
    }
    childrenArr.push(`{"type":"button","text":"✅ ${I18n.t('travel.dismiss')}","variant":"borderless","action":{"event":{"name":"travel_dismiss","context":{"type":"train","id":"${safeDismissId}"}}}}`);

    return `{"type":"form","id":"train_ticket_${ts}","children":[${childrenArr.join(',')}]}`;
  }

  // ==================== Private: calendar scanning ====================

  private async maybeRefresh(): Promise<void> {
    let now = Date.now();
    if (now - this.lastRefresh > REFRESH_INTERVAL_MS && this.permissionGranted) {
      await this.refresh();
    }
  }

  private async refresh(): Promise<void> {
    if (!this.context || !this.permissionGranted) return;
    try {
      let calMgr = calendarManager.getCalendarManager(this.context);
      let now = Date.now();
      let endTime = now + LOOKAHEAD_MS;
      let filter = calendarManager.EventFilter.filterByTime(now, endTime);

      let flights: FlightInfo[] = [];
      let trains: TrainInfo[] = [];

      let allCals: calendarManager.Calendar[] = await calMgr.getAllCalendars();
      for (let i = 0; i < allCals.length; i++) {
        let calEvents: calendarManager.Event[] = await allCals[i].getEvents(filter);
        for (let j = 0; j < calEvents.length; j++) {
          let ev = calEvents[j];
          let parsed: ParsedEventData = {
            title: ev.title ?? '',
            description: ev.description ?? '',
            startTime: ev.startTime,
            endTime: ev.endTime,
            eventId: ev.id?.toString() ?? undefined,
          };
          let combined = parsed.title + ' ' + parsed.description;

          // Parse flight number
          let flightMatch = FLIGHT_PATTERN.exec(combined);
          if (flightMatch !== null) {
            let fi: FlightInfo = {
              flightNumber: flightMatch[1],
              departure: this.extractDeparture(combined),
              arrival: this.extractArrival(combined),
              departureTime: parsed.startTime,
              gate: this.extractGate(combined),
              seat: this.extractSeat(combined),
              terminal: this.extractTerminal(combined),
              status: 'scheduled',
              calendarEventId: parsed.eventId,
              calendarEndTime: parsed.endTime,
            };
            flights.push(fi);
          }

          // Parse train number
          let trainMatch = TRAIN_PATTERN.exec(combined);
          if (trainMatch !== null) {
            let ti: TrainInfo = {
              trainNumber: trainMatch[1],
              departure: this.extractDeparture(combined),
              arrival: this.extractArrival(combined),
              departureTime: parsed.startTime,
              coach: this.extractCoach(combined),
              seat: this.extractSeat(combined),
              checkGate: this.extractCheckGate(combined),
              status: 'scheduled',
              calendarEventId: parsed.eventId,
            };
            trains.push(ti);
          }
        }
      }

      // Sort by departure time
      flights.sort((a: FlightInfo, b: FlightInfo): number => a.departureTime - b.departureTime);
      trains.sort((a: TrainInfo, b: TrainInfo): number => a.departureTime - b.departureTime);

      this.cachedFlights = flights;
      this.cachedTrains = trains;
      this.lastRefresh = Date.now();
      this.log.debug(TAG, `Refreshed: ${flights.length} flights, ${trains.length} trains in next 24h`);
    } catch (err) {
      this.log.warn(TAG, `Refresh failed: ${(err as Error).message}`);
    }
  }

  // ==================== Private: text extraction ====================

  /** Extract departure city from event text (e.g. "北京→上海" or "from Beijing") */
  private extractDeparture(text: string): string {
    // Pattern: 城市→城市 or 城市 to 城市 or from 城市
    let arrowMatch = /(.{2,8})[→\-→>]+/.exec(text);
    if (arrowMatch !== null) {
      return arrowMatch[1].trim();
    }
    let fromMatch = /(?:from|出发|始发)[:\s]*([^\s,，到→>]{2,8})/i.exec(text);
    if (fromMatch !== null) {
      return fromMatch[1].trim();
    }
    return '';
  }

  /** Extract arrival city from event text */
  private extractArrival(text: string): string {
    let arrowMatch = /[→\-→>]+(.{2,8})/.exec(text);
    if (arrowMatch !== null) {
      return arrowMatch[1].trim();
    }
    let toMatch = /(?:to|到达|终点)[:\s]*([^\s,，→>]{2,8})/i.exec(text);
    if (toMatch !== null) {
      return toMatch[1].trim();
    }
    return '';
  }

  /** Extract gate from event text (e.g. "登机口 B23" or "Gate B23") */
  private extractGate(text: string): string | undefined {
    let m = /(?:gate|登机口)[:\s]*([A-Z]\d{1,3}|\d{1,3}[A-Z]?)/i.exec(text);
    if (m !== null) return m[1];
    return undefined;
  }

  /** Extract seat from event text (e.g. "座位 12C" or "seat 12C") */
  private extractSeat(text: string): string | undefined {
    let m = /(?:seat|座位|坐位)[:\s]*(\d{1,3}[A-Z]?)/i.exec(text);
    if (m !== null) return m[1];
    return undefined;
  }

  /** Extract terminal from event text (e.g. "T3" or "航站楼3") */
  private extractTerminal(text: string): string | undefined {
    let m = /(?:terminal|航站楼)[:\s]*([T\d]\d?)/i.exec(text);
    if (m !== null) return m[1].replace(/^[Tt]/, 'T');
    let t2 = /\bT(\d)\b/.exec(text);
    if (t2 !== null) return 'T' + t2[1];
    return undefined;
  }

  /** Extract coach from event text (e.g. "3车" or "carriage 3" or "coach 03") */
  private extractCoach(text: string): string | undefined {
    let m = /(?:coach|carriage|车厢|车)[:\s]*(\d{1,2})/i.exec(text);
    if (m !== null) return m[1];
    let m2 = /(\d{1,2})车/.exec(text);
    if (m2 !== null) return m2[1];
    return undefined;
  }

  /** Extract check gate from event text (e.g. "检票口8A" or "check gate 8A") */
  private extractCheckGate(text: string): string | undefined {
    let m = /(?:check gate|检票口|检票)[:\s]*(\d{1,2}[A-Z]?)/i.exec(text);
    if (m !== null) return m[1];
    return undefined;
  }

  // ==================== Private: formatting ====================

  private formatCountdown(ms: number): string {
    if (ms <= 0) return I18n.t('travel.departed');
    let totalMin = Math.floor(ms / 60000);
    if (totalMin < 60) {
      return I18n.t('travel.countdown.min').replace('{0}', totalMin.toString());
    }
    let h = Math.floor(totalMin / 60);
    let m = totalMin % 60;
    if (m === 0) {
      return I18n.t('travel.countdown.hour').replace('{0}', h.toString());
    }
    return I18n.t('travel.countdown.hourMin').replace('{0}', h.toString()).replace('{1}', m.toString());
  }

  private formatTime(ts: number): string {
    let d = new Date(ts);
    let hh = d.getHours().toString().padStart(2, '0');
    let mm = d.getMinutes().toString().padStart(2, '0');
    return `${hh}:${mm}`;
  }

  private flightStatusEmoji(status: FlightStatus): string {
    let map: Record<string, string> = {
      'scheduled': '🟢', 'boarding': '🔵', 'departed': '🛫',
      'arrived': '🛬', 'delayed': '🟡', 'cancelled': '🔴',
    };
    return map[status] ?? '⚪';
  }

  private trainStatusEmoji(status: TrainStatus): string {
    let map: Record<string, string> = {
      'scheduled': '🟢', 'boarding': '🔵', 'departed': '🚄',
      'arrived': '🏁', 'delayed': '🟡',
    };
    return map[status] ?? '⚪';
  }

  private trainTypeLabel(trainNumber: string): string {
    if (trainNumber.length === 0) return '';
    let prefix = trainNumber[0];
    let map: Record<string, string> = {
      'G': I18n.t('travel.train.type.G'),
      'C': I18n.t('travel.train.type.C'),
      'D': I18n.t('travel.train.type.D'),
      'Z': I18n.t('travel.train.type.Z'),
      'T': I18n.t('travel.train.type.T'),
      'S': I18n.t('travel.train.type.S'),
      'P': I18n.t('travel.train.type.P'),
      'K': I18n.t('travel.train.type.K'),
      'L': I18n.t('travel.train.type.L'),
      'Y': I18n.t('travel.train.type.Y'),
    };
    return map[prefix] ?? '';
  }

  private escapeJson(s: string): string {
    return s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '');
  }
}
