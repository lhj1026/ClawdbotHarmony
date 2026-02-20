/**
 * CalendarPlugin — Read upcoming calendar events
 *
 * Queries the system calendar for events in the next 2 hours.
 * Provides: hasUpcomingEvent, nextEventTitle, nextEventMinutes, eventCount
 *
 * Permission: ohos.permission.READ_CALENDAR (user_grant, already declared)
 * API: @kit.CalendarKit — calendarManager
 */
import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { LogService } from '../../../common/LogService';
import { DigitalPlugin, DigitalSnapshot } from './DigitalPluginInterface';

const TAG = 'CalendarPlugin';
const LOOKAHEAD_MS = 2 * 60 * 60 * 1000;  // 2 hours
const REFRESH_INTERVAL_MS = 5 * 60 * 1000; // refresh cache every 5 minutes

/** Cached event summary */
interface EventInfo {
  title: string;
  startTime: number;
  endTime: number;
  location: string;
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
      // Check if permission was granted (authResults[0] === 0 means granted)
      if (result.authResults.length > 0 && result.authResults[0] === 0) {
        this.permissionGranted = true;
      }
      this.log.info(TAG, `Init: permission=${this.permissionGranted}`);
    } catch (err) {
      this.log.warn(TAG, `Permission request failed: ${(err as Error).message}`);
    }

    // Initial load
    if (this.permissionGranted) {
      await this.refreshEvents();
    }
  }

  getSnapshot(): DigitalSnapshot {
    // Refresh cache if stale
    let now = Date.now();
    if (now - this.lastRefresh > REFRESH_INTERVAL_MS && this.permissionGranted) {
      this.refreshEvents();  // fire-and-forget, use cached data for now
    }

    let data: Record<string, string> = {};

    // Filter to only future events
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

    // Check if user is currently IN an event
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
      } catch {
        // Fallback to default calendar
        let cal = await calMgr.getCalendar();
        let calEvents: calendarManager.Event[] = await cal.getEvents(filter);
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

      // Sort by start time
      events.sort((a: EventInfo, b: EventInfo): number => a.startTime - b.startTime);

      this.cachedEvents = events;
      this.lastRefresh = Date.now();
      this.log.debug(TAG, `Refreshed: ${events.length} events in next 2h`);
    } catch (err) {
      this.log.warn(TAG, `Refresh failed: ${(err as Error).message}`);
    }
  }
}
