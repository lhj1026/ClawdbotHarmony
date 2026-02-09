/**
 * Orchestrates two GatewaySession instances (operator + node) and
 * dispatches invoke requests to capability handlers.
 * Ported from Android NodeRuntime.kt.
 */
import { common } from '@kit.AbilityKit';
import { GatewaySession } from './GatewaySession';
import { DeviceIdentityStore } from './DeviceIdentityStore';
import { DeviceAuthStore } from './DeviceAuthStore';
import { LocationCapability } from './LocationCapability';
import { NotificationCapability } from './NotificationCapability';
import { CameraCapability } from './CameraCapability';
import { CanvasCapability } from './CanvasCapability';
import { SmsCapability } from './SmsCapability';
import { ScreenCapability } from './ScreenCapability';
import { GatewayProtocol } from './GatewayProtocol';
import { Capability, Command } from './GatewayProtocol';
import {
  GatewayEndpoint,
  ConnectionState,
  ConnectOptions,
  ClientInfo,
  InvokeRequest,
  InvokeResult,
  GatewayChatEvent,
  GatewayChatContentBlock,
} from './GatewayModels';
import { LogService } from '../../common/LogService';

const TAG = 'NodeRuntime';
const APP_VERSION = '1.0.0';

export class NodeRuntime {
  private static instance: NodeRuntime | undefined = undefined;

  private log: LogService = LogService.getInstance();

  private identityStore: DeviceIdentityStore = new DeviceIdentityStore();
  private authStore: DeviceAuthStore = new DeviceAuthStore();

  private operatorSession: GatewaySession | undefined = undefined;
  private nodeSession: GatewaySession | undefined = undefined;

  // Capabilities
  private locationCapability: LocationCapability = new LocationCapability();
  private notificationCapability: NotificationCapability = new NotificationCapability();
  private cameraCapability: CameraCapability = new CameraCapability();
  private canvasCapability: CanvasCapability = new CanvasCapability();
  private smsCapability: SmsCapability = new SmsCapability();
  private screenCapability: ScreenCapability = new ScreenCapability();

  // Capability toggles (default all enabled)
  private _capLocation: boolean = true;
  private _capCamera: boolean = true;
  private _capCanvas: boolean = true;
  private _capScreen: boolean = true;
  private _capNotification: boolean = true;
  private _capSms: boolean = true;

  // Observable state
  private _operatorState: ConnectionState = ConnectionState.Disconnected;
  private _nodeState: ConnectionState = ConnectionState.Disconnected;
  private _statusText: string = 'Offline';
  private _listeners: Array<(state: ConnectionState, text: string) => void> = [];

  // Chat via gateway
  private _chatListeners: Array<(event: GatewayChatEvent) => void> = [];
  private _chatIdCounter: number = 0;

  static getInstance(): NodeRuntime {
    if (!NodeRuntime.instance) {
      NodeRuntime.instance = new NodeRuntime();
    }
    return NodeRuntime.instance;
  }

  get connectionState(): ConnectionState {
    if (this._operatorState === ConnectionState.Connected &&
        this._nodeState === ConnectionState.Connected) {
      return ConnectionState.Connected;
    }
    if (this._operatorState === ConnectionState.Connected ||
        this._nodeState === ConnectionState.Connected) {
      return ConnectionState.Connected;
    }
    if (this._operatorState === ConnectionState.Connecting ||
        this._nodeState === ConnectionState.Connecting) {
      return ConnectionState.Connecting;
    }
    if (this._operatorState === ConnectionState.Reconnecting ||
        this._nodeState === ConnectionState.Reconnecting) {
      return ConnectionState.Reconnecting;
    }
    if (this._operatorState === ConnectionState.Error ||
        this._nodeState === ConnectionState.Error) {
      return ConnectionState.Error;
    }
    return ConnectionState.Disconnected;
  }

  get statusText(): string {
    return this._statusText;
  }

  get isConnected(): boolean {
    return this._operatorState === ConnectionState.Connected ||
           this._nodeState === ConnectionState.Connected;
  }

  /** Expose canvas capability for CanvasPage to register its controller */
  getCanvasCapability(): CanvasCapability {
    return this.canvasCapability;
  }

  /** Update which capabilities are enabled (called from SettingsPage) */
  updateCapabilities(location: boolean, camera: boolean, canvas: boolean,
                     screen: boolean, notification: boolean, sms?: boolean): void {
    this._capLocation = location;
    this._capCamera = camera;
    this._capCanvas = canvas;
    this._capScreen = screen;
    this._capNotification = notification;
    if (sms !== undefined) {
      this._capSms = sms;
    }
    this.log.info(TAG, `Capabilities updated: location=${location} camera=${camera} canvas=${canvas} screen=${screen} notification=${notification} sms=${this._capSms}`);
  }

  addStateListener(listener: (state: ConnectionState, text: string) => void): void {
    this._listeners.push(listener);
  }

  removeStateListener(listener: (state: ConnectionState, text: string) => void): void {
    let idx = this._listeners.indexOf(listener);
    if (idx >= 0) {
      this._listeners.splice(idx, 1);
    }
  }

  // ---- Chat via gateway (operator session) ----

  addChatListener(listener: (event: GatewayChatEvent) => void): void {
    this._chatListeners.push(listener);
  }

  removeChatListener(listener: (event: GatewayChatEvent) => void): void {
    let idx = this._chatListeners.indexOf(listener);
    if (idx >= 0) {
      this._chatListeners.splice(idx, 1);
    }
  }

  /**
   * Send a chat message through the gateway operator session.
   * Returns the runId for tracking the response.
   * Responses come back as 'chat' events (delta/final/error) via chat listeners.
   */
  async sendChatMessage(text: string): Promise<string> {
    if (!this.operatorSession) {
      throw new Error('Gateway not connected');
    }
    if (this._operatorState !== ConnectionState.Connected) {
      throw new Error('Operator session not connected');
    }

    this._chatIdCounter++;
    let idempotencyKey = `harmony-${Date.now()}-${this._chatIdCounter}`;
    let sessionKey = 'agent:main:main';

    let params = `{"sessionKey":${JSON.stringify(sessionKey)},"message":${JSON.stringify(text)},"idempotencyKey":${JSON.stringify(idempotencyKey)}}`;
    this.log.info(TAG, `sendChatMessage: key=${idempotencyKey} text=${text.substring(0, 100)}`);

    let resJson = await this.operatorSession.request('chat.send', params, 30000);
    this.log.info(TAG, `chat.send response: ${resJson.substring(0, 200)}`);

    // Extract runId from response
    let runId = idempotencyKey; // fallback
    if (resJson.length > 0) {
      try {
        let resObj = JSON.parse(resJson) as Record<string, string>;
        if (resObj['runId']) {
          runId = resObj['runId'];
        }
      } catch { /* use fallback */ }
    }
    return runId;
  }

  private dispatchChatEvent(event: GatewayChatEvent): void {
    this.log.info(TAG, `chatEvent: state=${event.state} runId=${event.runId} seq=${event.seq}`);
    for (let listener of this._chatListeners) {
      try {
        listener(event);
      } catch {
        // ignore
      }
    }
  }

  connect(context: common.UIAbilityContext, endpoint: GatewayEndpoint, token?: string, password?: string): void {
    // Disconnect existing sessions if any
    this.disconnect();

    this.log.info(TAG, `connect() called: ${endpoint.host}:${endpoint.port} tls=${endpoint.useTls} token=${token ? 'yes' : 'no'} password=${password ? 'yes' : 'no'}`);

    // Set context for capabilities that need file system access
    this.cameraCapability.setContext(context);
    this.screenCapability.setContext(context);

    // Create operator session
    let operatorOpts = this.buildOperatorOptions();
    this.log.info(TAG, `Creating operator session: clientId=${operatorOpts.client.id} mode=${operatorOpts.client.mode} role=${operatorOpts.role}`);
    this.operatorSession = new GatewaySession(operatorOpts, this.identityStore, this.authStore);
    this.operatorSession.onStateChanged = (state, message) => {
      this._operatorState = state;
      this.updateStatus();
      this.log.info(TAG, `operator state: ${state} - ${message}`);
    };
    this.operatorSession.onEvent = (event, payloadJson) => {
      this.handleOperatorEvent(event, payloadJson);
    };

    // Create node session
    let nodeOpts = this.buildNodeOptions();
    this.log.info(TAG, `Creating node session: clientId=${nodeOpts.client.id} mode=${nodeOpts.client.mode} role=${nodeOpts.role} caps=[${nodeOpts.caps.join(',')}] commands=[${nodeOpts.commands.join(',')}]`);
    this.nodeSession = new GatewaySession(nodeOpts, this.identityStore, this.authStore);
    this.nodeSession.onStateChanged = (state, message) => {
      this._nodeState = state;
      this.updateStatus();
      this.log.info(TAG, `node state: ${state} - ${message}`);
    };
    this.nodeSession.onEvent = (event, payloadJson) => {
      this.log.debug(TAG, `node event: ${event} payloadLen=${payloadJson ? payloadJson.length : 0}`);
    };
    this.nodeSession.onInvokeRequest = async (req: InvokeRequest): Promise<InvokeResult> => {
      return await this.handleInvoke(req);
    };

    // Connect both sessions (fire-and-forget, state updates via callbacks)
    this.log.info(TAG, 'Connecting operator session...');
    this.operatorSession.connect(context, endpoint, token, password);
    this.log.info(TAG, 'Connecting node session...');
    this.nodeSession.connect(context, endpoint, token, password);
  }

  disconnect(): void {
    this.log.info(TAG, 'disconnect() called');
    if (this.operatorSession) {
      this.log.info(TAG, 'Disconnecting operator session');
      this.operatorSession.disconnect();
      this.operatorSession = undefined;
    }
    if (this.nodeSession) {
      this.log.info(TAG, 'Disconnecting node session');
      this.nodeSession.disconnect();
      this.nodeSession = undefined;
    }
    this._operatorState = ConnectionState.Disconnected;
    this._nodeState = ConnectionState.Disconnected;
    this.updateStatus();
  }

  private updateStatus(): void {
    let opConnected = this._operatorState === ConnectionState.Connected;
    let nodeConnected = this._nodeState === ConnectionState.Connected;

    let oldStatus = this._statusText;

    if (opConnected && nodeConnected) {
      this._statusText = 'Connected';
    } else if (opConnected && !nodeConnected) {
      this._statusText = 'Connected (node offline)';
    } else if (!opConnected && nodeConnected) {
      this._statusText = 'Connected (operator offline)';
    } else if (this._operatorState === ConnectionState.Connecting ||
               this._nodeState === ConnectionState.Connecting) {
      this._statusText = 'Connecting…';
    } else if (this._operatorState === ConnectionState.Reconnecting ||
               this._nodeState === ConnectionState.Reconnecting) {
      this._statusText = 'Reconnecting…';
    } else if (this._operatorState === ConnectionState.Error ||
               this._nodeState === ConnectionState.Error) {
      this._statusText = 'Error';
    } else {
      this._statusText = 'Offline';
    }

    if (oldStatus !== this._statusText) {
      this.log.info(TAG, `Status changed: "${oldStatus}" → "${this._statusText}" (operator=${this._operatorState}, node=${this._nodeState})`);
    }

    let state = this.connectionState;
    for (let listener of this._listeners) {
      try {
        listener(state, this._statusText);
      } catch {
        // ignore
      }
    }
  }

  private async handleInvoke(req: InvokeRequest): Promise<InvokeResult> {
    let command = req.command;
    let paramsJson = req.paramsJSON ?? (req.params ? JSON.stringify(req.params) : undefined);

    this.log.info(TAG, `invoke: command=${command} params=${paramsJson ?? 'none'}`);

    try {
      switch (command) {
        case Command.LOCATION_GET: {
          this.log.info(TAG, 'Executing location.get capability...');
          let result = await this.locationCapability.execute(paramsJson);
          this.log.info(TAG, `location.get result: ${result}`);
          return InvokeResult.success(result);
        }
        case Command.NOTIFICATION_SHOW: {
          this.log.info(TAG, 'Executing notification.show capability...');
          let result = await this.notificationCapability.execute(paramsJson);
          this.log.info(TAG, `notification.show result: ${result}`);
          return InvokeResult.success(result);
        }
        case Command.CAMERA_SNAP:
        case Command.CAMERA_CLIP: {
          this.log.info(TAG, `Executing ${command} capability...`);
          let result = await this.cameraCapability.execute(command, paramsJson);
          this.log.info(TAG, `${command} result: ${result.substring(0, 200)}`);
          return InvokeResult.success(result);
        }
        case Command.CANVAS_PRESENT:
        case Command.CANVAS_HIDE:
        case Command.CANVAS_NAVIGATE:
        case Command.CANVAS_EVAL:
        case Command.CANVAS_SNAPSHOT: {
          this.log.info(TAG, `Executing ${command} capability...`);
          let result = await this.canvasCapability.execute(command, paramsJson);
          this.log.info(TAG, `${command} result: ${result.substring(0, 200)}`);
          return InvokeResult.success(result);
        }
        case Command.SMS_SEND: {
          this.log.info(TAG, 'Executing sms.send capability...');
          let result = await this.smsCapability.execute(paramsJson);
          this.log.info(TAG, `sms.send result: ${result}`);
          return InvokeResult.success(result);
        }
        case Command.SCREEN_RECORD: {
          this.log.info(TAG, 'Executing screen.record capability...');
          let result = await this.screenCapability.execute(paramsJson);
          this.log.info(TAG, `screen.record result: ${result.substring(0, 200)}`);
          return InvokeResult.success(result);
        }
        default:
          this.log.warn(TAG, `Unsupported invoke command: ${command}`);
          return InvokeResult.error('INVALID_REQUEST', `unsupported command: ${command}`);
      }
    } catch (err) {
      let message = (err as Error).message ?? 'invoke failed';
      this.log.error(TAG, `invoke error for ${command}: ${message}`);
      return InvokeResult.error('UNAVAILABLE', message);
    }
  }

  private handleOperatorEvent(event: string, payloadJson: string | undefined): void {
    this.log.info(TAG, `operator event: "${event}" payloadLen=${payloadJson ? payloadJson.length : 0} payload(200)=${payloadJson ? payloadJson.substring(0, 200) : '(none)'}`);

    if (!payloadJson) return;

    // Handle 'agent' event format (streaming from gateway)
    // Wire format: { runId, stream, data: { text }, delta, sessionKey, seq, ts }
    // Or: { runId, stream, text, delta, sessionKey, seq, ts }
    // delta=true means streaming chunk, delta=false or done=true means final
    if (event === 'agent') {
      try {
        let raw = JSON.parse(payloadJson) as Record<string, Object>;

        // Log the raw keys for debugging
        let rawKeys = Object.keys(raw);
        this.log.info(TAG, `agent event keys: [${rawKeys.join(',')}] payload(300): ${payloadJson.substring(0, 300)}`);

        let runId: string = (raw['runId'] as string) ?? '';
        let stream: string = (raw['stream'] as string) ?? '';
        let seq: number = (raw['seq'] as number) ?? 0;
        let sessionKey: string = (raw['sessionKey'] as string) ?? '';

        // Extract text: try data.text first, then top-level text
        let fullText: string = '';
        let dataObj = raw['data'] as Record<string, Object> | undefined;
        if (dataObj !== undefined && dataObj !== null) {
          if (dataObj['text'] !== undefined) {
            fullText = String(dataObj['text']);
          }
        }
        if (fullText.length === 0 && raw['text'] !== undefined) {
          fullText = String(raw['text']);
        }

        // Determine state from multiple signals:
        // 1. Explicit 'state' field
        // 2. 'done' boolean field
        // 3. 'delta' boolean field (delta=false on last chunk means final)
        // 4. 'type' field (some gateways use type='done')
        let chatState: string = 'delta';

        let explicitState: string = '';
        if (raw['state'] !== undefined) {
          explicitState = String(raw['state']);
        }

        if (explicitState === 'final' || explicitState === 'done' || explicitState === 'complete' || explicitState === 'finished') {
          chatState = 'final';
        } else if (explicitState === 'error') {
          chatState = 'error';
        } else if (explicitState === 'aborted') {
          chatState = 'aborted';
        }

        // Check 'done' boolean
        if (chatState === 'delta' && raw['done'] !== undefined) {
          let doneVal = raw['done'];
          if (doneVal === true || doneVal as boolean === true || String(doneVal) === 'true') {
            chatState = 'final';
          }
        }

        // Check 'delta' boolean — delta=false on a non-zero seq means final
        if (chatState === 'delta' && raw['delta'] !== undefined) {
          let deltaVal = raw['delta'];
          if (deltaVal === false || String(deltaVal) === 'false') {
            chatState = 'final';
          }
        }

        // Check 'type' field
        if (chatState === 'delta' && raw['type'] !== undefined) {
          let typeVal = String(raw['type']);
          if (typeVal === 'done' || typeVal === 'final' || typeVal === 'complete') {
            chatState = 'final';
          } else if (typeVal === 'error') {
            chatState = 'error';
          }
        }

        // Check stopReason — if present, this is likely the final event
        let stopReason: string = '';
        if (raw['stopReason'] !== undefined) {
          stopReason = String(raw['stopReason']);
          if (chatState === 'delta' && stopReason.length > 0) {
            chatState = 'final';
          }
        }

        // Build GatewayChatEvent with text
        let errorMsg: string | undefined = undefined;
        if (raw['errorMessage'] !== undefined) {
          errorMsg = String(raw['errorMessage']);
        } else if (raw['error'] !== undefined) {
          errorMsg = String(raw['error']);
        }

        // Always build the message with content blocks (even if empty)
        let blocks: GatewayChatContentBlock[] = [];
        if (fullText.length > 0) {
          let block: GatewayChatContentBlock = { type: 'text', text: fullText };
          blocks.push(block);
        }

        let msgRole: string = stream.length > 0 ? stream : 'assistant';
        let msgTs: number | undefined = (raw['ts'] as number) ?? undefined;

        let chatEvent: GatewayChatEvent = {
          runId: runId,
          sessionKey: sessionKey,
          seq: seq,
          state: chatState,
          message: { role: msgRole, content: blocks, timestamp: msgTs },
          errorMessage: errorMsg,
          stopReason: stopReason.length > 0 ? stopReason : undefined,
        };

        this.log.info(TAG, `agentChat: state=${chatState} runId=${runId} seq=${seq} textLen=${fullText.length} blocks=${blocks.length} text(100)="${fullText.substring(0, 100)}"`);
        this.dispatchChatEvent(chatEvent);
      } catch (err) {
        this.log.error(TAG, `Failed to parse agent event: ${(err as Error).message ?? ''}`);
      }
      return;
    }

    // Handle 'chat' event format (legacy / direct chat.send response)
    if (event === 'chat') {
      try {
        let raw = JSON.parse(payloadJson) as Record<string, Object>;
        let runId: string = (raw['runId'] as string) ?? '';
        let state: string = (raw['state'] as string) ?? '';

        let chatEvent: GatewayChatEvent = {
          runId: runId,
          sessionKey: (raw['sessionKey'] as string) ?? '',
          seq: (raw['seq'] as number) ?? 0,
          state: state,
          errorMessage: (raw['errorMessage'] as string) ?? undefined,
          stopReason: (raw['stopReason'] as string) ?? undefined,
        };

        let msgRaw = raw['message'] as Record<string, Object> | undefined;
        if (msgRaw) {
          let contentRaw: Object = msgRaw['content'];
          let blocks: GatewayChatContentBlock[] = [];
          if (Array.isArray(contentRaw)) {
            let contentArr: Object[] = contentRaw as Object[];
            for (let i = 0; i < contentArr.length; i++) {
              let block: Record<string, string> = contentArr[i] as Record<string, string>;
              let blockText: string = block['text'] ?? '';
              let b: GatewayChatContentBlock = {
                type: block['type'] ?? 'text',
                text: blockText.length > 0 ? blockText : undefined,
              };
              blocks.push(b);
            }
          } else if (typeof contentRaw === 'string') {
            let b: GatewayChatContentBlock = { type: 'text', text: contentRaw as string };
            blocks.push(b);
          }
          chatEvent.message = {
            role: (msgRaw['role'] as string) ?? 'assistant',
            content: blocks,
            timestamp: (msgRaw['timestamp'] as number) ?? undefined,
          };
        }

        this.dispatchChatEvent(chatEvent);
      } catch (err) {
        this.log.error(TAG, `Failed to parse chat event: ${(err as Error).message ?? ''}`);
      }
      return;
    }

    // Other operator events: voice wake, branding, presence, health, etc.
  }

  private buildClientInfo(clientId: string, clientMode: string): ClientInfo {
    return {
      id: clientId,
      version: APP_VERSION,
      platform: 'HarmonyOS',
      mode: clientMode,
      deviceFamily: 'HarmonyOS',
    };
  }

  private buildOperatorOptions(): ConnectOptions {
    return {
      role: 'operator',
      scopes: ['operator.read', 'operator.write'],
      caps: [],
      commands: [],
      permissions: {} as Record<string, boolean>,
      client: this.buildClientInfo('openclaw-control-ui', 'ui'),
      userAgent: `ClawdBotHarmony/${APP_VERSION} (HarmonyOS NEXT)`,
    };
  }

  private buildNodeOptions(): ConnectOptions {
    let caps: string[] = [];
    let commands: string[] = [];

    if (this._capLocation) {
      caps.push(Capability.Location);
      commands.push(Command.LOCATION_GET);
    }
    if (this._capCamera) {
      caps.push(Capability.Camera);
      commands.push(Command.CAMERA_SNAP);
      commands.push(Command.CAMERA_CLIP);
    }
    if (this._capCanvas) {
      caps.push(Capability.Canvas);
      commands.push(Command.CANVAS_PRESENT);
      commands.push(Command.CANVAS_HIDE);
      commands.push(Command.CANVAS_NAVIGATE);
      commands.push(Command.CANVAS_EVAL);
      commands.push(Command.CANVAS_SNAPSHOT);
    }
    if (this._capScreen) {
      caps.push(Capability.Screen);
      commands.push(Command.SCREEN_RECORD);
    }
    if (this._capNotification) {
      caps.push(Capability.Notification);
      commands.push(Command.NOTIFICATION_SHOW);
    }
    if (this._capSms) {
      caps.push(Capability.Sms);
      commands.push(Command.SMS_SEND);
    }

    return {
      role: 'node',
      scopes: [],
      caps: caps,
      commands: commands,
      permissions: {} as Record<string, boolean>,
      client: this.buildClientInfo('openclaw-android', 'node'),
      userAgent: `ClawdBotHarmony/${APP_VERSION} (HarmonyOS NEXT)`,
    };
  }
}
