// 文件路径: entry/src/main/ets/service/SmtpService.ets
import socket from '@ohos.net.socket';
import { util } from '@kit.ArkTS';
import { LogService } from '../common/LogService';

export class SmtpService {
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'SmtpService';
  private tlsSocket: socket.TLSSocket | null = null;

  async sendEmail(host: string, port: number, user: string, pass: string, to: string, subject: string, body: string): Promise<void> {
    this.tlsSocket = socket.constructTLSSocketInstance();

    // 绑定本地端口
    await this.tlsSocket.bind({ address: '0.0.0.0' });

    let connectOpts: socket.TLSConnectOptions = {
      address: { address: host, port: port, family: 1 },
      secureOptions: { protocols: [socket.Protocol.TLSv12] }
    };

    this.log.info(this.TAG, `Connecting to SMTP ${host}:${port}...`);

    return new Promise<void>(async (resolve, reject) => {
      let step = 0;

      this.tlsSocket!.on('message', async (msgInfo) => {
        let response = this.buf2str(msgInfo.message);
        this.log.info(this.TAG, `Server: ${response.trim()}`);

        try {
          // 简单的状态机处理 SMTP 握手
          if (step === 0 && response.startsWith('220')) {
            // 1. 发送 EHLO
            step++;
            await this.send(`EHLO ${host}\r\n`);
          } else if (step === 1 && response.includes('250')) {
            // 2. 请求登录
            step++;
            await this.send('AUTH LOGIN\r\n');
          } else if (step === 2 && response.startsWith('334')) {
            // 3. 发送用户名 (Base64)
            step++;
            let userB64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(this.str2buf(user)));
            await this.send(userB64 + '\r\n');
          } else if (step === 3 && response.startsWith('334')) {
            // 4. 发送密码 (Base64)
            step++;
            let passB64 = new util.Base64Helper().encodeToStringSync(new Uint8Array(this.str2buf(pass)));
            await this.send(passB64 + '\r\n');
          } else if (step === 4 && response.startsWith('235')) {
            // 5. 认证成功，发送发件人
            step++;
            await this.send(`MAIL FROM: <${user}>\r\n`);
          } else if (step === 5 && response.startsWith('250')) {
            // 6. 发送收件人
            step++;
            await this.send(`RCPT TO: <${to}>\r\n`);
          } else if (step === 6 && response.startsWith('250')) {
            // 7. 准备发送数据
            step++;
            await this.send('DATA\r\n');
          } else if (step === 7 && response.startsWith('354')) {
            // 8. 发送正文
            step++;
            let emailContent = this.buildEmailContent(user, to, subject, body);
            await this.send(emailContent + '\r\n.\r\n');
          } else if (step === 8 && response.startsWith('250')) {
            // 9. 发送完成，退出
            step++;
            await this.send('QUIT\r\n');
            resolve();
            this.close();
          } else if (response.startsWith('5') || response.startsWith('4')) {
            reject(new Error(`SMTP Error: ${response}`));
            this.close();
          }
        } catch (e) {
          reject(e);
          this.close();
        }
      });

      try {
        await this.tlsSocket!.connect(connectOpts);
      } catch (e) {
        reject(new Error('Connection failed: ' + e.message));
      }
    });
  }

  private buildEmailContent(from: string, to: string, subject: string, body: string): string {
    // 简单的 MIME 编码
    let subjectEncoded = `=${new util.Base64Helper().encodeToStringSync(new Uint8Array(this.str2buf(subject)))}?=`;
    return `From: ${from}
To: ${to}
Subject: =?UTF-8?B?${subjectEncoded}
MIME-Version: 1.0
Content-Type: text/plain; charset=UTF-8

${body}`;
  }

  private async send(data: string) {
    if (this.tlsSocket) {
      await this.tlsSocket.send(this.str2buf(data));
    }
  }

  private close() {
    if (this.tlsSocket) {
      this.tlsSocket.close();
      this.tlsSocket = null;
    }
  }

  private str2buf(str: string): ArrayBuffer {
    let buf = new ArrayBuffer(str.length);
    let view = new Uint8Array(buf);
    for (let i = 0; i < str.length; i++) {
      view[i] = str.charCodeAt(i);
    }
    return buf;
  }

  private buf2str(buf: ArrayBuffer): string {
    let view = new Uint8Array(buf);
    let str = '';
    for (let i = 0; i < view.length; i++) {
      str += String.fromCharCode(view[i]);
    }
    return str;
  }
}