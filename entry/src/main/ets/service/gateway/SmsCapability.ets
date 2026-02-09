/**
 * Handles sms.send commands from the gateway.
 * Sends SMS text messages via HarmonyOS telephony API.
 */
import sms from '@ohos.telephony.sms';
import { LogService } from '../../common/LogService';

const TAG = 'SmsCap';

export class SmsCapability {
  private log: LogService = LogService.getInstance();

  async execute(paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: params=${paramsJson ?? 'none'}`);

    if (!paramsJson || paramsJson.length === 0) {
      throw new Error('sms.send requires params with "to" and "message"');
    }

    let params: Record<string, string>;
    try {
      params = JSON.parse(paramsJson) as Record<string, string>;
    } catch {
      throw new Error('Invalid JSON params for sms.send');
    }

    let to: string = params['to'] ?? '';
    let message: string = params['message'] ?? '';

    if (to.length === 0) {
      throw new Error('sms.send: "to" (phone number) is required');
    }
    if (message.length === 0) {
      throw new Error('sms.send: "message" is required');
    }

    this.log.info(TAG, `Sending SMS to=${to} messageLen=${message.length}`);

    let options: sms.SendMessageOptions = {
      slotId: 0,
      destinationHost: to,
      content: message,
    };

    await sms.sendShortMessage(options);
    this.log.info(TAG, `SMS sent successfully to=${to}`);
    return `{"ok":true,"to":${JSON.stringify(to)},"messageLength":${message.length}}`;
  }
}
