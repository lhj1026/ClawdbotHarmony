/**
 * Handles calendar.add commands from the gateway.
 * Adds events with reminders to the system calendar via @kit.CalendarKit.
 */
import { calendarManager } from '@kit.CalendarKit';
import { abilityAccessCtrl, common } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';

const TAG = 'CalendarCap';

interface CalendarEventParams {
  title: string;
  startTime: number;   // epoch ms
  endTime: number;      // epoch ms
  description: string;
  location: string;
  reminderTime: number[];  // minutes before event, e.g. [5, 15, 60]
}

export class CalendarCapability {
  private log: LogService = LogService.getInstance();
  private context: common.UIAbilityContext | undefined = undefined;
  private calendarMgr: calendarManager.CalendarManager | undefined = undefined;
  private permissionGranted: boolean = false;

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  async execute(paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: params=${paramsJson ?? 'none'}`);

    if (!this.context) {
      throw new Error('calendar.add: no UI context available');
    }

    if (!paramsJson || paramsJson.length === 0) {
      throw new Error('calendar.add requires params with "title", "startTime"');
    }

    // Ensure calendar permission
    if (!this.permissionGranted) {
      await this.requestPermission();
    }
    if (!this.permissionGranted) {
      return '{"ok":false,"error":"CALENDAR_PERMISSION_DENIED","message":"Calendar permission not granted"}';
    }

    // Initialize calendar manager
    if (!this.calendarMgr) {
      this.calendarMgr = calendarManager.getCalendarManager(this.context);
      this.log.info(TAG, 'CalendarManager initialized');
    }

    let params: CalendarEventParams;
    try {
      params = JSON.parse(paramsJson) as CalendarEventParams;
    } catch {
      throw new Error('Invalid JSON params for calendar.add');
    }

    let title: string = params.title ?? '';
    if (title.length === 0) {
      throw new Error('calendar.add: "title" is required');
    }

    // Default: start now, end 1 hour later
    let now = Date.now();
    let startTime: number = params.startTime ?? now;
    let endTime: number = params.endTime ?? (startTime + 60 * 60 * 1000);
    let description: string = params.description ?? '';
    let location: string = params.location ?? '';
    let reminderTime: number[] = params.reminderTime ?? [5]; // default 5 minutes before

    this.log.info(TAG, `Adding event: title="${title}" start=${startTime} end=${endTime} reminder=[${reminderTime.join(',')}] loc="${location}"`);

    // Get default calendar
    let calendar: calendarManager.Calendar = await this.calendarMgr.getCalendar();
    this.log.info(TAG, 'Got default calendar');

    // Build event
    let event: calendarManager.Event = {
      type: calendarManager.EventType.NORMAL,
      startTime: startTime,
      endTime: endTime,
      title: title,
    };

    if (description.length > 0) {
      event.description = description;
    }

    if (location.length > 0) {
      event.location = { location: location };
    }

    if (reminderTime.length > 0) {
      event.reminderTime = reminderTime;
    }

    // Add event to calendar
    let eventId: number = await calendar.addEvent(event);
    this.log.info(TAG, `Event added successfully: eventId=${eventId}`);

    return `{"ok":true,"eventId":${eventId},"title":${JSON.stringify(title)},"startTime":${startTime},"endTime":${endTime}}`;
  }

  private async requestPermission(): Promise<void> {
    if (!this.context) {
      return;
    }

    try {
      let atManager = abilityAccessCtrl.createAtManager();
      let result = await atManager.requestPermissionsFromUser(this.context,
        ['ohos.permission.READ_CALENDAR', 'ohos.permission.WRITE_CALENDAR']);
      // Check if both permissions are granted (authResults[i] === 0 means granted)
      let allGranted = true;
      for (let i = 0; i < result.authResults.length; i++) {
        if (result.authResults[i] !== 0) {
          allGranted = false;
          break;
        }
      }
      this.permissionGranted = allGranted;
      this.log.info(TAG, `Permission request result: granted=${allGranted} results=[${result.authResults.join(',')}]`);
    } catch (err) {
      this.log.error(TAG, `Permission request failed: ${(err as Error).message ?? ''}`);
      this.permissionGranted = false;
    }
  }
}
