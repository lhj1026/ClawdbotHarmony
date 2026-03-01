/**
 * CalendarPlugin — Read upcoming calendar events
 *
 * ⚠️ HarmonyOS NEXT limitation: CalendarKit can ONLY read calendars created by THIS app.
 * Third-party calendars (WeLink, etc.) are not accessible — no DataShare consumer API available.
 *
 * Current strategy:
 * - CalendarKit for app-owned events (e.g. events added via CalendarCapability)
 * - For WeLink/system calendar events: rely on Gateway agent calendar tools (gog, etc.)
 *
 * Permission: ohos.permission.READ_CALENDAR (user_grant, already declared)
 * API: @kit.CalendarKit — calendarManager
 */
import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'CalendarPlugin';
const LOOKAHEAD_MS = 36 * 60 * 60 * 1000;  // 36 hours (cover today + tomorrow morning)
const REFRESH_INTERVAL_MS = 5 * 60 * 1000; // refresh cache every 5 minutes

/** Cached event summary */
export interface EventInfo {
  title: string;
  startTime: number;
  endTime: number;
  location: string;
}

/** A pair of conflicting events */
export interface EventConflict {
  event1: EventInfo;
  event2: EventInfo;
  overlapMinutes: number;
}

export class CalendarPlugin implements DigitalPlugin {
  name: string = 'calendar';
  private log: LogService = LogService.getInstance();
  private context: common.UIAbilityContext | undefined;
  private permissionGranted: boolean = false;
  private cachedEvents: EventInfo[] = [];
  private lastRefresh: number = 0;

  async init(context: common.UIAbilityContext): Promise<void> {
    this.context = context;
    try {
      let atManager = abilityAccessCtrl.createAtManager();
      let result = await atManager.requestPermissionsFromUser(context,
        ['ohos.permission.READ_CALENDAR']);
      if (result.authResults.length > 0 && result.authResults[0] === 0) {
        this.permissionGranted = true;
      }
      this.log.info(TAG, `Init: permission=${this.permissionGranted}`);
    } catch (err) {
      this.log.warn(TAG, `Permission request failed: ${(err as Error).message}`);
    }

    if (this.permissionGranted) {
      await this.refreshEvents();
    }
  }

  getSnapshot(): DigitalSnapshot {
    let now = Date.now();
    if (now - this.lastRefresh > REFRESH_INTERVAL_MS && this.permissionGranted) {
      this.refreshEvents();  // fire-and-forget
    }

    let data: Record<string, string> = {};
    let upcoming = this.cachedEvents.filter((ev: EventInfo): boolean => ev.startTime > now);
    data['cal_eventCount'] = upcoming.length.toString();
    data['cal_hasUpcoming'] = (upcoming.length > 0) ? 'true' : 'false';

    if (upcoming.length > 0) {
      let next = upcoming[0];
      data['cal_nextTitle'] = next.title;
      let minutesUntil = Math.round((next.startTime - now) / 60000);
      data['cal_nextMinutes'] = minutesUntil.toString();
      if (next.location.length > 0) {
        data['cal_nextLocation'] = next.location;
      }
    }

    let current = this.cachedEvents.filter((ev: EventInfo): boolean =>
      ev.startTime <= now && ev.endTime > now
    );
    data['cal_inMeeting'] = (current.length > 0) ? 'true' : 'false';
    if (current.length > 0) {
      data['cal_currentTitle'] = current[0].title;
    }

    return {
      pluginName: this.name,
      timestamp: now,
      data: data
    };
  }

  destroy(): void {
    this.cachedEvents = [];
    this.log.info(TAG, 'Destroyed');
  }

  /** Get upcoming events within a time window */
  async getUpcomingEvents(hoursAhead?: number): Promise<EventInfo[]> {
    let now = Date.now();
    if (now - this.lastRefresh > REFRESH_INTERVAL_MS && this.permissionGranted) {
      await this.refreshEvents();
    }
    let windowMs = (hoursAhead ?? 8) * 60 * 60 * 1000;
    let cutoff = now + windowMs;
    let filtered = this.cachedEvents.filter((ev: EventInfo): boolean =>
      ev.startTime > now && ev.startTime < cutoff
    );
    this.log.info(TAG, `getUpcomingEvents(${hoursAhead ?? 8}h): ${filtered.length}/${this.cachedEvents.length} events`);
    return filtered;
  }

  /** Detect time-overlapping event pairs */
  findConflicts(events: EventInfo[]): EventConflict[] {
    let conflicts: EventConflict[] = [];
    for (let i = 0; i < events.length; i++) {
      for (let j = i + 1; j < events.length; j++) {
        let a = events[i];
        let b = events[j];
        let overlapStart = Math.max(a.startTime, b.startTime);
        let overlapEnd = Math.min(a.endTime, b.endTime);
        if (overlapStart < overlapEnd) {
          conflicts.push({
            event1: a,
            event2: b,
            overlapMinutes: Math.round((overlapEnd - overlapStart) / 60000)
          });
        }
      }
    }
    return conflicts;
  }

  /** Format events as human-readable text for chat display */
  formatEventsMarkdown(events: EventInfo[], conflicts?: EventConflict[]): string {
    if (events.length === 0) {
      return '📅 接下来没有日程安排';
    }
    let lines: string[] = [];
    lines.push(`📅 **接下来有 ${events.length} 个日程**\n`);
    for (let i = 0; i < events.length; i++) {
      let ev = events[i];
      let start = new Date(ev.startTime);
      let end = new Date(ev.endTime);
      let timeStr = `${start.getHours().toString().padStart(2, '0')}:${start.getMinutes().toString().padStart(2, '0')}` +
        ` - ${end.getHours().toString().padStart(2, '0')}:${end.getMinutes().toString().padStart(2, '0')}`;
      let locStr = ev.location.length > 0 ? ` 📍 ${ev.location}` : '';
      lines.push(`${(i + 1).toString()}. **${ev.title}**`);
      lines.push(`   🕐 ${timeStr}${locStr}`);
    }
    if (conflicts && conflicts.length > 0) {
      lines.push('');
      lines.push(`⚠️ **发现 ${conflicts.length} 个时间冲突：**`);
      for (let c of conflicts) {
        lines.push(`   - "${c.event1.title}" 与 "${c.event2.title}" 重叠 ${c.overlapMinutes} 分钟`);
      }
    }
    return lines.join('\n');
  }

  /** Inject events from external source (e.g. Gateway agent calendar query) */
  injectEvents(events: EventInfo[]): void {
    let seen = new Set<string>();
    for (let ev of this.cachedEvents) {
      seen.add(`${ev.title}@${ev.startTime}`);
    }
    let added = 0;
    for (let ev of events) {
      let key = `${ev.title}@${ev.startTime}`;
      if (!seen.has(key)) {
        this.cachedEvents.push(ev);
        seen.add(key);
        added++;
      }
    }
    if (added > 0) {
      this.cachedEvents.sort((a: EventInfo, b: EventInfo): number => a.startTime - b.startTime);
      this.log.info(TAG, `Injected ${added} external events, total=${this.cachedEvents.length}`);
    }
  }

  private async refreshEvents(): Promise<void> {
    if (!this.context || !this.permissionGranted) return;

    try {
      let calMgr = calendarManager.getCalendarManager(this.context);
      let now = Date.now();
      let endTime = now + LOOKAHEAD_MS;
      let filter = calendarManager.EventFilter.filterByTime(now, endTime);
      let events: EventInfo[] = [];

      try {
        let allCals: calendarManager.Calendar[] = await calMgr.getAllCalendars();
        for (let i = 0; i < allCals.length; i++) {
          let calEvents: calendarManager.Event[] = await allCals[i].getEvents(filter);
          for (let j = 0; j < calEvents.length; j++) {
            let ev = calEvents[j];
            events.push({
              title: ev.title ?? '',
              startTime: ev.startTime,
              endTime: ev.endTime,
              location: ev.location?.location ?? ''
            });
          }
        }
      } catch (calErr) {
        this.log.warn(TAG, `getAllCalendars failed: ${(calErr as Error).message}`);
      }

      events.sort((a: EventInfo, b: EventInfo): number => a.startTime - b.startTime);
      this.cachedEvents = events;
      this.lastRefresh = Date.now();
      this.log.info(TAG, `Refreshed: ${events.length} events (CalendarKit only — WeLink not accessible)`);
    } catch (err) {
      this.log.warn(TAG, `Refresh failed: ${(err as Error).message}`);
    }
  }
}
