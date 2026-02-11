/**
 * Handles email.send commands from the gateway.
 * Composes and sends email via HarmonyOS system email app (startAbility with mailto).
 */
import { common, Want } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';

const TAG = 'EmailCap';

interface EmailParams {
  to: string;
  subject: string;
  body: string;
  cc: string;
  bcc: string;
}

export class EmailCapability {
  private log: LogService = LogService.getInstance();
  private context: common.UIAbilityContext | undefined = undefined;

  setContext(ctx: common.UIAbilityContext): void {
    this.context = ctx;
  }

  async execute(paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: params=${paramsJson ?? 'none'}`);

    if (!paramsJson || paramsJson.length === 0) {
      throw new Error('email.send requires params with "to", "subject", "body"');
    }

    let params: EmailParams;
    try {
      params = JSON.parse(paramsJson) as EmailParams;
    } catch {
      throw new Error('Invalid JSON params for email.send');
    }

    let to: string = params.to ?? '';
    let subject: string = params.subject ?? '';
    let body: string = params.body ?? '';
    let cc: string = params.cc ?? '';
    let bcc: string = params.bcc ?? '';

    if (to.length === 0) {
      throw new Error('email.send: "to" (email address) is required');
    }

    this.log.info(TAG, `Sending email to=${to} subject=${subject} bodyLen=${body.length}`);

    if (!this.context) {
      throw new Error('email.send: no UI context available');
    }

    // Build mailto URI
    let mailto = `mailto:${encodeURIComponent(to)}`;
    let queryParts: string[] = [];
    if (subject.length > 0) {
      queryParts.push(`subject=${encodeURIComponent(subject)}`);
    }
    if (body.length > 0) {
      queryParts.push(`body=${encodeURIComponent(body)}`);
    }
    if (cc.length > 0) {
      queryParts.push(`cc=${encodeURIComponent(cc)}`);
    }
    if (bcc.length > 0) {
      queryParts.push(`bcc=${encodeURIComponent(bcc)}`);
    }
    if (queryParts.length > 0) {
      mailto += '?' + queryParts.join('&');
    }

    this.log.info(TAG, `mailto URI: ${mailto}`);

    // Launch system email app via implicit Want
    let want: Want = {
      action: 'ohos.want.action.sendToData',
      uri: mailto,
    };

    try {
      await this.context.startAbility(want);
      this.log.info(TAG, `Email compose launched successfully to=${to}`);
      return `{"ok":true,"to":${JSON.stringify(to)},"subject":${JSON.stringify(subject)}}`;
    } catch (e) {
      let errMsg = (e as Error).message ?? String(e);
      this.log.error(TAG, `startAbility failed: ${errMsg}`);
      // Fallback: try with viewData action on mailto URI
      this.log.info(TAG, 'Trying fallback with viewData action...');
      let fallbackWant: Want = {
        action: 'ohos.want.action.viewData',
        uri: mailto,
      };
      try {
        await this.context.startAbility(fallbackWant);
        this.log.info(TAG, `Email compose launched via viewData fallback to=${to}`);
        return `{"ok":true,"to":${JSON.stringify(to)},"subject":${JSON.stringify(subject)},"method":"viewData"}`;
      } catch (e2) {
        let errMsg2 = (e2 as Error).message ?? String(e2);
        this.log.error(TAG, `viewData fallback also failed: ${errMsg2}`);
        throw new Error(`Failed to open email app: ${errMsg}. Fallback: ${errMsg2}`);
      }
    }
  }
}
