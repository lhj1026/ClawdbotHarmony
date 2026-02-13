/**
 * Handles email.send commands from the gateway.
 * Sends email via SMTP over TLS using credentials from Settings (PREFS_EMAIL).
 * Follows the same TLS socket pattern as ImapService (proven to work).
 */
import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import socket from '@ohos.net.socket';
import { LogService } from '../../common/LogService';
import { Constants } from '../../common/Constants';

const TAG = 'EmailCap';

interface EmailParams {
  to: string;
  subject: string;
  body: string;
  cc: string;
  bcc: string;
}

interface SmtpConfig {
  smtpHost: string;
  smtpPort: number;
  user: string;
  pass: string;
}

export class EmailCapability {
  private log: LogService = LogService.getInstance();
  private context: common.UIAbilityContext | undefined = undefined;

  // SMTP socket state (mirrors ImapService pattern)
  private tlsSocket: socket.TLSSocket | null = null;
  private tcpSocket: socket.TCPSocket | null = null;
  private dataBuffer: string = '';
  private pendingCode: string = '';
  private collectedLines: string[] = [];
  private lineResolve: ((line: string) => void) | null = null;

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

    if (!this.context) {
      throw new Error('email.send: no UI context available');
    }

    let config = await this.loadSmtpConfig();
    if (config.smtpHost.length === 0 || config.user.length === 0) {
      throw new Error('email.send: SMTP not configured. Please set up email in Settings.');
    }

    this.log.info(TAG, `Sending email via SMTP ${config.smtpHost}:${config.smtpPort} from=${config.user} to=${to}`);

    try {
      if (config.smtpPort === 465) {
        await this.smtpConnect(config.smtpHost, config.smtpPort);
      } else {
        await this.smtpConnectStartTls(config.smtpHost, config.smtpPort);
      }
      await this.smtpCommand('EHLO clawdbot', '250');
      this.log.info(TAG, '[smtp] EHLO OK');

      await this.smtpCommand('AUTH LOGIN', '334');
      await this.smtpCommand(this.toBase64(config.user), '334');
      await this.smtpCommand(this.toBase64(config.pass), '235');
      this.log.info(TAG, '[smtp] AUTH OK');

      await this.smtpCommand(`MAIL FROM:<${config.user}>`, '250');

      let recipients = to.split(',');
      for (let r of recipients) {
        let addr = r.trim();
        if (addr.length > 0) {
          await this.smtpCommand(`RCPT TO:<${addr}>`, '250');
        }
      }
      if (cc.length > 0) {
        for (let r of cc.split(',')) {
          let addr = r.trim();
          if (addr.length > 0) {
            await this.smtpCommand(`RCPT TO:<${addr}>`, '250');
          }
        }
      }
      if (bcc.length > 0) {
        for (let r of bcc.split(',')) {
          let addr = r.trim();
          if (addr.length > 0) {
            await this.smtpCommand(`RCPT TO:<${addr}>`, '250');
          }
        }
      }
      this.log.info(TAG, '[smtp] Recipients OK');

      await this.smtpCommand('DATA', '354');

      // Build email message with all required headers
      let now = new Date();
      let dateStr = this.formatRfc2822Date(now);
      let msgId = `<${Date.now()}.${Math.floor(Math.random() * 100000)}@${config.smtpHost}>`;

      let msg = '';
      msg += `Date: ${dateStr}\r\n`;
      msg += `From: ${config.user}\r\n`;
      msg += `To: ${to}\r\n`;
      if (cc.length > 0) {
        msg += `Cc: ${cc}\r\n`;
      }
      msg += `Subject: ${this.encodeMimeHeader(subject)}\r\n`;
      msg += `Message-ID: ${msgId}\r\n`;
      msg += `MIME-Version: 1.0\r\n`;
      msg += `Content-Type: text/plain; charset=UTF-8\r\n`;
      msg += `Content-Transfer-Encoding: base64\r\n`;
      msg += `X-Mailer: ClawdBot\r\n`;
      msg += `\r\n`;
      msg += this.toBase64(body);
      msg += `\r\n.\r\n`;

      // Send message body and expect 250
      await this.smtpSendRaw(msg);
      let doneResp = await this.smtpWaitResponse(15000);
      if (!doneResp.startsWith('250')) {
        throw new Error(`SMTP DATA response: ${doneResp}`);
      }
      this.log.info(TAG, '[smtp] Message sent OK');

      try { await this.smtpSendRaw('QUIT\r\n'); } catch { /* ignore */ }
    } finally {
      await this.smtpClose();
    }

    this.log.info(TAG, `Email sent successfully to=${to}`);
    return `{"ok":true,"to":${JSON.stringify(to)},"subject":${JSON.stringify(subject)}}`;
  }

  // ========== SMTP protocol methods (following ImapService pattern exactly) ==========

  private async smtpConnect(host: string, port: number): Promise<void> {
    this.dataBuffer = '';
    this.pendingCode = '';
    this.collectedLines = [];
    this.lineResolve = null;

    this.tlsSocket = socket.constructTLSSocketInstance();

    // Step 1: Bind (same as ImapService)
    await this.tlsSocket.bind({ address: '0.0.0.0' });

    // Step 2: Prepare greeting promise BEFORE connect (same as ImapService)
    let greetingPromise = new Promise<string>((resolve, reject) => {
      this.lineResolve = resolve;
      let timer = setTimeout(() => {
        if (this.lineResolve) {
          this.lineResolve = null;
          reject(new Error(`SMTP greeting timeout from ${host}:${port}`));
        }
      }, 20000);
      let origResolve = this.lineResolve;
      this.lineResolve = (line: string) => {
        clearTimeout(timer);
        origResolve(line);
      };
    });

    // Step 3: Set up message handler (same as ImapService)
    this.tlsSocket.on('message', (value: socket.SocketMessageInfo) => {
      let data = buf2str(value.message);
      this.log.info(TAG, `[smtp recv] ${data.length}b: ${data.substring(0, 120).replace(/\r\n/g, '\\r\\n')}`);
      this.onSmtpData(data);
    });

    // Step 4: Connect
    this.log.info(TAG, `[smtp] Connecting to ${host}:${port}...`);
    let tlsOptions: socket.TLSConnectOptions = {
      address: { address: host, port: port, family: 1 },
      secureOptions: {
        protocols: [socket.Protocol.TLSv12],
      },
    };
    await this.tlsSocket.connect(tlsOptions);
    this.log.info(TAG, '[smtp] TLS connected, waiting for greeting...');

    // Step 5: Wait for greeting
    let greeting = await greetingPromise;
    this.log.info(TAG, `[smtp] Greeting: ${greeting.substring(0, 80)}`);
    if (!greeting.startsWith('220')) {
      throw new Error(`SMTP unexpected greeting: ${greeting}`);
    }
  }

  private async smtpConnectStartTls(host: string, port: number): Promise<void> {
    this.dataBuffer = '';
    this.pendingCode = '';
    this.collectedLines = [];
    this.lineResolve = null;

    // Step 1: Create plain TCP socket
    this.tcpSocket = socket.constructTCPSocketInstance();
    await this.tcpSocket.bind({ address: '0.0.0.0' });

    // Step 2: Prepare greeting promise BEFORE connect
    let greetingPromise = new Promise<string>((resolve, reject) => {
      this.lineResolve = resolve;
      let timer = setTimeout(() => {
        if (this.lineResolve) {
          this.lineResolve = null;
          reject(new Error(`SMTP STARTTLS greeting timeout from ${host}:${port}`));
        }
      }, 20000);
      let origResolve = this.lineResolve;
      this.lineResolve = (line: string) => {
        clearTimeout(timer);
        origResolve(line);
      };
    });

    // Step 3: Set up TCP message handler
    this.tcpSocket.on('message', (value: socket.SocketMessageInfo) => {
      let data = buf2str(value.message);
      this.log.info(TAG, `[smtp-tcp recv] ${data.length}b: ${data.substring(0, 120).replace(/\r\n/g, '\\r\\n')}`);
      this.onSmtpData(data);
    });

    // Step 4: TCP connect (plaintext)
    this.log.info(TAG, `[smtp] STARTTLS: TCP connecting to ${host}:${port}...`);
    await this.tcpSocket.connect({ address: { address: host, port: port, family: 1 } });
    this.log.info(TAG, '[smtp] TCP connected, waiting for greeting...');

    // Step 5: Wait for 220 greeting (plaintext)
    let greeting = await greetingPromise;
    this.log.info(TAG, `[smtp] Greeting: ${greeting.substring(0, 80)}`);
    if (!greeting.startsWith('220')) {
      throw new Error(`SMTP unexpected greeting: ${greeting}`);
    }

    // Step 6: EHLO + STARTTLS (plaintext, smtpCommand uses tcpSocket via smtpSendRaw)
    await this.smtpCommand('EHLO clawdbot', '250');
    this.log.info(TAG, '[smtp] EHLO OK (plaintext)');
    await this.smtpCommand('STARTTLS', '220');
    this.log.info(TAG, '[smtp] STARTTLS accepted, upgrading to TLS...');

    // Step 7: Remove TCP message handler, reset buffers
    this.tcpSocket.off('message');
    this.dataBuffer = '';
    this.collectedLines = [];
    this.lineResolve = null;

    // Step 8: Create TLS socket from existing TCP socket
    this.tlsSocket = socket.constructTLSSocketInstance(this.tcpSocket);

    // Step 9: Register TLS message handler
    this.tlsSocket.on('message', (value: socket.SocketMessageInfo) => {
      let data = buf2str(value.message);
      this.log.info(TAG, `[smtp-tls recv] ${data.length}b: ${data.substring(0, 120).replace(/\r\n/g, '\\r\\n')}`);
      this.onSmtpData(data);
    });

    // Step 10: TLS handshake
    let tlsOptions: socket.TLSConnectOptions = {
      address: { address: host, port: port, family: 1 },
      secureOptions: {
        protocols: [socket.Protocol.TLSv12],
      },
    };
    await this.tlsSocket.connect(tlsOptions);
    this.log.info(TAG, '[smtp] TLS upgrade complete');
  }

  private onSmtpData(data: string): void {
    this.dataBuffer += data;
    let nlIdx = this.dataBuffer.indexOf('\r\n');
    while (nlIdx >= 0) {
      let line = this.dataBuffer.substring(0, nlIdx);
      this.dataBuffer = this.dataBuffer.substring(nlIdx + 2);

      // Skip multi-line continuation (e.g. 250-SIZE, 250-AUTH)
      if (line.length >= 4 && line[3] === '-') {
        nlIdx = this.dataBuffer.indexOf('\r\n');
        continue;
      }

      // Resolve waiting promise
      if (this.lineResolve) {
        let resolve = this.lineResolve;
        this.lineResolve = null;
        resolve(line);
      } else {
        // Buffer for later (shouldn't happen in normal flow)
        this.collectedLines.push(line);
      }

      nlIdx = this.dataBuffer.indexOf('\r\n');
    }
  }

  private smtpWaitResponse(timeoutMs: number = 20000): Promise<string> {
    return new Promise<string>((resolve, reject) => {
      // Check if a line was already buffered
      if (this.collectedLines.length > 0) {
        resolve(this.collectedLines.shift() as string);
        return;
      }
      this.lineResolve = resolve;
      let timer = setTimeout(() => {
        if (this.lineResolve) {
          this.lineResolve = null;
          reject(new Error('SMTP response timeout'));
        }
      }, timeoutMs);
      let origResolve = this.lineResolve;
      this.lineResolve = (line: string) => {
        clearTimeout(timer);
        origResolve(line);
      };
    });
  }

  private async smtpCommand(cmd: string, expectedCode: string): Promise<string> {
    await this.smtpSendRaw(cmd + '\r\n');
    let response = await this.smtpWaitResponse();
    if (!response.startsWith(expectedCode)) {
      throw new Error(`SMTP expected ${expectedCode}, got: ${response}`);
    }
    return response;
  }

  private async smtpSendRaw(data: string): Promise<void> {
    let logData = data.trim();
    if (logData.length > 40) logData = logData.substring(0, 40) + '...';
    this.log.info(TAG, `[smtp send] ${logData}`);
    if (this.tlsSocket) {
      let encoded = str2buf(data);
      await this.tlsSocket.send(encoded);
    } else if (this.tcpSocket) {
      await this.tcpSocket.send({ data: data });
    } else {
      throw new Error('SMTP not connected');
    }
  }

  private async smtpClose(): Promise<void> {
    if (this.tlsSocket) {
      try { await this.tlsSocket.close(); } catch { /* ignore */ }
      this.tlsSocket = null;
    }
    if (this.tcpSocket) {
      try { await this.tcpSocket.close(); } catch { /* ignore */ }
      this.tcpSocket = null;
    }
    this.lineResolve = null;
  }

  // ========== Helpers ==========

  private async loadSmtpConfig(): Promise<SmtpConfig> {
    let ctx = this.context as common.UIAbilityContext;
    let store = await preferences.getPreferences(ctx, Constants.PREFS_EMAIL);
    let config: SmtpConfig = {
      smtpHost: (await store.get('smtpHost', '')) as string,
      smtpPort: parseInt((await store.get('smtpPort', '465')) as string) || 465,
      user: (await store.get('imapUser', '')) as string,
      pass: (await store.get('imapPass', '')) as string,
    };
    return config;
  }

  private toBase64(input: string): string {
    let chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    let bytes: number[] = [];
    for (let i = 0; i < input.length; i++) {
      let code = input.charCodeAt(i);
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xC0 | (code >> 6));
        bytes.push(0x80 | (code & 0x3F));
      } else {
        bytes.push(0xE0 | (code >> 12));
        bytes.push(0x80 | ((code >> 6) & 0x3F));
        bytes.push(0x80 | (code & 0x3F));
      }
    }
    let result = '';
    for (let i = 0; i < bytes.length; i += 3) {
      let b1 = bytes[i];
      let b2 = i + 1 < bytes.length ? bytes[i + 1] : 0;
      let b3 = i + 2 < bytes.length ? bytes[i + 2] : 0;
      result += chars[(b1 >> 2) & 0x3F];
      result += chars[((b1 & 3) << 4) | ((b2 >> 4) & 0xF)];
      result += i + 1 < bytes.length ? chars[((b2 & 0xF) << 2) | ((b3 >> 6) & 3)] : '=';
      result += i + 2 < bytes.length ? chars[b3 & 0x3F] : '=';
    }
    return result;
  }

  private formatRfc2822Date(d: Date): string {
    let days = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    let months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    let day = days[d.getDay()];
    let date = d.getDate();
    let mon = months[d.getMonth()];
    let year = d.getFullYear();
    let h = d.getHours().toString().padStart(2, '0');
    let m = d.getMinutes().toString().padStart(2, '0');
    let s = d.getSeconds().toString().padStart(2, '0');
    let tz = -d.getTimezoneOffset();
    let tzSign = tz >= 0 ? '+' : '-';
    let tzAbs = Math.abs(tz);
    let tzH = Math.floor(tzAbs / 60).toString().padStart(2, '0');
    let tzM = (tzAbs % 60).toString().padStart(2, '0');
    return `${day}, ${date} ${mon} ${year} ${h}:${m}:${s} ${tzSign}${tzH}${tzM}`;
  }

  private encodeMimeHeader(text: string): string {
    let needsEncoding = false;
    for (let i = 0; i < text.length; i++) {
      if (text.charCodeAt(i) > 127) {
        needsEncoding = true;
        break;
      }
    }
    if (!needsEncoding) return text;
    return `=?UTF-8?B?${this.toBase64(text)}?=`;
  }
}

function buf2str(buf: ArrayBuffer): string {
  let view = new Uint8Array(buf);
  let result = '';
  for (let i = 0; i < view.length; i++) {
    result += String.fromCharCode(view[i]);
  }
  return result;
}

function str2buf(str: string): ArrayBuffer {
  let bytes: number[] = [];
  for (let i = 0; i < str.length; i++) {
    let code = str.charCodeAt(i);
    if (code < 0x80) {
      bytes.push(code);
    } else if (code < 0x800) {
      bytes.push(0xC0 | (code >> 6));
      bytes.push(0x80 | (code & 0x3F));
    } else {
      bytes.push(0xE0 | (code >> 12));
      bytes.push(0x80 | ((code >> 6) & 0x3F));
      bytes.push(0x80 | (code & 0x3F));
    }
  }
  let buf = new ArrayBuffer(bytes.length);
  let view = new Uint8Array(buf);
  for (let i = 0; i < bytes.length; i++) {
    view[i] = bytes[i];
  }
  return buf;
}
