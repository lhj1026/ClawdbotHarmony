import socket from '@ohos.net.socket';
import { LogService } from '../common/LogService';

/**
 * IMAP protocol client using TLS socket.
 * Connects to IMAP servers (e.g., imap.gmail.com:993) and provides
 * methods to list, search, and read emails.
 */

export interface EmailSummary {
  seq: number;
  from: string;
  subject: string;
  date: string;
}

export interface EmailBody {
  seq: number;
  from: string;
  subject: string;
  date: string;
  body: string;
}

export class ImapService {
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'ImapService';
  private tlsSocket: socket.TLSSocket | null = null;
  private tagCounter: number = 0;
  private dataBuffer: string = '';
  private connected: boolean = false;

  // Unified resolver — handles both greeting and tagged responses
  private pendingTag: string = '';
  private collectedLines: string[] = [];
  private lineResolve: ((lines: string[]) => void) | null = null;

  private nextTag(): string {
    this.tagCounter++;
    let num = this.tagCounter.toString();
    while (num.length < 3) {
      num = '0' + num;
    }
    return 'a' + num;
  }

  /**
   * Connect to IMAP server over TLS.
   */
  async connect(host: string, port: number): Promise<string> {
    this.tagCounter = 0;
    this.dataBuffer = '';
    this.connected = false;
    this.pendingTag = '';
    this.collectedLines = [];
    this.lineResolve = null;

    this.tlsSocket = socket.constructTLSSocketInstance();

    // Must bind to local address before connect
    this.log.info(this.TAG, `Binding local socket...`);
    await this.tlsSocket.bind({ address: '0.0.0.0' });

    // Prepare greeting promise BEFORE connect so we don't miss early data
    let greetingPromise = new Promise<string[]>((resolve, reject) => {
      this.lineResolve = resolve;
      // pendingTag stays empty — onData will resolve on first \r\n line
      let timer = setTimeout(() => {
        if (this.lineResolve) {
          this.lineResolve = null;
          reject(new Error('Timeout waiting for server greeting'));
        }
      }, 8000);
      // Wrap resolve to clear timer
      let origResolve = this.lineResolve;
      this.lineResolve = (lines: string[]) => {
        clearTimeout(timer);
        origResolve(lines);
      };
    });

    // Set up data handler
    this.tlsSocket.on('message', (value: socket.SocketMessageInfo) => {
      let data = buf2str(value.message);
      this.log.info(this.TAG, `[recv] ${data.length} bytes: ${data.substring(0, 120).replace(/\r\n/g, '\\r\\n')}`);
      this.onData(data);
    });

    let tlsConnectOptions: socket.TLSConnectOptions = {
      address: { address: host, port: port, family: 1 },
      secureOptions: {
        protocols: [socket.Protocol.TLSv12],
      },
    };

    this.log.info(this.TAG, `Connecting to ${host}:${port}...`);
    await this.tlsSocket.connect(tlsConnectOptions);
    this.connected = true;
    this.log.info(this.TAG, `TLS connected, waiting for greeting...`);

    // Wait for server greeting (untagged * OK ...)
    let greetingLines = await greetingPromise;
    let greeting = greetingLines.join('\n');
    this.log.info(this.TAG, `Server greeting: ${greeting.substring(0, 100)}`);
    return greeting;
  }

  /**
   * Login with username and password.
   */
  async login(user: string, pass: string): Promise<string> {
    // 1. 发送 ID 命令 (网易邮箱必须)
    // 格式: ID ("name" "client_name" "version" "1.0.0")
    try {
      let idTag = this.nextTag();
      let idCmd = `${idTag} ID ("name" "ClawdBot" "version" "1.0.0")\r\n`;
      await this.sendCommand(idTag, idCmd);
      this.log.info(this.TAG, 'Sent IMAP ID command');
    } catch (e) {
      // 部分服务器不支持 ID 命令，忽略错误继续尝试登录
      this.log.warn(this.TAG, 'ID command failed/ignored: ' + (e as Error).message);
    }

    // 2. 发送 LOGIN 命令
    let tag = this.nextTag();
    let cmd = `${tag} LOGIN ${this.quoteStr(user)} ${this.quoteStr(pass)}\r\n`;
    let response = await this.sendCommand(tag, cmd);
    let lastLine = response.length > 0 ? response[response.length - 1] : '';

    // 网易邮箱有时会返回 "Unsafe Login" 作为 LOGIN 的响应，或者在 SELECT 时报错
    // 如果 LOGIN 这一步就报错：
    if (!lastLine.includes('OK')) {
      throw new Error('Login failed: ' + lastLine);
    }

    this.log.info(this.TAG, 'Login successful');
    return lastLine;
  }

  /**
   * Select a mailbox (e.g., INBOX).
   */
  async selectMailbox(name: string): Promise<string> {
    let tag = this.nextTag();
    let cmd = `${tag} SELECT ${name}\r\n`;
    let response = await this.sendCommand(tag, cmd);
    let lastLine = response.length > 0 ? response[response.length - 1] : '';
    if (!lastLine.includes('OK')) {
      throw new Error('SELECT failed: ' + lastLine);
    }
    let exists = 0;
    for (let line of response) {
      let m = /\*\s+(\d+)\s+EXISTS/i.exec(line);
      if (m) {
        exists = parseInt(m[1]);
      }
    }
    this.log.info(this.TAG, `Selected ${name}: ${exists} messages`);
    return `${exists}`;
  }

  /**
   * Fetch recent emails (ENVELOPE data).
   */
  async fetchRecentEmails(count: number): Promise<EmailSummary[]> {
    let tag = this.nextTag();
    let statusCmd = `${tag} STATUS INBOX (MESSAGES)\r\n`;
    let statusResp = await this.sendCommand(tag, statusCmd);
    let totalMessages = 0;
    for (let line of statusResp) {
      let m = /MESSAGES\s+(\d+)/i.exec(line);
      if (m) {
        totalMessages = parseInt(m[1]);
      }
    }
    if (totalMessages === 0) {
      return [];
    }

    let start = Math.max(1, totalMessages - count + 1);
    let range = `${start}:${totalMessages}`;

    tag = this.nextTag();
    let cmd = `${tag} FETCH ${range} (ENVELOPE)\r\n`;
    let response = await this.sendCommand(tag, cmd);

    let emails: EmailSummary[] = [];
    for (let line of response) {
      if (!line.includes('ENVELOPE')) continue;
      let email = this.parseEnvelope(line);
      if (email) {
        emails.push(email);
      }
    }
    emails.reverse();
    this.log.info(this.TAG, `Fetched ${emails.length} email summaries`);
    return emails;
  }

  /**
   * Fetch email body text by sequence number.
   */
  async fetchEmailBody(seq: number): Promise<EmailBody> {
    let tag = this.nextTag();
    let cmd = `${tag} FETCH ${seq} (ENVELOPE BODY[TEXT])\r\n`;
    let response = await this.sendCommand(tag, cmd, 15000);

    let from = '';
    let subject = '';
    let date = '';
    let bodyParts: string[] = [];
    let inBody = false;

    for (let line of response) {
      if (line.includes('ENVELOPE')) {
        let env = this.parseEnvelope(line);
        if (env) {
          from = env.from;
          subject = env.subject;
          date = env.date;
        }
      }
      if (line.includes('BODY[TEXT]') || inBody) {
        if (!inBody) {
          let bodyStart = line.indexOf('BODY[TEXT]');
          let afterBody = line.substring(bodyStart);
          let braceIdx = afterBody.indexOf('}');
          if (braceIdx >= 0 && braceIdx + 1 < afterBody.length) {
            bodyParts.push(afterBody.substring(braceIdx + 1).trim());
          }
          inBody = true;
        } else if (line.startsWith(tag) || line.startsWith(')')) {
          inBody = false;
        } else {
          bodyParts.push(line);
        }
      }
    }

    let rawBody = bodyParts.join('\n');
    let decodedBody = this.decodeMimeBody(rawBody);
    if (decodedBody.length > 8000) {
      decodedBody = decodedBody.substring(0, 8000) + '\n...[truncated]';
    }

    let result: EmailBody = { seq: seq, from: from, subject: subject, date: date, body: decodedBody };
    this.log.info(this.TAG, `Fetched body for seq ${seq}: ${decodedBody.length} chars`);
    return result;
  }

  /**
   * Search emails by subject keyword.
   */
  async searchEmails(query: string): Promise<number[]> {
    let tag = this.nextTag();
    let cmd = `${tag} SEARCH SUBJECT ${this.quoteStr(query)}\r\n`;
    let response = await this.sendCommand(tag, cmd);

    let seqNums: number[] = [];
    for (let line of response) {
      if (line.startsWith('* SEARCH')) {
        let parts = line.substring(9).trim().split(/\s+/);
        for (let p of parts) {
          let n = parseInt(p);
          if (!isNaN(n)) {
            seqNums.push(n);
          }
        }
      }
    }
    this.log.info(this.TAG, `Search "${query}": found ${seqNums.length} messages`);
    return seqNums;
  }

  /**
   * Logout and close connection.
   */
  async logout(): Promise<void> {
    try {
      if (this.connected && this.tlsSocket) {
        let tag = this.nextTag();
        let cmd = `${tag} LOGOUT\r\n`;
        try {
          await this.sendRaw(cmd);
        } catch { /* ignore send errors during logout */ }
        await this.tlsSocket.close();
      }
    } catch (e) {
      this.log.warn(this.TAG, `Logout error: ${(e as Error).message}`);
    } finally {
      this.connected = false;
      this.tlsSocket = null;
      this.lineResolve = null;
    }
  }

  // ========== Internal methods ==========

  private onData(data: string): void {
    this.dataBuffer += data;
    let nlIdx = this.dataBuffer.indexOf('\r\n');
    while (nlIdx >= 0) {
      let line = this.dataBuffer.substring(0, nlIdx);
      this.dataBuffer = this.dataBuffer.substring(nlIdx + 2);
      this.collectedLines.push(line);

      if (this.pendingTag.length > 0) {
        // Waiting for a tagged response — resolve when tag line arrives
        if (line.startsWith(this.pendingTag + ' ')) {
          this.finishPending();
        }
      } else {
        // No pending tag (greeting phase) — resolve immediately on any line
        this.finishPending();
      }

      nlIdx = this.dataBuffer.indexOf('\r\n');
    }
  }

  private finishPending(): void {
    if (this.lineResolve) {
      let resolve = this.lineResolve;
      this.lineResolve = null;
      this.pendingTag = '';
      let lines = this.collectedLines.slice();
      this.collectedLines = [];
      resolve(lines);
    }
  }

  private async sendCommand(tag: string, cmd: string, timeoutMs: number = 10000): Promise<string[]> {
    // Drain any leftover lines
    this.collectedLines = [];
    this.pendingTag = tag;

    let promise = new Promise<string[]>((resolve, reject) => {
      this.lineResolve = resolve;
      let timer = setTimeout(() => {
        if (this.lineResolve) {
          this.lineResolve = null;
          if (this.collectedLines.length > 0) {
            let lines = this.collectedLines.slice();
            this.collectedLines = [];
            this.pendingTag = '';
            resolve(lines);
          } else {
            this.pendingTag = '';
            reject(new Error(`IMAP command timeout: ${tag}`));
          }
        }
      }, timeoutMs);
      // Wrap resolve to clear timer
      let origResolve = this.lineResolve;
      this.lineResolve = (lines: string[]) => {
        clearTimeout(timer);
        origResolve(lines);
      };
    });

    this.log.info(this.TAG, `[send] ${cmd.trim()}`);
    await this.sendRaw(cmd);

    return promise;
  }

  private async sendRaw(data: string): Promise<void> {
    if (!this.tlsSocket || !this.connected) {
      throw new Error('Not connected');
    }
    let encoded = str2buf(data);
    await this.tlsSocket.send(encoded);
  }

  private quoteStr(s: string): string {
    let escaped = s.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    return '"' + escaped + '"';
  }

  private parseEnvelope(line: string): EmailSummary | null {
    let seqMatch = /^\*\s+(\d+)\s+FETCH/i.exec(line);
    let seq = seqMatch ? parseInt(seqMatch[1]) : 0;

    let envIdx = line.indexOf('ENVELOPE (');
    if (envIdx < 0) return null;
    let envData = line.substring(envIdx + 10);

    let date = this.extractQuoted(envData, 0);
    let afterDate = this.skipField(envData, 0);
    let subject = this.extractQuoted(envData, afterDate);
    let afterSubject = this.skipField(envData, afterDate);
    let fromStr = this.extractFromField(envData, afterSubject);

    subject = this.decodeMimeWord(subject);
    fromStr = this.decodeMimeWord(fromStr);

    let result: EmailSummary = { seq: seq, from: fromStr, subject: subject, date: date };
    return result;
  }

  private extractQuoted(data: string, startPos: number): string {
    let i = startPos;
    while (i < data.length && (data[i] === ' ' || data[i] === '\t')) i++;
    if (i >= data.length) return '';

    if (data[i] === '"') {
      let end = data.indexOf('"', i + 1);
      if (end < 0) return data.substring(i + 1);
      return data.substring(i + 1, end);
    } else if (data[i] === 'N' && data.substring(i, i + 3) === 'NIL') {
      return '';
    } else if (data[i] === '{') {
      let braceEnd = data.indexOf('}', i);
      if (braceEnd >= 0) {
        let size = parseInt(data.substring(i + 1, braceEnd));
        if (!isNaN(size) && braceEnd + 1 + size <= data.length) {
          return data.substring(braceEnd + 1, braceEnd + 1 + size);
        }
      }
      return '';
    }
    return '';
  }

  private skipField(data: string, startPos: number): number {
    let i = startPos;
    while (i < data.length && (data[i] === ' ' || data[i] === '\t')) i++;
    if (i >= data.length) return i;

    if (data[i] === '"') {
      let end = data.indexOf('"', i + 1);
      return end >= 0 ? end + 1 : data.length;
    } else if (data[i] === 'N' && data.substring(i, i + 3) === 'NIL') {
      return i + 3;
    } else if (data[i] === '(') {
      let depth = 1;
      let j = i + 1;
      while (j < data.length && depth > 0) {
        if (data[j] === '(') depth++;
        else if (data[j] === ')') depth--;
        else if (data[j] === '"') {
          let qEnd = data.indexOf('"', j + 1);
          if (qEnd >= 0) j = qEnd;
        }
        j++;
      }
      return j;
    } else if (data[i] === '{') {
      let braceEnd = data.indexOf('}', i);
      if (braceEnd >= 0) {
        let size = parseInt(data.substring(i + 1, braceEnd));
        if (!isNaN(size)) return braceEnd + 1 + size;
      }
      return data.length;
    }
    while (i < data.length && data[i] !== ' ' && data[i] !== ')') i++;
    return i;
  }

  private extractFromField(data: string, startPos: number): string {
    let i = startPos;
    while (i < data.length && (data[i] === ' ' || data[i] === '\t')) i++;
    if (i >= data.length || data[i] === 'N') return '';
    if (data[i] !== '(') return '';

    let inner = i + 1;
    while (inner < data.length && (data[inner] === ' ' || data[inner] === '\t')) inner++;
    if (inner >= data.length || data[inner] !== '(') return '';

    let addrData = data.substring(inner + 1);
    let name = this.extractQuoted(addrData, 0);
    let afterName = this.skipField(addrData, 0);
    let afterRoute = this.skipField(addrData, afterName);
    let mailbox = this.extractQuoted(addrData, afterRoute);
    let afterMailbox = this.skipField(addrData, afterRoute);
    let host = this.extractQuoted(addrData, afterMailbox);

    let email = mailbox.length > 0 && host.length > 0 ? `${mailbox}@${host}` : mailbox;
    if (name.length > 0) {
      return `${name} <${email}>`;
    }
    return email;
  }

  private decodeMimeWord(input: string): string {
    if (!input.includes('=?')) return input;
    let result = input;
    let re = /=\?([^?]+)\?([BbQq])\?([^?]*)\?=/g;
    let match: RegExpExecArray | null = re.exec(result);
    while (match !== null) {
      let encoding = match[2].toUpperCase();
      let encoded = match[3];
      let decoded = '';
      if (encoding === 'B') {
        decoded = this.decodeBase64(encoded);
      } else if (encoding === 'Q') {
        decoded = encoded.replace(/_/g, ' ');
        decoded = this.decodeQuotedPrintable(decoded);
      }
      result = result.substring(0, match.index) + decoded + result.substring(match.index + match[0].length);
      re.lastIndex = match.index + decoded.length;
      match = re.exec(result);
    }
    return result;
  }

  private decodeMimeBody(body: string): string {
    let text = body;
    if (text.includes('<html') || text.includes('<HTML') || text.includes('<div') || text.includes('<p>')) {
      text = text.replace(/<style[\s\S]*?<\/style>/gi, '');
      text = text.replace(/<script[\s\S]*?<\/script>/gi, '');
      text = text.replace(/<br\s*\/?>/gi, '\n');
      text = text.replace(/<\/p>/gi, '\n');
      text = text.replace(/<\/div>/gi, '\n');
      text = text.replace(/<[^>]*>/g, '');
      text = text.replace(/&nbsp;/g, ' ');
      text = text.replace(/&amp;/g, '&');
      text = text.replace(/&lt;/g, '<');
      text = text.replace(/&gt;/g, '>');
      text = text.replace(/&quot;/g, '"');
      text = text.replace(/&#39;/g, "'");
    }
    text = text.replace(/=\r?\n/g, '');
    text = this.decodeQuotedPrintable(text);
    text = text.replace(/\r\n/g, '\n');
    text = text.replace(/\n{3,}/g, '\n\n');
    return text.trim();
  }

  private decodeQuotedPrintable(input: string): string {
    return input.replace(/=([0-9A-Fa-f]{2})/g, (_match: string, hex: string): string => {
      let code = parseInt(hex, 16);
      return String.fromCharCode(code);
    });
  }

  private decodeBase64(input: string): string {
    try {
      let chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
      let clean = input.replace(/[^A-Za-z0-9+/=]/g, '');
      let bytes: number[] = [];
      for (let i = 0; i < clean.length; i += 4) {
        let b1 = chars.indexOf(clean[i]);
        let b2 = i + 1 < clean.length ? chars.indexOf(clean[i + 1]) : 0;
        let b3 = i + 2 < clean.length ? chars.indexOf(clean[i + 2]) : 0;
        let b4 = i + 3 < clean.length ? chars.indexOf(clean[i + 3]) : 0;
        if (b1 < 0) b1 = 0;
        if (b2 < 0) b2 = 0;
        if (b3 < 0) b3 = 0;
        if (b4 < 0) b4 = 0;
        bytes.push((b1 << 2) | (b2 >> 4));
        if (clean[i + 2] !== '=') bytes.push(((b2 & 15) << 4) | (b3 >> 2));
        if (clean[i + 3] !== '=') bytes.push(((b3 & 3) << 6) | b4);
      }
      let result = '';
      for (let b of bytes) {
        result += String.fromCharCode(b);
      }
      return result;
    } catch {
      return input;
    }
  }
}

// ========== Buffer conversion helpers ==========

function buf2str(buf: ArrayBuffer): string {
  let view = new Uint8Array(buf);
  let result = '';
  for (let i = 0; i < view.length; i++) {
    result += String.fromCharCode(view[i]);
  }
  return result;
}

function str2buf(str: string): ArrayBuffer {
  let buf = new ArrayBuffer(str.length);
  let view = new Uint8Array(buf);
  for (let i = 0; i < str.length; i++) {
    view[i] = str.charCodeAt(i) & 0xFF;
  }
  return buf;
}
