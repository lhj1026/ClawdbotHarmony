// Network diagnostics page: HTTP reachability, WebSocket status, network info, portproxy check/fix
import { http, connection } from '@kit.NetworkKit';
import { preferences } from '@kit.ArkData';
import { NodeRuntime } from '../service/gateway/NodeRuntime';

const STATUS_PENDING: number = 0;
const STATUS_LOADING: number = 1;
const STATUS_SUCCESS: number = 2;
const STATUS_FAILURE: number = 3;

@Component
export struct NetworkDiagPage {
  // ---- HTTP check state ----
  @State httpStatus: number = STATUS_PENDING;
  @State httpDetail: string = '';
  @State httpExpanded: boolean = false;

  // ---- WebSocket check state ----
  @State wsStatus: number = STATUS_PENDING;
  @State wsDetail: string = '';
  @State wsExpanded: boolean = false;

  // ---- Network info state ----
  @State netStatus: number = STATUS_PENDING;
  @State netDetail: string = '';
  @State netExpanded: boolean = false;

  // ---- Advanced: portproxy ----
  @State portproxyResult: string = '';
  @State portproxyLoading: boolean = false;
  @State fixLoading: boolean = false;

  // ---- Gateway URL ----
  @State gatewayUrl: string = '';

  private getGatewayUrl(): string {
    try {
      let prefs = preferences.getPreferencesSync(getContext(), { name: 'gateway_settings' });
      let host = prefs.getSync('host', '192.168.1.68') as string;
      let port = prefs.getSync('port', '18789') as string;
      let useTls = prefs.getSync('useTls', false) as boolean;
      let scheme = useTls ? 'https' : 'http';
      return `${scheme}://${host}:${port}`;
    } catch (_e) {
      return 'http://192.168.1.68:18789';
    }
  }

  aboutToAppear(): void {
    this.gatewayUrl = this.getGatewayUrl();
    this.runAllChecks();
  }

  private runAllChecks(): void {
    this.checkHttp();
    this.checkWebSocket();
    this.checkNetwork();
  }

  private async checkHttp(): Promise<void> {
    this.httpStatus = STATUS_LOADING;
    this.httpDetail = '';
    try {
      let req = http.createHttp();
      let url = `${this.gatewayUrl}/health`;
      let resp = await req.request(url, {
        method: http.RequestMethod.GET,
        connectTimeout: 5000,
        readTimeout: 5000,
      });
      req.destroy();
      let body = String(resp.result);
      if (body.length > 300) {
        body = body.substring(0, 300) + '...';
      }
      if (resp.responseCode >= 200 && resp.responseCode < 300) {
        this.httpStatus = STATUS_SUCCESS;
        this.httpDetail = `HTTP ${resp.responseCode}\n${body}`;
      } else {
        this.httpStatus = STATUS_FAILURE;
        this.httpDetail = `HTTP ${resp.responseCode}\n${body}`;
      }
    } catch (e) {
      this.httpStatus = STATUS_FAILURE;
      this.httpDetail = `错误: ${JSON.stringify(e)}`;
    }
  }

  private checkWebSocket(): void {
    this.wsStatus = STATUS_LOADING;
    let nr = NodeRuntime.getInstance();
    if (nr.isOperatorConnected) {
      this.wsStatus = STATUS_SUCCESS;
      this.wsDetail = 'Operator WebSocket 已连接 ✓';
    } else if (nr.isConnected) {
      this.wsStatus = STATUS_SUCCESS;
      this.wsDetail = 'Node Session 已连接 (operator 未连接)';
    } else {
      this.wsStatus = STATUS_FAILURE;
      this.wsDetail = '未连接到 Gateway\n请在设置中启用 Gateway 连接';
    }
  }

  private async checkNetwork(): Promise<void> {
    this.netStatus = STATUS_LOADING;
    try {
      let netHandle = await connection.getDefaultNet();
      let cap = await connection.getNetCapabilities(netHandle);
      let props = await connection.getConnectionProperties(netHandle);
      let lines: string[] = [];

      if (cap.bearerTypes && cap.bearerTypes.length > 0) {
        let bt = cap.bearerTypes[0];
        let typeName: string;
        if (bt === 0) {
          typeName = 'WiFi';
        } else if (bt === 1) {
          typeName = '蜂窝网络';
        } else {
          typeName = `类型 ${bt}`;
        }
        lines.push(`网络类型: ${typeName}`);
      }

      if (props.linkAddresses && props.linkAddresses.length > 0) {
        for (let i = 0; i < props.linkAddresses.length; i++) {
          let la = props.linkAddresses[i];
          let addrStr = la.address?.address ?? '';
          if (addrStr.length > 0 && addrStr.indexOf(':') < 0) {
            // IPv4 only
            lines.push(`IP 地址: ${addrStr}/${la.prefixLength}`);
          }
        }
      }

      if (props.dnses && props.dnses.length > 0) {
        let dnsAddrs: string[] = [];
        for (let i = 0; i < props.dnses.length && i < 2; i++) {
          let d = props.dnses[i];
          if (d?.address) {
            dnsAddrs.push(d.address);
          }
        }
        if (dnsAddrs.length > 0) {
          lines.push(`DNS: ${dnsAddrs.join(', ')}`);
        }
      }

      if (lines.length > 0) {
        this.netStatus = STATUS_SUCCESS;
        this.netDetail = lines.join('\n');
      } else {
        this.netStatus = STATUS_FAILURE;
        this.netDetail = '无法获取网络信息';
      }
    } catch (e) {
      this.netStatus = STATUS_FAILURE;
      this.netDetail = `错误: ${JSON.stringify(e)}`;
    }
  }

  private async queryPortproxy(): Promise<void> {
    this.portproxyLoading = true;
    this.portproxyResult = '⏳ 正在发送查询命令...';
    try {
      let nr = NodeRuntime.getInstance();
      let runId = await nr.sendChatMessage(
        '请执行以下命令并直接返回原始命令输出（不要解释，不要格式化）:\nnetsh interface portproxy show v4tov4',
        undefined
      );
      this.portproxyResult = `✅ 命令已发送 (runId: ${runId})\n\n💬 结果将在主聊天界面显示`;
    } catch (e) {
      this.portproxyResult = `❌ 发送失败: ${JSON.stringify(e)}`;
    }
    this.portproxyLoading = false;
  }

  private async fixPortproxy(): Promise<void> {
    this.fixLoading = true;
    this.portproxyResult = '⏳ 正在发送修复命令...';
    try {
      let nr = NodeRuntime.getInstance();
      let cmd =
        '请以管理员权限依次执行以下命令并返回每条命令的执行结果（直接输出，不要解释）：\n' +
        '1. netsh interface portproxy delete v4tov4 listenaddress=0.0.0.0 listenport=18789\n' +
        '2. netsh interface portproxy add v4tov4 listenaddress=192.168.1.68 listenport=18789 connectaddress=172.17.9.26 connectport=18789\n' +
        '3. netsh interface portproxy show v4tov4';
      let runId = await nr.sendChatMessage(cmd, undefined);
      this.portproxyResult = `✅ 修复命令已发送 (runId: ${runId})\n\n💬 结果将在主聊天界面显示`;
    } catch (e) {
      this.portproxyResult = `❌ 发送失败: ${JSON.stringify(e)}`;
    }
    this.fixLoading = false;
  }

  private statusIcon(status: number): string {
    if (status === STATUS_LOADING) {
      return '⏳';
    }
    if (status === STATUS_SUCCESS) {
      return '✅';
    }
    if (status === STATUS_FAILURE) {
      return '❌';
    }
    return '○';
  }

  @Builder
  HttpCheckRow() {
    Column() {
      Row() {
        Text(this.statusIcon(this.httpStatus))
          .fontSize(16)
          .margin({ right: 10 })
        Text('手机 → Gateway HTTP 连通性')
          .fontSize(14)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
        if (this.httpDetail.length > 0) {
          Text(this.httpExpanded ? '▲' : '▼')
            .fontSize(11)
            .fontColor('#999999')
        }
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        if (this.httpDetail.length > 0) {
          this.httpExpanded = !this.httpExpanded;
        }
      })

      if (this.httpExpanded && this.httpDetail.length > 0) {
        Text(this.httpDetail)
          .fontSize(11)
          .fontColor('#555555')
          .width('100%')
          .padding({ left: 26, right: 4, bottom: 10 })
      }
    }
    .width('100%')
  }

  @Builder
  WsCheckRow() {
    Column() {
      Row() {
        Text(this.statusIcon(this.wsStatus))
          .fontSize(16)
          .margin({ right: 10 })
        Text('Gateway WebSocket 连接状态')
          .fontSize(14)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
        if (this.wsDetail.length > 0) {
          Text(this.wsExpanded ? '▲' : '▼')
            .fontSize(11)
            .fontColor('#999999')
        }
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        if (this.wsDetail.length > 0) {
          this.wsExpanded = !this.wsExpanded;
        }
      })

      if (this.wsExpanded && this.wsDetail.length > 0) {
        Text(this.wsDetail)
          .fontSize(11)
          .fontColor('#555555')
          .width('100%')
          .padding({ left: 26, right: 4, bottom: 10 })
      }
    }
    .width('100%')
  }

  @Builder
  NetCheckRow() {
    Column() {
      Row() {
        Text(this.statusIcon(this.netStatus))
          .fontSize(16)
          .margin({ right: 10 })
        Text('手机网络信息')
          .fontSize(14)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
        if (this.netDetail.length > 0) {
          Text(this.netExpanded ? '▲' : '▼')
            .fontSize(11)
            .fontColor('#999999')
        }
      }
      .width('100%')
      .padding({ top: 10, bottom: 10 })
      .onClick(() => {
        if (this.netDetail.length > 0) {
          this.netExpanded = !this.netExpanded;
        }
      })

      if (this.netExpanded && this.netDetail.length > 0) {
        Text(this.netDetail)
          .fontSize(11)
          .fontColor('#555555')
          .width('100%')
          .padding({ left: 26, right: 4, bottom: 10 })
      }
    }
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: 12 }) {
        // Recheck button
        Button('🔄 重新检查')
          .width('100%')
          .height(44)
          .backgroundColor('#D2691E')
          .fontColor(Color.White)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .borderRadius(10)
          .onClick(() => {
            this.httpStatus = STATUS_PENDING;
            this.wsStatus = STATUS_PENDING;
            this.netStatus = STATUS_PENDING;
            this.portproxyResult = '';
            this.httpExpanded = false;
            this.wsExpanded = false;
            this.netExpanded = false;
            this.gatewayUrl = this.getGatewayUrl();
            this.runAllChecks();
          })

        Text(`Gateway: ${this.gatewayUrl}`)
          .fontSize(11)
          .fontColor('#999999')
          .width('100%')
          .padding({ left: 4 })

        // Basic checks card
        Column() {
          Text('基础检查')
            .fontSize(13)
            .fontColor('#D2691E')
            .fontWeight(FontWeight.Bold)
            .width('100%')
            .margin({ bottom: 4 })

          this.HttpCheckRow()
          Divider().color('#F0F0F0')
          this.WsCheckRow()
          Divider().color('#F0F0F0')
          this.NetCheckRow()
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(12)

        // Advanced section card
        Column({ space: 10 }) {
          Text('高级操作')
            .fontSize(13)
            .fontColor('#D2691E')
            .fontWeight(FontWeight.Bold)
            .width('100%')

          Text('需要 Gateway WebSocket 已连接。命令通过 AI Agent 执行，结果在主聊天界面显示。')
            .fontSize(11)
            .fontColor('#999999')
            .width('100%')

          Row({ space: 10 }) {
            Button(this.portproxyLoading ? '⏳ 发送中...' : '🔍 查询 portproxy')
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.wsStatus === STATUS_SUCCESS ? '#D2691E' : '#CCCCCC')
              .fontColor(Color.White)
              .fontSize(13)
              .borderRadius(8)
              .enabled(this.wsStatus === STATUS_SUCCESS && !this.portproxyLoading && !this.fixLoading)
              .onClick(() => {
                this.queryPortproxy();
              })

            Button(this.fixLoading ? '⏳ 发送中...' : '🔧 修复 portproxy')
              .layoutWeight(1)
              .height(40)
              .backgroundColor(this.wsStatus === STATUS_SUCCESS ? '#8B2500' : '#CCCCCC')
              .fontColor(Color.White)
              .fontSize(13)
              .borderRadius(8)
              .enabled(this.wsStatus === STATUS_SUCCESS && !this.portproxyLoading && !this.fixLoading)
              .onClick(() => {
                this.fixPortproxy();
              })
          }
          .width('100%')

          if (this.portproxyResult.length > 0) {
            Scroll() {
              Text(this.portproxyResult)
                .fontSize(12)
                .fontColor('#1A1A1A')
                .width('100%')
            }
            .width('100%')
            .height(120)
            .backgroundColor('#F5F5F5')
            .borderRadius(8)
            .padding(10)
          }
        }
        .width('100%')
        .padding(16)
        .backgroundColor(Color.White)
        .borderRadius(12)
      }
      .padding({ left: 16, right: 16, top: 16, bottom: 32 })
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F2F7')
  }
}
