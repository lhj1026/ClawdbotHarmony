/**
 * Handles calendar.add commands from the gateway.
 * Uses CalendarManager.editEvent() (API 12+) to open the system calendar UI,
 * ensuring events are visible in the system Calendar app.
 * Falls back to programmatic addEvent() on a LOCAL calendar if editEvent fails.
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

    // Build event object
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

    // Strategy 1: Use editEvent() which opens the system calendar creation UI
    // This guarantees the event appears in the system Calendar app
    try {
      this.log.info(TAG, 'Trying editEvent() to open system calendar UI...');
      let eventId: number = await this.calendarMgr.editEvent(event);
      this.log.info(TAG, `editEvent() succeeded: eventId=${eventId}`);
      return `{"ok":true,"eventId":${eventId},"title":${JSON.stringify(title)},"startTime":${startTime},"endTime":${endTime},"method":"editEvent"}`;
    } catch (editErr) {
      this.log.warn(TAG, `editEvent() failed: ${(editErr as Error).message ?? ''}, trying programmatic approach...`);
    }

    // Strategy 2: Find a LOCAL calendar from getAllCalendars()
    let calendar: calendarManager.Calendar | undefined = undefined;
    try {
      let allCalendars: calendarManager.Calendar[] = await this.calendarMgr.getAllCalendars();
      this.log.info(TAG, `Found ${allCalendars.length} calendars`);
      for (let i = 0; i < allCalendars.length; i++) {
        let cal = allCalendars[i];
        let account: calendarManager.CalendarAccount = cal.getAccount();
        let config: calendarManager.CalendarConfig = cal.getConfig();
        this.log.info(TAG, `Calendar[${i}]: id=${cal.id} name="${account.name}" type="${account.type}" display="${account.displayName ?? ''}" reminder=${config.enableReminder ?? false}`);
        // Prefer LOCAL type calendar
        if (account.type === calendarManager.CalendarType.LOCAL && !calendar) {
          calendar = cal;
          this.log.info(TAG, `Selected LOCAL calendar: id=${cal.id} name="${account.name}"`);
        }
      }
      // If no LOCAL found, use first available
      if (!calendar && allCalendars.length > 0) {
        calendar = allCalendars[0];
        let acc = calendar.getAccount();
        this.log.info(TAG, `No LOCAL calendar found, using first: id=${calendar.id} name="${acc.name}" type="${acc.type}"`);
      }
    } catch (listErr) {
      this.log.warn(TAG, `getAllCalendars() failed: ${(listErr as Error).message ?? ''}`);
    }

    // Strategy 3: Fall back to getCalendar() (app default)
    if (!calendar) {
      this.log.info(TAG, 'Falling back to getCalendar() (app default)...');
      calendar = await this.calendarMgr.getCalendar();
    }

    // Ensure reminders are enabled on the calendar
    try {
      let config = calendar.getConfig();
      if (!config.enableReminder) {
        this.log.info(TAG, 'Enabling reminders on calendar...');
        await calendar.setConfig({ enableReminder: true });
      }
    } catch (cfgErr) {
      this.log.warn(TAG, `setConfig failed: ${(cfgErr as Error).message ?? ''}`);
    }

    // Add event to selected calendar
    let eventId: number = await calendar.addEvent(event);
    let account = calendar.getAccount();
    this.log.info(TAG, `Event added to calendar "${account.name}" (type=${account.type}): eventId=${eventId}`);

    return `{"ok":true,"eventId":${eventId},"title":${JSON.stringify(title)},"startTime":${startTime},"endTime":${endTime},"calendar":"${account.name}","calendarType":"${account.type}","method":"addEvent"}`;
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
