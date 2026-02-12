/**
 * Handles email.send commands from the gateway.
 * Composes and sends email via HarmonyOS system email app (startAbility with mailto).
 */
import { common, Want } from '@kit.AbilityKit';
import { LogService } from '../../common/LogService';
import { SmtpService } from '../SmtpService';

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

    // 限制 body 长度，防止 URI 过长导致系统拉起失败 (系统 Intent URI 通常有限制)
    if (body.length > 2000) {
      this.log.warn(TAG, 'Body too long, truncating to 2000 chars for mailto URI');
      body = body.substring(0, 2000) + '...\n(Content truncated)';
    }

    this.log.info(TAG, `Sending email to=${to} subject=${subject} bodyLen=${body.length}`);

    if (!this.context) {
      throw new Error('email.send: no UI context available');
    }

    // Build mailto URI
    // 格式: mailto:user@example.com?subject=...&body=...
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

    this.log.info(TAG, `mailto URI prefix: ${mailto.substring(0, 50)}...`);

    // 关键修改：使用 ohos.want.action.viewData 来处理 mailto 协议
    // 这等同于在浏览器中点击邮件链接，系统会自动寻找注册了 mailto 的应用（即邮件客户端）
    let want: Want = {
      action: 'ohos.want.action.viewData',
      uri: mailto,
    };

    try {
      await this.context.startAbility(want);
      this.log.info(TAG, `Email compose UI launched successfully to=${to}`);
      return `{"ok":true,"to":${JSON.stringify(to)},"subject":${JSON.stringify(subject)},"action":"viewData"}`;
    } catch (e) {
      let errMsg = (e as Error).message ?? String(e);
      this.log.error(TAG, `startAbility(viewData) failed: ${errMsg}`);

      // Fallback: 尝试 sendToData (旧的方式，部分设备可能只认这个)
      this.log.info(TAG, 'Trying fallback with sendToData action...');
      let fallbackWant: Want = {
        action: 'ohos.want.action.sendToData',
        uri: mailto,
      };

      try {
        await this.context.startAbility(fallbackWant);
        this.log.info(TAG, `Email compose launched via sendToData fallback to=${to}`);
        return `{"ok":true,"to":${JSON.stringify(to)},"subject":${JSON.stringify(subject)},"method":"sendToData"}`;
      } catch (e2) {
        let errMsg2 = (e2 as Error).message ?? String(e2);
        this.log.error(TAG, `sendToData fallback also failed: ${errMsg2}`);
        throw new Error(`Failed to open email app. Please ensure a Mail app is installed. Error: ${errMsg}`);
      }
    }
  }

}
