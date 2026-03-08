/**
 * Handles proxy.fetch commands from the gateway.
 * Fetches URLs via the phone's China network environment, used for WeChat article retrieval.
 */
import http from '@ohos.net.http';
import { LogService } from '../../common/LogService';

const TAG = 'ProxyCap';

// Default headers to simulate WeChat in-app browser (微信内置浏览器)
const WECHAT_UA = 'Mozilla/5.0 (Linux; Android 14; SM-S9280) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.6099.230 Mobile Safari/537.36 MicroMessenger/8.0.49.2575(0x2800315B) NetType/WIFI Language/zh_CN';
const WECHAT_REFERER = 'https://mp.weixin.qq.com/';

interface ProxyParams {
  url: string;
  headers?: Record<string, string>;
}

interface ProxyResult {
  status: number;
  body: string;
  headers: Record<string, string>;
}

interface ProxyError {
  error: string;
}

export class ProxyCapability {
  private log: LogService = LogService.getInstance();

  async execute(paramsJson: string | undefined): Promise<string> {
    this.log.info(TAG, `execute: params=${paramsJson ?? 'none'}`);

    if (!paramsJson || paramsJson.length === 0) {
      return JSON.stringify({ error: 'No params provided' } as ProxyError);
    }

    let params: ProxyParams;
    try {
      params = JSON.parse(paramsJson) as ProxyParams;
    } catch {
      return JSON.stringify({ error: 'Invalid JSON params' } as ProxyError);
    }

    let url = params.url;
    if (!url || url.length === 0) {
      return JSON.stringify({ error: 'No url provided' } as ProxyError);
    }

    this.log.info(TAG, `Fetching URL: ${url}`);

    return new Promise<string>((resolve) => {
      let httpRequest = http.createHttp();

      // Merge default WeChat headers with caller-provided headers
      let mergedHeaders: Record<string, string> = {
        'User-Agent': WECHAT_UA,
        'Referer': WECHAT_REFERER,
        'Accept': 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
        'Accept-Language': 'zh-CN,zh;q=0.9',
      };
      if (params.headers) {
        let extra = params.headers;
        let keys = Object.keys(extra);
        for (let i = 0; i < keys.length; i++) {
          mergedHeaders[keys[i]] = extra[keys[i]];
        }
      }

      httpRequest.request(
        url,
        {
          method: http.RequestMethod.GET,
          header: mergedHeaders,
          connectTimeout: 15000,
          readTimeout: 30000,
        },
        (err, data) => {
          httpRequest.destroy();
          if (err) {
            let msg = (err as Error).message ?? String(err);
            this.log.error(TAG, `HTTP request failed: ${msg}`);
            resolve(JSON.stringify({ error: msg } as ProxyError));
            return;
          }

          let bodyStr: string;
          if (typeof data.result === 'string') {
            bodyStr = data.result as string;
          } else {
            bodyStr = String(data.result);
          }

          // Limit body to 500KB to avoid WebSocket overflow
          if (bodyStr.length > 500000) {
            bodyStr = bodyStr.substring(0, 500000) + '\n...[truncated]';
          }

          let respHeaders: Record<string, string> = {};
          if (data.header) {
            let hdr = data.header as Record<string, string>;
            let hkeys = Object.keys(hdr);
            for (let i = 0; i < hkeys.length; i++) {
              respHeaders[hkeys[i]] = hdr[hkeys[i]];
            }
          }

          let result: ProxyResult = {
            status: data.responseCode,
            body: bodyStr,
            headers: respHeaders,
          };

          this.log.info(TAG, `Fetch done: status=${data.responseCode} bodyLen=${bodyStr.length}`);
          resolve(JSON.stringify(result));
        }
      );
    });
  }
}
