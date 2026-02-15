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
import { NotificationCapability, NotificationInfo } from './NotificationCapability';
import { CameraCapability } from './CameraCapability';
import { CanvasCapability } from './CanvasCapability';
import { SmsCapability } from './SmsCapability';
import { ScreenCapability } from './ScreenCapability';
import { MicrophoneCapability } from './MicrophoneCapability';
import { SpeakerCapability } from './SpeakerCapability';
import { EmailCapability } from './EmailCapability';
import { CalendarCapability } from './CalendarCapability';
import { ExecCapability } from './ExecCapability';
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
  ExecApprovalRequest,
} from './GatewayModels';
import { image } from '@kit.ImageKit';
import { preferences } from '@kit.ArkData';
import { LogService } from '../../common/LogService';
import { Constants } from '../../common/Constants';

const TAG = 'NodeRuntime';
const APP_VERSION = '2.10.0';

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
  private canvasCapability: CanvasCapability = CanvasCapability.getInstance();
  private smsCapability: SmsCapability = new SmsCapability();
  private screenCapability: ScreenCapability = ScreenCapability.getInstance();
  private microphoneCapability: MicrophoneCapability = new MicrophoneCapability();
  private speakerCapability: SpeakerCapability = new SpeakerCapability();
  private emailCapability: EmailCapability = new EmailCapability();
  private calendarCapability: CalendarCapability = new CalendarCapability();
  private execCapability: ExecCapability = new ExecCapability();

  // Capability toggles (default all enabled)
  private _capLocation: boolean = true;
  private _capCamera: boolean = true;
  private _capCanvas: boolean = true;
  private _capScreen: boolean = true;
  private _capNotification: boolean = true;
  private _capSms: boolean = true;
  private _capMicrophone: boolean = true;
  private _capSpeaker: boolean = true;
  private _capEmail: boolean = true;
  private _capCalendar: boolean = true;
  private _capExec: boolean = true;

  // Observable state
  private _operatorState: ConnectionState = ConnectionState.Disconnected;
  private _nodeState: ConnectionState = ConnectionState.Disconnected;
  private _statusText: string = 'Offline';
  private _listeners: Array<(state: ConnectionState, text: string) => void> = [];

  // Chat via gateway
  private _chatListeners: Array<(event: GatewayChatEvent) => void> = [];
  private _chatIdCounter: number = 0;

  // Dedup: track runId+seq processed by 'agent' events to skip duplicate 'chat' events
  private _agentProcessedSeqs: Set<string> = new Set<string>();
  private _agentActiveRunId: string = '';

  // Current endpoint (for media URL building)
  private _endpoint: GatewayEndpoint | undefined = undefined;

  // Store connect params for reconnect/re-auth
  private _context: common.UIAbilityContext | undefined = undefined;
  private _connectToken: string | undefined = undefined;
  private _connectPassword: string | undefined = undefined;

  // Notification-to-chat listeners
  private _notifListeners: Array<(info: NotificationInfo) => void> = [];

  // Media file listeners — notify ChatPage when a recording/photo is captured via gateway
  private _mediaListeners: Array<(type: string, path: string) => void> = [];

  // Invoke listeners — notify ChatPage when a gateway invoke request is executed
  private _invokeListeners: Array<(command: string, params: string, result: string, isError: boolean) => void> = [];

  // Approval listeners — notify ChatPage when an exec approval is requested
  private _approvalListeners: Array<(req: ExecApprovalRequest) => void> = [];

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
                     screen: boolean, notification: boolean, sms?: boolean,
                     microphone?: boolean, speaker?: boolean, email?: boolean): void {
    this._capLocation = location;
    this._capCamera = camera;
    this._capCanvas = canvas;
    this._capScreen = screen;
    this._capNotification = notification;
    if (sms !== undefined) {
      this._capSms = sms;
    }
    if (microphone !== undefined) {
      this._capMicrophone = microphone;
    }
    if (speaker !== undefined) {
      this._capSpeaker = speaker;
    }
    if (email !== undefined) {
      this._capEmail = email;
    }
    this.log.info(TAG, `Capabilities updated: location=${location} camera=${camera} canvas=${canvas} screen=${screen} notification=${notification} sms=${this._capSms} mic=${this._capMicrophone} speaker=${this._capSpeaker} email=${this._capEmail}`);
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

  // ---- Notification-to-chat listeners ----

  addNotificationListener(listener: (info: NotificationInfo) => void): void {
    this._notifListeners.push(listener);
  }

  removeNotificationListener(listener: (info: NotificationInfo) => void): void {
    let idx = this._notifListeners.indexOf(listener);
    if (idx >= 0) {
      this._notifListeners.splice(idx, 1);
    }
  }

  addMediaListener(listener: (type: string, path: string) => void): void {
    this._mediaListeners.push(listener);
  }

  removeMediaListener(listener: (type: string, path: string) => void): void {
    let idx = this._mediaListeners.indexOf(listener);
    if (idx >= 0) {
      this._mediaListeners.splice(idx, 1);
    }
  }

  private dispatchMedia(type: string, path: string): void {
    this.log.info(TAG, `dispatchMedia: type=${type} path=${path}`);
    for (let listener of this._mediaListeners) {
      try {
        listener(type, path);
      } catch { /* ignore */ }
    }
  }

  addInvokeListener(listener: (command: string, params: string, result: string, isError: boolean) => void): void {
    this._invokeListeners.push(listener);
  }

  removeInvokeListener(listener: (command: string, params: string, result: string, isError: boolean) => void): void {
    let idx = this._invokeListeners.indexOf(listener);
    if (idx >= 0) {
      this._invokeListeners.splice(idx, 1);
    }
  }

  private dispatchInvoke(command: string, params: string, result: string, isError: boolean): void {
    this.log.info(TAG, `dispatchInvoke: command=${command} isError=${isError} resultLen=${result.length}`);
    for (let listener of this._invokeListeners) {
      try {
        listener(command, params, result, isError);
      } catch { /* ignore */ }
    }
  }

  addApprovalListener(listener: (req: ExecApprovalRequest) => void): void {
    this._approvalListeners.push(listener);
  }

  removeApprovalListener(listener: (req: ExecApprovalRequest) => void): void {
    let idx = this._approvalListeners.indexOf(listener);
    if (idx >= 0) {
      this._approvalListeners.splice(idx, 1);
    }
  }

  private dispatchApproval(req: ExecApprovalRequest): void {
    this.log.info(TAG, `dispatchApproval: id=${req.id} command=${req.command.substring(0, 100)} host=${req.host}`);
    for (let listener of this._approvalListeners) {
      try {
        listener(req);
      } catch { /* ignore */ }
    }
  }

  async resolveApproval(approvalId: string, decision: string): Promise<void> {
    if (!this.operatorSession) {
      throw new Error('Gateway not connected');
    }
    let params = `{"approvalId":${JSON.stringify(approvalId)},"decision":${JSON.stringify(decision)}}`;
    this.log.info(TAG, `resolveApproval: id=${approvalId} decision=${decision}`);
    let resJson = await this.operatorSession.request('exec.approval.resolve', params, 15000);
    this.log.info(TAG, `resolveApproval response: ${resJson.substring(0, 200)}`);
  }

  private dispatchNotification(info: NotificationInfo): void {
    this.log.info(TAG, `dispatchNotification: title="${info.title}" sender="${info.sender}" body="${info.body.substring(0, 80)}"`);
    for (let listener of this._notifListeners) {
      try {
        listener(info);
      } catch {
        // ignore
      }
    }
  }

  /** Get the current gateway endpoint (for building media URLs, etc.) */
  getEndpoint(): GatewayEndpoint | undefined {
    return this._endpoint;
  }

  /**
   * Build an HTTP URL from a MEDIA: path reference.
   * Gateway serves media at: http(s)://host:port/media/<path>
   * e.g., "MEDIA:/tmp/tts-xxx/voice.mp3" → "https://host:port/media/tmp/tts-xxx/voice.mp3"
   */
  buildMediaUrl(mediaPath: string): string | undefined {
    let ep = this._endpoint;
    if (!ep) return undefined;
    // Strip "MEDIA:" prefix
    let path = mediaPath;
    if (path.startsWith('MEDIA:')) {
      path = path.substring(6);
    }
    // Remove leading slash for clean join
    if (path.startsWith('/')) {
      path = path.substring(1);
    }
    let scheme = ep.useTls ? 'https' : 'http';
    return `${scheme}://${ep.host}:${ep.port}/media/${path}`;
  }

  /**
   * Play a MEDIA: reference URL through the speaker capability.
   * Downloads from gateway and plays via AVPlayer.
   */
  async playMediaUrl(mediaPath: string): Promise<void> {
    let url = this.buildMediaUrl(mediaPath);
    if (!url) {
      this.log.warn(TAG, 'Cannot play media: no gateway endpoint');
      return;
    }
    if (!this._capSpeaker) {
      this.log.warn(TAG, 'Cannot play media: speaker capability disabled');
      return;
    }
    this.log.info(TAG, `Playing media URL: ${url}`);
    let paramsJson = `{"url":${JSON.stringify(url)}}`;
    try {
      let result = await this.speakerCapability.execute(Command.SPEAKER_PLAY, paramsJson);
      this.log.info(TAG, `Media playback result: ${result.substring(0, 200)}`);
    } catch (err) {
      this.log.error(TAG, `Media playback error: ${(err as Error).message ?? ''}`);
    }
  }

  /**
   * Use local TTS to speak text (bypasses gateway, uses device speaker directly).
   */
  async speakLocal(paramsJson: string): Promise<void> {
    if (!this._capSpeaker) {
      this.log.warn(TAG, 'Cannot speak: speaker capability disabled');
      return;
    }
    this.log.info(TAG, `speakLocal: params=${paramsJson.substring(0, 200)}`);
    try {
      let result = await this.speakerCapability.execute(Command.SPEAKER_SPEAK, paramsJson);
      this.log.info(TAG, `speakLocal result: ${result.substring(0, 200)}`);
    } catch (err) {
      this.log.error(TAG, `speakLocal error: ${(err as Error).message ?? ''}`);
      throw err as Error;
    }
  }

  /**
   * Stop all speaker audio (TTS and media playback) immediately.
   */
  async stopSpeaker(): Promise<void> {
    this.log.info(TAG, 'stopSpeaker: stopping all audio');
    try {
      await this.speakerCapability.execute(Command.SPEAKER_STOP, undefined);
    } catch (err) {
      this.log.warn(TAG, `stopSpeaker error: ${(err as Error).message ?? ''}`);
    }
  }

  /** Pre-load display name from preferences. Call before connect(). */
  async loadDisplayName(context: common.UIAbilityContext): Promise<void> {
    try {
      let store = await preferences.getPreferences(context, Constants.PREFS_SETTINGS);
      this._displayName = (await store.get('assistant_name', '')) as string;
      this.log.info(TAG, `Loaded displayName: "${this._displayName}"`);
    } catch { /* ignore */ }
  }

  connect(context: common.UIAbilityContext, endpoint: GatewayEndpoint, token?: string, password?: string): void {
    // Disconnect existing sessions if any
    this.disconnect();

    this._endpoint = endpoint;
    this._context = context;
    this._connectToken = token;
    this._connectPassword = password;
    this._pairingApproved = false;
    this._pairingInProgress = false;
    this.log.info(TAG, `connect() called: ${endpoint.host}:${endpoint.port} tls=${endpoint.useTls} token=${token ? 'yes' : 'no'} password=${password ? 'yes' : 'no'} displayName="${this._displayName}"`);
    // Set context for capabilities that need file system access
    this.cameraCapability.setContext(context);
    this.screenCapability.setContext(context);
    this.microphoneCapability.setContext(context);
    this.speakerCapability.setContext(context);
    this.emailCapability.setContext(context);
    this.calendarCapability.setContext(context);

    // Set up notification capability: bundleName, icon, permission, and chat callback
    if (this._capNotification) {
      this.notificationCapability.setBundleName(context.abilityInfo.bundleName);
      this.notificationCapability.requestPermissionEarly();
      this.notificationCapability.onNotificationPublished = (info: NotificationInfo) => {
        this.dispatchNotification(info);
      };
      // Load small icon for status bar display (fire-and-forget)
      this.loadNotificationIcon(context);
    }

    // Wire up A2UI action callback
    this.canvasCapability.onA2UIAction = (actionJson: string) => {
      if (this.nodeSession) {
        this.log.info(TAG, `A2UI action → node event: ${actionJson.substring(0, 200)}`);
        this.nodeSession.sendNodeEvent('canvas.a2ui.action', actionJson);
      }
    };

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
      // Reset pairing flags when node disconnects so re-pairing can happen on reconnect
      if (state === ConnectionState.Reconnecting || state === ConnectionState.Disconnected) {
        this._pairingApproved = false;
        this._pairingInProgress = false;
        this._pairingScopeMissing = false;
      }
      this.updateStatus();
      this.log.info(TAG, `node state: ${state} - ${message}`);
    };
    this.nodeSession.onEvent = (event, payloadJson) => {
      this.log.debug(TAG, `node event: ${event} payloadLen=${payloadJson ? payloadJson.length : 0}`);
    };
    this.nodeSession.onInvokeRequest = async (req: InvokeRequest): Promise<InvokeResult> => {
      return await this.handleInvoke(req);
    };
    this.nodeSession.onPairingRequired = (requestId: string) => {
      this.autoApproveNodePairing(requestId);
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
    this._endpoint = undefined;
    this._operatorState = ConnectionState.Disconnected;
    this._nodeState = ConnectionState.Disconnected;
    this.updateStatus();
  }

  private _pairingApproved: boolean = false;
  private _pairingInProgress: boolean = false;
  private _pairingScopeMissing: boolean = false;

  private async autoApproveNodePairing(requestId: string): Promise<void> {
    if (this._pairingApproved) {
      if (this.nodeSession) this.nodeSession.notifyPairingDone();
      return;
    }
    if (this._pairingInProgress) {
      return;
    }
    // If we already know the operator lacks the pairing scope, don't retry
    if (this._pairingScopeMissing) {
      if (this.nodeSession) this.nodeSession.notifyPairingDone();
      return;
    }
    this._pairingInProgress = true;

    // Wait for operator session to be connected (poll every 1s, up to 15s)
    let waitedMs = 0;
    while ((!this.operatorSession || this._operatorState !== ConnectionState.Connected) && waitedMs < 15000) {
      this.log.info(TAG, `Auto-pair: waiting for operator to connect... (${waitedMs}ms)`);
      await new Promise<void>((resolve) => { setTimeout(() => { resolve(); }, 1000); });
      waitedMs += 1000;
    }

    if (!this.operatorSession || this._operatorState !== ConnectionState.Connected) {
      this.log.warn(TAG, 'Auto-pair: operator not connected after 15s, cannot approve');
      this._pairingInProgress = false;
      if (this.nodeSession) this.nodeSession.notifyPairingDone();
      return;
    }

    this.log.info(TAG, `Auto-pair: approving requestId=${requestId} via node.pair.approve`);
    let params = `{"requestId":${JSON.stringify(requestId)}}`;
    try {
      let res = await this.operatorSession.request('node.pair.approve', params, 10000);
      this.log.info(TAG, `Auto-pair: succeeded (full response): ${res}`);
      this._pairingApproved = true;

      // Extract and store device token from approve response if present
      if (res.length > 0 && this._context) {
        try {
          let resObj = JSON.parse(res) as Record<string, Object>;
          // Check common token field names
          let token = (resObj['deviceToken'] ?? resObj['token'] ?? resObj['nodeToken'] ?? '') as string;
          // Also check nested auth object
          if (token.length === 0 && resObj['auth']) {
            let authObj = resObj['auth'] as Record<string, string>;
            token = authObj['deviceToken'] ?? authObj['token'] ?? '';
          }
          if (token.length > 0) {
            this.log.info(TAG, `Auto-pair: found token in approve response (${token.length} chars), storing...`);
            let identity = await this.identityStore.loadOrCreate(this._context);
            await this.authStore.saveToken(this._context, identity.deviceId, 'node', token);
          } else {
            this.log.info(TAG, `Auto-pair: no token in approve response, keys: [${Object.keys(resObj).join(',')}]`);
          }
        } catch {
          // ignore parse errors
        }
      }
    } catch (err) {
      let errMsg = (err as Error).message ?? '';
      this.log.error(TAG, `Auto-pair: failed: ${errMsg}`);
      if (errMsg.includes('missing scope')) {
        this._pairingScopeMissing = true;
        this.log.warn(TAG, 'Auto-pair: operator lacks pairing scope. Set gateway.devices.autoApprove="all" in gateway config, or run: openclaw nodes approve ' + requestId);
      }
    }
    this._pairingInProgress = false;
    if (this.nodeSession) {
      this.log.info(TAG, 'Auto-pair: notifying node session pairing done');
      this.nodeSession.notifyPairingDone();
    }
  }

  private updateStatus(): void {
    let opConnected = this._operatorState === ConnectionState.Connected;
    let nodeConnected = this._nodeState === ConnectionState.Connected;

    let oldStatus = this._statusText;

    if (opConnected && nodeConnected) {
      this._statusText = 'Connected';
    } else if (opConnected && !nodeConnected) {
      this._statusText = this._pairingScopeMissing
        ? 'Connected (node not paired)'
        : 'Connected (node offline)';
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
    let paramsStr = paramsJson ?? '';

    this.log.info(TAG, `invoke: command=${command} params=${paramsStr.substring(0, 200)}`);

    try {
      let result = '';
      switch (command) {
        case Command.LOCATION_GET: {
          this.log.info(TAG, 'Executing location.get capability...');
          result = await this.locationCapability.execute(paramsJson);
          break;
        }
        case Command.NOTIFICATION_SHOW:
        case Command.SYSTEM_NOTIFY: {
          this.log.info(TAG, `Executing ${command} capability...`);
          result = await this.notificationCapability.execute(paramsJson);
          break;
        }
        case Command.CAMERA_SNAP:
        case Command.CAMERA_CLIP: {
          this.log.info(TAG, `Executing ${command} capability...`);
          result = await this.cameraCapability.execute(command, paramsJson);
          break;
        }
        case Command.CANVAS_PRESENT:
        case Command.CANVAS_HIDE:
        case Command.CANVAS_NAVIGATE:
        case Command.CANVAS_EVAL:
        case Command.CANVAS_SNAPSHOT:
        case Command.CANVAS_A2UI_PUSH:
        case Command.CANVAS_A2UI_PUSH_JSONL:
        case Command.CANVAS_A2UI_RESET: {
          this.log.info(TAG, `Executing ${command} capability...`);
          result = await this.canvasCapability.execute(command, paramsJson);
          break;
        }
        case Command.SMS_SEND: {
          this.log.info(TAG, 'Executing sms.send capability...');
          result = await this.smsCapability.execute(paramsJson);
          break;
        }
        case Command.SCREEN_CAPTURE:
        case Command.SCREEN_RECORD: {
          this.log.info(TAG, `Executing ${command} capability...`);
          result = await this.screenCapability.execute(command, paramsJson);
          break;
        }
        case Command.MIC_RECORD: {
          this.log.info(TAG, 'Executing mic.record capability...');
          // Parse duration to notify UI for recording timer
          let recDurationMs: number = 5000;
          if (paramsJson && paramsJson.length > 0) {
            try {
              let rp = JSON.parse(paramsJson) as Record<string, Object>;
              if (rp['durationMs'] !== undefined) {
                recDurationMs = Math.max(1000, Math.min(120000, rp['durationMs'] as number));
              }
              if (rp['duration'] !== undefined) {
                let ds: number = Math.max(1, Math.min(120, rp['duration'] as number));
                recDurationMs = ds * 1000;
              }
            } catch { /* ignore */ }
          }
          this.dispatchMedia('recording_start', String(recDurationMs));
          result = await this.microphoneCapability.execute(paramsJson);
          this.dispatchMedia('recording_stop', '');
          // Extract filePath and notify ChatPage for playback button
          try {
            let parsed = JSON.parse(result) as Record<string, Object>;
            let fp = parsed['filePath'] as string;
            if (fp && fp.length > 0) {
              this.dispatchMedia('audio', fp);
            }
          } catch { /* ignore */ }
          break;
        }
        case Command.SPEAKER_SPEAK:
        case Command.SPEAKER_PLAY:
        case Command.SPEAKER_STOP: {
          this.log.info(TAG, `Executing ${command} capability...`);
          result = await this.speakerCapability.execute(command, paramsJson);
          break;
        }
        case Command.EMAIL_SEND: {
          this.log.info(TAG, 'Executing email.send capability...');
          result = await this.emailCapability.execute(paramsJson);
          break;
        }
        case Command.CALENDAR_ADD: {
          this.log.info(TAG, 'Executing calendar.add capability...');
          result = await this.calendarCapability.execute(paramsJson);
          break;
        }
        case Command.EXEC_RUN: {
          this.log.info(TAG, 'Executing exec.run capability...');
          result = await this.execCapability.execute(paramsJson);
          break;
        }
        default:
          this.log.warn(TAG, `Unsupported invoke command: ${command}`);
          this.dispatchInvoke(command, paramsStr, `unsupported command: ${command}`, true);
          return InvokeResult.error('INVALID_REQUEST', `unsupported command: ${command}`);
      }
      this.log.info(TAG, `${command} result: ${result.substring(0, 200)}`);
      this.dispatchInvoke(command, paramsStr, result, false);
      return InvokeResult.success(result);
    } catch (err) {
      let message = (err as Error).message ?? 'invoke failed';
      this.log.error(TAG, `invoke error for ${command}: ${message}`);
      this.dispatchInvoke(command, paramsStr, message, true);
      return InvokeResult.error('UNAVAILABLE', message);
    }
  }

  private handleOperatorEvent(event: string, payloadJson: string | undefined): void {
    this.log.info(TAG, `operator event: "${event}" payloadLen=${payloadJson ? payloadJson.length : 0} payload(500)=${payloadJson ? payloadJson.substring(0, 500) : '(none)'}`);

    if (!payloadJson) return;

    // Handle exec approval requests from gateway
    if (event === 'exec.approval.requested') {
      try {
        let raw = JSON.parse(payloadJson) as Record<string, Object>;
        let req: ExecApprovalRequest = {
          id: (raw['id'] as string) ?? '',
          command: (raw['command'] as string) ?? '',
          cwd: (raw['cwd'] as string) ?? '',
          host: (raw['host'] as string) ?? '',
          agentId: (raw['agentId'] as string) ?? '',
          sessionKey: (raw['sessionKey'] as string) ?? '',
          expiresAt: (raw['expiresAt'] as number) ?? 0,
        };
        this.dispatchApproval(req);
      } catch (err) {
        this.log.error(TAG, `Failed to parse exec.approval.requested: ${(err as Error).message}`);
      }
      return;
    }

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

        // Extract INCREMENTAL text (delta) from agent events.
        // Wire format: data.text = accumulated full text, data.delta = incremental chunk.
        // We use data.delta (incremental) because ChatPage accumulates text on its side.
        // Fallback order:
        // 1. data.delta (incremental chunk — preferred)
        // 2. data.text (accumulated — only if delta not available)
        // 3. top-level text field
        // 4. message.content[].text (chat-style message format)
        // 5. content[].text (direct content blocks)
        // 6. data (if data is a string directly)
        let fullText: string = '';
        let dataObj = raw['data'] as Record<string, Object> | undefined;
        if (dataObj !== undefined && dataObj !== null) {
          if (typeof dataObj === 'string') {
            fullText = String(dataObj);
          } else if (dataObj['delta'] !== undefined && String(dataObj['delta']).length > 0) {
            // Always use incremental delta — ChatPage accumulates on its side.
            // NEVER use data.text (server-accumulated) here, because ChatPage does
            // gwAccumulatedText += text, which would cause double content.
            fullText = String(dataObj['delta']);
          } else if (dataObj['text'] !== undefined) {
            // Fallback to accumulated text (used for final events that have no delta)
            fullText = String(dataObj['text']);
          }
        }
        if (fullText.length === 0 && raw['text'] !== undefined) {
          fullText = String(raw['text']);
        }
        // Try message.content[].text format
        if (fullText.length === 0 && raw['message'] !== undefined) {
          let msgObj = raw['message'] as Record<string, Object>;
          if (msgObj !== null && msgObj['content'] !== undefined) {
            let contentVal = msgObj['content'];
            if (Array.isArray(contentVal)) {
              let arr: Object[] = contentVal as Object[];
              for (let i = 0; i < arr.length; i++) {
                let block: Record<string, string> = arr[i] as Record<string, string>;
                if (block['type'] === 'text' && block['text']) {
                  fullText += block['text'];
                }
              }
            } else if (typeof contentVal === 'string') {
              fullText = contentVal as string;
            }
          }
        }
        // Try top-level content array
        if (fullText.length === 0 && raw['content'] !== undefined) {
          let contentVal = raw['content'];
          if (Array.isArray(contentVal)) {
            let arr: Object[] = contentVal as Object[];
            for (let i = 0; i < arr.length; i++) {
              let block: Record<string, string> = arr[i] as Record<string, string>;
              if (block['type'] === 'text' && block['text']) {
                fullText += block['text'];
              }
            }
          } else if (typeof contentVal === 'string') {
            fullText = contentVal as string;
          }
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

        // Check lifecycle stream: stream=lifecycle, data.phase=end means the run is complete
        if (chatState === 'delta' && stream === 'lifecycle' && dataObj !== undefined && dataObj !== null) {
          let phase = dataObj['phase'];
          if (phase !== undefined && String(phase) === 'end') {
            chatState = 'final';
            this.log.info(TAG, `lifecycle phase=end detected, marking as final`);
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

        // Track this runId+seq so we can skip duplicate 'chat' events for the same data
        this._agentActiveRunId = runId;
        let dedupKey = `${runId}:${seq}`;
        this._agentProcessedSeqs.add(dedupKey);
        // Keep set small: clear old entries when final
        if (chatState === 'final' || chatState === 'error' || chatState === 'aborted') {
          // Schedule cleanup after a short delay so any lagging chat events still get filtered
          setTimeout(() => {
            this._agentProcessedSeqs.clear();
            this._agentActiveRunId = '';
          }, 3000);
        }

        this.dispatchChatEvent(chatEvent);
      } catch (err) {
        this.log.error(TAG, `Failed to parse agent event: ${(err as Error).message ?? ''}`);
      }
      return;
    }

    // Handle 'chat' event format (legacy / direct chat.send response)
    // Skip if we already processed the same runId+seq from 'agent' events (dedup)
    if (event === 'chat') {
      try {
        let raw = JSON.parse(payloadJson) as Record<string, Object>;
        let runId: string = (raw['runId'] as string) ?? '';
        let state: string = (raw['state'] as string) ?? '';
        let chatSeq: number = (raw['seq'] as number) ?? 0;

        // Dedup: if this runId+seq was already handled by an 'agent' event, skip it
        let dedupKey = `${runId}:${chatSeq}`;
        if (this._agentProcessedSeqs.has(dedupKey)) {
          this.log.info(TAG, `chat event SKIPPED (dedup): runId=${runId} seq=${chatSeq} state=${state}`);
          return;
        }
        // Also skip if we have an active agent run for this runId (agent events are preferred)
        if (this._agentActiveRunId.length > 0 && runId === this._agentActiveRunId) {
          this.log.info(TAG, `chat event SKIPPED (agent active): runId=${runId} seq=${chatSeq} state=${state}`);
          return;
        }

        let chatEvent: GatewayChatEvent = {
          runId: runId,
          sessionKey: (raw['sessionKey'] as string) ?? '',
          seq: chatSeq,
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

  private _displayName: string = '';

  private buildClientInfo(clientId: string, clientMode: string): ClientInfo {
    let info: ClientInfo = {
      id: clientId,
      version: APP_VERSION,
      platform: 'HarmonyOS',
      mode: clientMode,
      deviceFamily: 'HarmonyOS',
    };
    if (this._displayName.length > 0) {
      info.displayName = this._displayName;
    }
    return info;
  }

  private buildOperatorOptions(): ConnectOptions {
    return {
      role: 'operator',
      scopes: ['operator.read', 'operator.write', 'operator.pairing', 'operator.approvals'],
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
      commands.push(Command.CANVAS_A2UI_PUSH);
      commands.push(Command.CANVAS_A2UI_PUSH_JSONL);
      commands.push(Command.CANVAS_A2UI_RESET);
    }
    if (this._capScreen) {
      caps.push(Capability.Screen);
      commands.push(Command.SCREEN_CAPTURE);
      commands.push(Command.SCREEN_RECORD);
    }
    if (this._capNotification) {
      caps.push(Capability.Notification);
      commands.push(Command.NOTIFICATION_SHOW);
      commands.push(Command.SYSTEM_NOTIFY);
    }
    if (this._capSms) {
      caps.push(Capability.Sms);
      commands.push(Command.SMS_SEND);
    }
    if (this._capMicrophone) {
      caps.push(Capability.Microphone);
      commands.push(Command.MIC_RECORD);
    }
    if (this._capSpeaker) {
      caps.push(Capability.Speaker);
      commands.push(Command.SPEAKER_SPEAK);
      commands.push(Command.SPEAKER_PLAY);
      commands.push(Command.SPEAKER_STOP);
    }
    if (this._capEmail) {
      caps.push(Capability.Email);
      commands.push(Command.EMAIL_SEND);
    }
    if (this._capCalendar) {
      caps.push(Capability.Calendar);
      commands.push(Command.CALENDAR_ADD);
    }
    if (this._capExec) {
      caps.push(Capability.Exec);
      commands.push(Command.EXEC_RUN);
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

  /** Fetch memories from the OpenClaw server via operator session RPC. */
  async fetchMemories(): Promise<string> {
    if (!this.operatorSession) {
      throw new Error('Gateway not connected');
    }
    if (this._operatorState !== ConnectionState.Connected) {
      throw new Error('Operator session not connected');
    }

    this.log.info(TAG, 'Fetching memories from server...');
    let resJson = await this.operatorSession.request('memory.list', '{}', 15000);
    this.log.info(TAG, `memory.list response: ${resJson.substring(0, 500)}`);
    return resJson;
  }

  /** Save a memory item to the OpenClaw server via operator session RPC. */
  async saveMemoryToServer(memType: string, content: string, importance: number = 0.5): Promise<string> {
    if (!this.operatorSession) {
      throw new Error('Gateway not connected');
    }
    if (this._operatorState !== ConnectionState.Connected) {
      throw new Error('Operator session not connected');
    }

    let params = `{"type":${JSON.stringify(memType)},"content":${JSON.stringify(content)},"importance":${importance}}`;
    this.log.info(TAG, `Saving memory to server: type=${memType} content=${content.substring(0, 80)}`);
    let resJson = await this.operatorSession.request('memory.add', params, 15000);
    this.log.info(TAG, `memory.add response: ${resJson.substring(0, 200)}`);
    return resJson;
  }

  /** Load the app icon as PixelMap for notification status bar display */
  private loadNotificationIcon(context: common.UIAbilityContext): void {
    try {
      let mgr = context.resourceManager;
      // Use getRawFileContent to load icon from rawfile, or getMediaByName
      mgr.getMediaByName('icon').then((data: Uint8Array) => {
        let imageSource = image.createImageSource(data.buffer);
        imageSource.createPixelMap({
          desiredSize: { width: 48, height: 48 },
        }).then((pixelMap: image.PixelMap) => {
          this.notificationCapability.setSmallIcon(pixelMap);
          this.log.info(TAG, 'Notification small icon loaded');
        }).catch((err: Error) => {
          this.log.warn(TAG, `Failed to create PixelMap for icon: ${err.message ?? ''}`);
        });
      }).catch((err: Error) => {
        this.log.warn(TAG, `Failed to load icon media content: ${err.message ?? ''}`);
      });
    } catch (err) {
      this.log.warn(TAG, `Failed to load notification icon: ${(err as Error).message ?? ''}`);
    }
  }
}
