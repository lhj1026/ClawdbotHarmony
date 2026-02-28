/**
 * Orchestrates two GatewaySession instances (operator + node) and
 * dispatches invoke requests to capability handlers.
 * Ported from Android NodeRuntime.kt.
 */
import { common, wantAgent } from '@kit.AbilityKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
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
  GatewayTokenUsage,
  ExecApprovalRequest,
  AgentIdentity,
  GatewayFileResult,
  ChatAttachment,
} from './GatewayModels';
import { image } from '@kit.ImageKit';
import { buffer } from '@kit.ArkTS';
import { webview } from '@kit.ArkWeb';
import { componentSnapshot, router, window } from '@kit.ArkUI';
import { preferences } from '@kit.ArkData';
import { ConfigManager } from '../ConfigManager';
import { http, connection } from '@kit.NetworkKit';
import { fileIo } from '@kit.CoreFileKit';
import { LogService } from '../../common/LogService';
import { Constants } from '../../common/Constants';
import { I18n } from '../../common/I18n';
import { NotificationHelper } from '../NotificationHelper';
import { ExperienceStorage } from '../ExperienceStorage';
import { ExperiencePack, Experience, Skill, Memory, ShareLevel, generateId } from '../../model/ExperiencePack';
import { MemoryService } from '../MemoryService';
import { Monitor } from '../ModuleMonitor';
import { ContextAwarenessService, ContextRecommendation, LocationCandidate, ActivityCandidate } from '../context/ContextAwarenessService';
import { ContextEngineService, ContextSnapshot, ContextRule, ContextCondition, ContextAction, MatchResult, GeofenceBinding } from '../context/ContextEngine';
import { FeedbackService } from '../context/FeedbackService';
import { ActionExecutor, ActionResult } from '../context/ActionExecutor';
import { GeofenceSuggestion } from '../context/LocationDiscoveryService';
import { Geofence, GeofenceCategory, LearnedPlaceSignals, UserAction } from '../context/ContextModels';
import { FederatedSync } from '../context/FederatedSync';
import { PushCapability } from './PushCapability';

const TAG = 'NodeRuntime';
const APP_VERSION = '2.58.5';

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
  private pushCapability: PushCapability = PushCapability.getInstance();

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

  // Buffer for messages received while no listeners are registered (e.g., app in background)
  private _pendingChatEvents: GatewayChatEvent[] = [];
  private readonly MAX_PENDING_EVENTS: number = 50;

  // Dedup: track runId+seq processed by 'agent' events to skip duplicate 'chat' events
  private _agentProcessedSeqs: Set<string> = new Set<string>();
  private _agentActiveRunId: string = '';
  private _harmonyRunIds: Set<string> = new Set();

  // Pending doc viewer content (set by canvas.navigate .md handler, consumed by ChatPage A2UI listener)
  _pendingDocTitle: string = '';
  _pendingDocContent: string = '';

  consumePendingDoc(): Record<string, string> | undefined {
    if (this._pendingDocContent.length === 0) return undefined;
    let result: Record<string, string> = { 'title': this._pendingDocTitle, 'content': this._pendingDocContent };
    this._pendingDocTitle = '';
    this._pendingDocContent = '';
    return result;
  }

  // Multi-session routing: map runId → chatSessionId
  private _runSessionMap: Map<string, string> = new Map<string, string>();

  // Current endpoint (for media URL building)
  private _endpoint: GatewayEndpoint | undefined = undefined;

  // Store connect params for reconnect/re-auth
  private _context: common.UIAbilityContext | undefined = undefined;
  private _connectToken: string | undefined = undefined;
  private _connectPassword: string | undefined = undefined;

  // Network change monitoring
  private _netConnection: connection.NetConnection | undefined = undefined;
  private _netReconnectTimer: number = -1;
  private static readonly NET_RECONNECT_DEBOUNCE_MS: number = 2000;

  // Notification-to-chat listeners
  private _notifListeners: Array<(info: NotificationInfo) => void> = [];

  // Media file listeners — notify ChatPage when a recording/photo is captured via gateway
  private _mediaListeners: Array<(type: string, path: string) => void> = [];

  // Invoke listeners — notify ChatPage when a gateway invoke request is executed
  private _invokeListeners: Array<(command: string, params: string, result: string, isError: boolean) => void> = [];

  // Approval listeners — notify ChatPage when an exec approval is requested
  private _approvalListeners: Array<(req: ExecApprovalRequest) => void> = [];

  // A2UI / inline canvas listeners — notify ChatPage when A2UI or canvas content arrives
  private _a2uiListeners: Array<(type: string, content: string) => void> = [];

  // Experience pull completion callbacks — notify MemoryPage when pull finishes
  private _experiencePullCallbacks: Array<(success: boolean, count: number) => void> = [];
  private _experienceSyncActive: boolean = false;  // Suppress chat display during sync

  // Inline canvas controller — provided by ChatPage/MessageBubble for eval/snapshot
  private _inlineCanvasController: webview.WebviewController | undefined = undefined;
  private _inlineCanvasReady: (() => void) | undefined = undefined;

  // Gateway agent identity (fetched from config.get after connect)
  private _agentIdentity: AgentIdentity | undefined = undefined;
  private _agentId: string = 'main';  // agent ID from config (for avatar URL)
  private _cachedAvatarPath: string = '';  // local file path of downloaded avatar
  private _lastRecRuleId: string = '';
  private _lastRecRuleName: string = '';
  private _lastRecReason: string = '';
  private _lastRecConfidence: number = 0;
  private _contextListenersRegistered: boolean = false;
  private _activeRecommendations: Map<string, ContextRecommendation> = new Map();
  private _actionExecutor: ActionExecutor | undefined = undefined;
  private _identityListeners: Array<(identity: AgentIdentity | undefined) => void> = [];

  // App foreground/background state and chat page visibility for message notifications
  private _isInForeground: boolean = true;
  private _isChatPageVisible: boolean = false;
  private _unreadMessageNotifEnabled: boolean = true;
  private _bgNotifSentForRun: string = '';  // track runId for which we already sent a bg notification
  private _bgNotifAccumText: string = '';   // accumulate text for background notification
  private _bgNotifSentLen: number = 0;     // how much of _bgNotifAccumText was already sent in a notification
  private _bgNotifTimerId: number = -1;     // timer for delayed notification send

  // Background task for keeping WebSocket alive when app is in background
  private _backgroundTaskRunning: boolean = false;

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

  get isOperatorConnected(): boolean {
    return this._operatorState === ConnectionState.Connected;
  }

  get isNodeConnected(): boolean {
    return this._nodeState === ConnectionState.Connected;
  }

  get operatorConnectionState(): ConnectionState {
    return this._operatorState;
  }

  get nodeConnectionState(): ConnectionState {
    return this._nodeState;
  }

  get isNodePairingPending(): boolean {
    return this._pairingPending;
  }

  get agentIdentity(): AgentIdentity | undefined {
    return this._agentIdentity;
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

  // ---- App foreground/background and chat page visibility ----

  /** Called by EntryAbility when app goes to foreground */
  setForegroundState(inForeground: boolean): void {
    this._isInForeground = inForeground;
    this.log.info(TAG, `Foreground state: ${inForeground}`);
    // Clear message notifications when user returns to the app
    if (inForeground) {
      NotificationHelper.getInstance().cancelAll();
      this._bgNotifSentForRun = '';
      this._bgNotifAccumText = '';
      if (this._bgNotifTimerId >= 0) {
        clearTimeout(this._bgNotifTimerId);
        this._bgNotifTimerId = -1;
      }
      // Stop background task when returning to foreground
      this.stopBackgroundTask();
    } else {
      // Start background task to keep WebSocket alive when going to background
      // Only start if we have an active connection
      if (this.connectionState === ConnectionState.Connected && this._context) {
        this.startBackgroundTask(this._context);
      }
    }
  }

  /** Start background task for DATA_TRANSFER to keep WebSocket alive */
  /** Start Context Awareness if not already running */
  private async maybeStartContextAwareness(context: common.UIAbilityContext): Promise<void> {
    try {
      let store = preferences.getPreferencesSync(context, { name: 'chat_prefs' });
      let enabled = store.getSync('contextAwarenessEnabled', false) as boolean;
      if (enabled) {
        this.startContextAwareness(context);
      } else {
        this.log.info(TAG, '情景智能已关闭（设置中未启用）');
      }
    } catch (err) {
      this.log.warn(TAG, `读取情景智能设置失败: ${err}`);
    }
  }

  /**
   * Toggle context awareness on/off from settings
   */
  async setContextAwarenessEnabled(enabled: boolean): Promise<void> {
    if (!this._context) {
      return;
    }
    try {
      let store = preferences.getPreferencesSync(this._context, { name: 'chat_prefs' });
      store.putSync('contextAwarenessEnabled', enabled);
      store.flush();
    } catch (err) {
      this.log.warn(TAG, `保存情景智能设置失败: ${err}`);
    }

    let cas = ContextAwarenessService.getInstance();
    if (enabled) {
      if (!cas.isActive()) {
        this.startContextAwareness(this._context);
      }
    } else {
      if (cas.isActive()) {
        cas.stop();
        Monitor.stopModule('ContextAwareness');
        this.log.info(TAG, '情景智能已停止');
      }
    }
  }

  private startContextAwareness(context: common.UIAbilityContext): void {
    let cas = ContextAwarenessService.getInstance();
    if (cas.isActive()) {
      // CAS already started (by EntryAbility), just register listeners
      this.log.info(TAG, '情景智能已运行，注册监听器');
      Monitor.startModule('ContextAwareness');
      this.registerContextListeners(cas);
      return;
    }
    cas.init(context).then(() => {
      return cas.start();
    }).then((ok: boolean) => {
      if (ok) {
        this.log.info(TAG, '情景智能已启动');
        Monitor.startModule('ContextAwareness');
        this.registerContextListeners(cas);
      } else {
        // start() returned false — CAS may have been started by EntryAbility
        // Check again and register if already active
        if (cas.isActive()) {
          this.log.info(TAG, '情景智能已由其他路径启动，注册监听器');
          Monitor.startModule('ContextAwareness');
          this.registerContextListeners(cas);
        } else {
          this.log.warn(TAG, '情景智能启动失败');
        }
      }
    }).catch((err: Error) => {
      this.log.warn(TAG, `情景智能初始化失败: ${err.message ?? ''}`);
      // Even on error, CAS might be running (started by EntryAbility)
      if (cas.isActive()) {
        this.log.info(TAG, '情景智能初始化异常但已运行，注册监听器');
        Monitor.startModule('ContextAwareness');
        this.registerContextListeners(cas);
      }
    });
  }

  private registerContextListeners(cas: ContextAwarenessService): void {
    if (this._contextListenersRegistered) {
      this.log.info(TAG, '情景智能监听器已注册，跳过');
      return;
    }
    this._contextListenersRegistered = true;
    this.log.info(TAG, '注册情景智能监听器');

    // Listen for recommendations and dispatch as chat events
    cas.addRecommendationListener((rec: ContextRecommendation) => {
      this.log.info(TAG, `情景推荐: ${rec.reason}`);
      let ruleId = rec.rule.id;
      let confidence = Math.round((rec.rule.confidence ?? 1) * 100);

      // Look up rule name from engine
      let ruleName = ruleId;
      try {
        let engine = ContextEngineService.getInstance();
        let allRulesJson = engine.exportRules();
        let allRules: ContextRule[] = JSON.parse(allRulesJson) as ContextRule[];
        for (let i = 0; i < allRules.length; i++) {
          if (allRules[i].id === ruleId) {
            ruleName = allRules[i].name;
            break;
          }
        }
      } catch { /* use ruleId as fallback */ }

      // Store last recommendation for "back" functionality
      this._lastRecRuleId = ruleId;
      this._lastRecRuleName = ruleName;
      this._lastRecReason = rec.reason;
      this._lastRecConfidence = confidence;

      // Cache recommendation for action execution on accept
      this._activeRecommendations.set(ruleId, rec);
      setTimeout(() => { this._activeRecommendations.delete(ruleId); }, 5 * 60 * 1000);

      // 探索模式：显示检测到的状态 + 建议
      let stateInfo = rec.exploreStateInfo ?? '';
      if (stateInfo.length === 0 && cas.isExploreMode()) {
        // Fallback: build state from DigitalWorldService
        stateInfo = this.buildExploreStateFromDigital(cas);
        this.log.info(TAG, `[Explore] fallback stateInfo built (${stateInfo.length} chars)`);
      }

      if (stateInfo.length > 0) {
        let a2uiJsonl = this.buildExploreStateA2UI(ruleId, ruleName, rec.reason, confidence, stateInfo);

        let event: GatewayChatEvent = {
          runId: `ctx-${Date.now()}`,
          sessionKey: '',
          seq: 0,
          state: 'final',
          message: {
            role: 'assistant',
            content: [{ type: 'text', text: `🔍 探索模式检测到新状态\n${stateInfo}\n\n💡 ${rec.reason}` }],
          },
        };
        this.dispatchChatEvent(event);
        this.dispatchA2UI('push', a2uiJsonl);
      } else {
        // 普通模式：原有逻辑
        let a2uiJsonl = this.buildContextRecommendationA2UI(ruleId, ruleName, rec.reason, confidence);

        let event: GatewayChatEvent = {
          runId: `ctx-${Date.now()}`,
          sessionKey: '',
          seq: 0,
          state: 'final',
          message: {
            role: 'assistant',
            content: [{ type: 'text', text: `💡 ${rec.reason}` }],
          },
        };
        this.dispatchChatEvent(event);
        this.dispatchA2UI('push', a2uiJsonl);
      }

      // Also send system notification if in background
      if (!this._isInForeground) {
        NotificationHelper.getInstance().send('💡 ' + I18n.t('context.notification.title'), rec.reason).catch(() => { /* ignore */ });
      }
    });

    // Listen for geofence suggestions from location discovery
    cas.addSuggestionListener((suggestions: GeofenceSuggestion[]) => {
      let discoveredText = I18n.t('context.suggestion.discovered');
      let goToSettingsText = I18n.t('context.suggestion.goToSettings');
      for (let i = 0; i < suggestions.length; i++) {
        let s = suggestions[i];
        let text = `📍 ${discoveredText}：${s.name}\n${s.reason}\n${goToSettingsText}`;
        this.log.info(TAG, `围栏建议: ${s.name}`);
        let event: GatewayChatEvent = {
          runId: `suggest-${Date.now()}-${i}`,
          sessionKey: '',
          seq: 0,
          state: 'final',
          message: {
            role: 'assistant',
            content: [{ type: 'text', text: text }],
          },
        };
        this.dispatchChatEvent(event);
      }
      // Notification for first suggestion if in background
      if (!this._isInForeground && suggestions.length > 0) {
        let first = suggestions[0];
        NotificationHelper.getInstance()
          .send('📍 ' + I18n.t('context.notification.discoveredPlace'), `${first.name} — ${first.reason}`)
          .catch(() => { /* ignore */ });
      }
    });

    // Listen for A2UI events from ContextAwarenessService (new place discovery, etc.)
    cas.addA2UIListener((type: string, content: string) => {
      this.log.info(TAG, `ContextA2UI: type=${type} contentLen=${content.length}`);
      this.dispatchA2UI(type, content);
    });

    this.log.info(TAG, '情景智能监听器注册完成');
  }

  private async startBackgroundTask(context: common.UIAbilityContext): Promise<void> {
    if (this._backgroundTaskRunning) {
      this.log.info(TAG, 'Background task already running');
      return;
    }
    try {
      let wantAgentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: context.abilityInfo.bundleName,
          abilityName: context.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      let agent = await wantAgent.getWantAgent(wantAgentInfo);
      await backgroundTaskManager.startBackgroundRunning(context, backgroundTaskManager.BackgroundMode.DATA_TRANSFER, agent);
      this._backgroundTaskRunning = true;
      this.log.info(TAG, '🌐 Background task started (DATA_TRANSFER) - WebSocket will stay alive');
    } catch (err) {
      let code = (err as Record<string, number>)['code'] ?? 0;
      this.log.system(TAG, `Failed to start background task: code=${code} ${(err as Error).message ?? ''}`);
      if (code === 9800001) {
        this.log.system(TAG, 'Missing ohos.permission.KEEP_BACKGROUND_RUNNING permission');
      } else if (code === 9800003) {
        this.log.system(TAG, 'backgroundModes not configured in module.json5 (need dataTransfer)');
      }
    }
  }

  /** Stop background task */
  private async stopBackgroundTask(): Promise<void> {
    if (!this._backgroundTaskRunning || !this._context) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this._context);
      this._backgroundTaskRunning = false;
      this.log.info(TAG, 'Background task stopped');
    } catch (err) {
      this.log.warn(TAG, `Failed to stop background task: ${(err as Error).message ?? ''}`);
    }
  }

  /** Called by ChatPage when it appears/disappears */
  setChatPageVisible(visible: boolean): void {
    this._isChatPageVisible = visible;
    this.log.info(TAG, `Chat page visible: ${visible}`);
  }

  /** Enable/disable unread message notifications (called from settings) */
  setUnreadNotificationEnabled(enabled: boolean): void {
    this._unreadMessageNotifEnabled = enabled;
    this.log.info(TAG, `Unread message notification: ${enabled}`);
  }

  get isUnreadNotificationEnabled(): boolean {
    return this._unreadMessageNotifEnabled;
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
    // Deliver any buffered events from when app was in background
    if (this._pendingChatEvents.length > 0) {
      this.log.info(TAG, `📬 Delivering ${this._pendingChatEvents.length} buffered chat events`);
      let pending = this._pendingChatEvents.slice();
      this._pendingChatEvents = [];
      for (let event of pending) {
        try {
          listener(event);
        } catch {
          // ignore
        }
      }
    }
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
   * @param chatSessionId optional client-side session ID for multi-session routing
   */
  async sendChatMessage(text: string, chatSessionId?: string, attachments?: ChatAttachment[]): Promise<string> {
    if (!this.operatorSession) {
      throw new Error('Gateway not connected');
    }
    if (this._operatorState !== ConnectionState.Connected) {
      throw new Error('Operator session not connected');
    }

    this._chatIdCounter++;
    let idempotencyKey = `harmony-${Date.now()}-${this._chatIdCounter}`;
    // Dynamic sessionKey: each local session maps to its own Gateway session for parallel execution
    let sessionKey = chatSessionId ? `agent:main:harmony:${chatSessionId}` : 'agent:main:main';

    // Build params JSON string directly (ArkTS requires explicit types for object literals)
    let attachmentsJson = '';
    if (attachments && attachments.length > 0) {
      attachmentsJson = `,"attachments":${JSON.stringify(attachments)}`;
    }
    let params = `{"sessionKey":${JSON.stringify(sessionKey)},"message":${JSON.stringify(text)},"idempotencyKey":${JSON.stringify(idempotencyKey)}${attachmentsJson}}`;
    this.log.info(TAG, `sendChatMessage: key=${idempotencyKey} chatSession=${chatSessionId ?? 'none'} attachments=${attachments?.length ?? 0} text=${text.substring(0, 100)}`);

    // Register idempotencyKey → chatSessionId before RPC (events may arrive before response)
    if (chatSessionId) {
      this._runSessionMap.set(idempotencyKey, chatSessionId);
    }

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

    // Also map the actual runId to the chatSessionId
    if (chatSessionId && runId !== idempotencyKey) {
      this._runSessionMap.set(runId, chatSessionId);
    }

    // Track as harmony-originated run
    this._harmonyRunIds.add(runId);
    this._harmonyRunIds.add(idempotencyKey);
    // Keep set bounded
    if (this._harmonyRunIds.size > 100) {
      let iter = this._harmonyRunIds.keys();
      let first: IteratorResult<string> = iter.next();
      if (!first.done) {
        this._harmonyRunIds.delete(first.value);
      }
    }

    return runId;
  }

  /** Register a runId → chatSessionId mapping (for adopted runIds). */
  registerRunSession(runId: string, chatSessionId: string): void {
    this._runSessionMap.set(runId, chatSessionId);
  }

  /**
   * Get gateway config via config.get RPC.
   * Returns the raw JSON config string, or empty string on failure.
   */
  async configGet(): Promise<string> {
    if (!this.operatorSession || this._operatorState !== ConnectionState.Connected) {
      return '';
    }
    try {
      let resJson = await this.operatorSession.request('config.get', '{}', 10000);
      if (resJson.length > 0) {
        let resObj = JSON.parse(resJson) as Record<string, Object>;
        if (resObj['raw'] && typeof resObj['raw'] === 'string') {
          return resObj['raw'] as string;
        }
      }
      return resJson;
    } catch (err) {
      this.log.error(TAG, `configGet failed: ${(err as Error).message ?? ''}`);
      return '';
    }
  }

  /**
   * Patch gateway config via config.patch RPC.
   * @param patchJson JSON string with partial config to merge
   */
  async configPatch(patchJson: string): Promise<void> {
    if (!this.operatorSession || this._operatorState !== ConnectionState.Connected) {
      throw new Error('Gateway not connected');
    }
    let params = `{"raw":${patchJson}}`;
    let resJson = await this.operatorSession.request('config.patch', params, 15000);
    this.log.info(TAG, `config.patch response: ${resJson.substring(0, 200)}`);
  }

  /**
   * Request a file from the gateway server.
   * Sends file.get RPC with the file path, returns base64 data and metadata.
   * @returns { data: base64, fileName, size, mimeType } or throws on error
   */
  async requestFile(filePath: string): Promise<GatewayFileResult> {
    if (!this.operatorSession || this._operatorState !== ConnectionState.Connected) {
      throw new Error('Gateway not connected');
    }
    let params = `{"path":${JSON.stringify(filePath)}}`;
    this.log.info(TAG, `requestFile: path=${filePath}`);
    let resJson = await this.operatorSession.request('file.get', params, 30000);
    this.log.info(TAG, `file.get response length: ${resJson.length}`);

    if (resJson.length === 0) {
      throw new Error('Empty response from gateway');
    }

    let res = JSON.parse(resJson) as Record<string, Object>;
    let data = (res['data'] as string) ?? '';
    let fileName = (res['fileName'] as string) ?? filePath.split('/').pop() ?? 'file';
    let size = (res['size'] as number) ?? 0;
    let mimeType = (res['mimeType'] as string) ?? 'application/octet-stream';

    if (data.length === 0) {
      throw new Error(((res['error'] as string) ?? 'No file data returned'));
    }

    let result: GatewayFileResult = {
      data: data,
      fileName: fileName,
      size: size,
      mimeType: mimeType
    };
    return result;
  }

  /** Look up which chatSessionId a runId belongs to. */
  getSessionForRun(runId: string): string | undefined {
    return this._runSessionMap.get(runId);
  }

  /** Remove a runId → chatSessionId mapping. */
  clearRunSession(runId: string): void {
    this._runSessionMap.delete(runId);
  }

  /**
   * Get session status including token usage from Gateway.
   * Uses sessions.list RPC method and finds the matching session.
   * Returns { inputTokens, outputTokens, totalTokens } or null on failure.
   */
  async getSessionTokenUsage(chatSessionId?: string): Promise<GatewayTokenUsage | null> {
    if (!this.operatorSession || this._operatorState !== ConnectionState.Connected) {
      return null;
    }
    try {
      let sessionKey = chatSessionId ? `agent:main:harmony:${chatSessionId}` : 'agent:main:main';
      // Use sessions.list to get session info including totalTokens
      let params = `{"limit":50}`;
      let resJson = await this.operatorSession.request('sessions.list', params, 10000);
      this.log.info(TAG, `sessions.list response (300): ${resJson.substring(0, 300)}`);

      if (resJson.length > 0) {
        let result = JSON.parse(resJson) as Record<string, Object>;
        let sessions = result['sessions'] as Array<Record<string, Object>> | undefined;

        if (sessions) {
          // Find the session with matching key
          for (let session of sessions) {
            let key = session['key'] as string;
            if (key === sessionKey) {
              let totalTokens = (session['totalTokens'] as number) ?? 0;
              let contextTokens = (session['contextTokens'] as number) ?? 200000;
              this.log.info(TAG, `Found session ${sessionKey}: totalTokens=${totalTokens}, contextTokens=${contextTokens}`);
              // Gateway only provides totalTokens, not split - estimate 60% output, 40% input
              let estimatedInput = Math.floor(totalTokens * 0.4);
              let estimatedOutput = totalTokens - estimatedInput;
              return {
                inputTokens: estimatedInput,
                outputTokens: estimatedOutput,
                totalTokens: totalTokens
              };
            }
          }
          this.log.warn(TAG, `Session ${sessionKey} not found in sessions.list (${sessions.length} sessions)`);
        }
      }
    } catch (err) {
      this.log.warn(TAG, `sessions.list failed: ${(err as Error).message ?? ''}`);
    }
    return null;
  }

  private dispatchChatEvent(event: GatewayChatEvent): void {
    // Attach chatSessionId from runId mapping (multi-session routing)
    if (!event.chatSessionId && event.runId.length > 0) {
      let sid = this._runSessionMap.get(event.runId);
      if (sid) {
        event.chatSessionId = sid;
      }
    }
    // Clean up mapping when run completes
    if (event.state === 'final' || event.state === 'error' || event.state === 'aborted') {
      if (event.runId.length > 0) {
        this._runSessionMap.delete(event.runId);
      }
    }
    this.log.info(TAG, `chatEvent: state=${event.state} runId=${event.runId} seq=${event.seq} chatSession=${event.chatSessionId ?? 'none'} listeners=${this._chatListeners.length}`);

    // If no listeners (ChatPage not visible), buffer events for later delivery
    if (this._chatListeners.length === 0) {
      this.log.info(TAG, `📦 Buffering chat event (no listeners): state=${event.state}`);
      this._pendingChatEvents.push(event);
      // Keep buffer bounded
      if (this._pendingChatEvents.length > this.MAX_PENDING_EVENTS) {
        this._pendingChatEvents.shift();
      }
    } else {
      for (let listener of this._chatListeners) {
        try {
          listener(event);
        } catch {
          // ignore
        }
      }
    }

    // Send system notification for new messages when app is in background or chat page is not visible
    // Accumulate text and send after a delay so notification has meaningful content
    let hasMsg: boolean = event.message !== undefined && event.message !== null;
    let isBackground: boolean = !this._isInForeground || !this._isChatPageVisible;
    let shouldNotify: boolean = this._unreadMessageNotifEnabled && hasMsg && isBackground;
    if (shouldNotify && (event.state === 'final' || event.state === 'delta')) {
      // Accumulate text from this event
      if (event.message && event.message.content) {
        for (let block of event.message.content) {
          if (block.type === 'text' && block.text) {
            this._bgNotifAccumText += block.text;
          }
        }
      }
      let runKey = event.runId ?? '';
      if (this._bgNotifSentForRun !== runKey) {
        // New run — only send ONE notification per run
        this._bgNotifSentForRun = runKey;
        this._bgNotifAccumText = '';
        this._bgNotifSentLen = 0;
        if (this._bgNotifTimerId >= 0) {
          clearTimeout(this._bgNotifTimerId);
        }
        // Send notification after 2 seconds to accumulate enough text for context
        this._bgNotifTimerId = setTimeout(() => {
          this._bgNotifTimerId = -1;
          this.sendAccumulatedNotification();
        }, 2000) as number;
      }
      // No more notifications for this run — one is enough
    }
    // Reset tracking when run completes so next run can trigger notification
    if (event.state === 'final' || event.state === 'error' || event.state === 'aborted') {
      this._bgNotifSentForRun = '';
      this._bgNotifAccumText = '';
      this._bgNotifSentLen = 0;
    }
  }

  /** Send notification with accumulated text from background streaming */
  private sendAccumulatedNotification(): void {
    // Only send the NEW portion since last notification
    let newText = this._bgNotifAccumText.substring(this._bgNotifSentLen).trim();
    if (newText.length === 0) {
      return;
    }
    this._bgNotifSentLen = this._bgNotifAccumText.length;
    // Truncate for notification display
    let notifText = newText.length > 500 ? newText.substring(0, 500) + '…' : newText;

    let title = this._agentIdentity?.name ?? 'OpenClaw';
    if (this._agentIdentity?.emoji) {
      title = `${this._agentIdentity.emoji} ${title}`;
    }

    this.log.info(TAG, `Sending bg notification: title="${title}" text="${notifText.substring(0, 80)}..."`);
    NotificationHelper.getInstance().send(title, notifText).catch((err: Error) => {
      this.log.warn(TAG, `Failed to send bg notification: ${err.message ?? ''}`);
    });
  }

  /** Send a system notification for a new chat message (used by gateway-triggered notifications) */
  private sendMessageNotification(event: GatewayChatEvent): void {
    if (!event.message || !event.message.content) {
      return;
    }

    // Extract text from message content blocks
    let textParts: string[] = [];
    for (let block of event.message.content) {
      if (block.type === 'text' && block.text) {
        textParts.push(block.text);
      }
    }
    let messageText = textParts.join('\n');
    if (messageText.length === 0) {
      return;
    }

    // Truncate long messages for notification
    let notifText = messageText.length > 500 ? messageText.substring(0, 500) + '…' : messageText;

    // Get agent name for notification title
    let title = this._agentIdentity?.name ?? 'OpenClaw';
    if (this._agentIdentity?.emoji) {
      title = `${this._agentIdentity.emoji} ${title}`;
    }

    this.log.info(TAG, `Sending message notification: title="${title}" text="${notifText.substring(0, 50)}..."`);

    // Use NotificationHelper (local notification) for background message alerts
    NotificationHelper.getInstance().send(title, notifText).catch((err: Error) => {
      this.log.warn(TAG, `Failed to send message notification: ${err.message ?? ''}`);
    });
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

  // ---- A2UI listeners (inline rendering in chat) ----

  addA2UIListener(listener: (type: string, content: string) => void): void {
    this._a2uiListeners.push(listener);
  }

  removeA2UIListener(listener: (type: string, content: string) => void): void {
    let idx = this._a2uiListeners.indexOf(listener);
    if (idx >= 0) {
      this._a2uiListeners.splice(idx, 1);
    }
  }

  private dispatchA2UI(type: string, content: string): void {
    this.log.info(TAG, `dispatchA2UI: type=${type} contentLen=${content.length} listenerCount=${this._a2uiListeners.length}`);
    if (this._a2uiListeners.length === 0) {
      this.log.warn(TAG, '⚠️ No A2UI listeners registered! A2UI content will not be displayed.');
    }
    for (let listener of this._a2uiListeners) {
      try {
        listener(type, content);
      } catch { /* ignore */ }
    }
  }

  /** Called by ChatPage/MessageBubble when the inline canvas WebView is ready. */
  setInlineCanvasController(ctrl: webview.WebviewController | undefined): void {
    this._inlineCanvasController = ctrl;
    if (ctrl && this._inlineCanvasReady) {
      let resolve = this._inlineCanvasReady;
      this._inlineCanvasReady = undefined;
      resolve();
    }
  }

  /** Wait for the inline canvas controller to become available. */
  private waitForInlineCanvas(timeoutMs: number): Promise<void> {
    if (this._inlineCanvasController) return Promise.resolve();
    return new Promise<void>((resolve, reject) => {
      this._inlineCanvasReady = resolve;
      setTimeout(() => {
        this._inlineCanvasReady = undefined;
        if (this._inlineCanvasController) {
          resolve();
        } else {
          reject(new Error('Inline canvas controller not ready'));
        }
      }, timeoutMs);
    });
  }

  /** Send A2UI action (user interaction) back to gateway. */
  sendA2UIAction(actionJson: string): void {
    this.log.info(TAG, `sendA2UIAction: ${actionJson.substring(0, 200)}`);
    // Handle all A2UI actions locally (feedback, scene correction, etc.)
    // No need to forward to Gateway — all processing is on-device
    this.handleA2UIAction(actionJson);
  }

  private handleA2UIAction(actionJson: string): void {
    try {
      let parsed = JSON.parse(actionJson) as Record<string, Object>;
      // WebView sends {"action":{"name":"...","context":{...}}} — unwrap
      let action = (parsed['action'] ?? parsed) as Record<string, Object>;
      let name = action['name'] as string;
      if (name !== 'context_feedback' && name !== 'view_snapshot' && 
          name !== 'new_place_save' && name !== 'new_place_rename' && name !== 'new_place_ignore') return;

      let ctx = action['context'] as Record<string, string>;
      if (!ctx) return;
      let ruleId = ctx['ruleId'] ?? '';
      let ruleName = ctx['ruleName'] ?? '';
      let feedback = ctx['feedback'] ?? '';

      this.log.info(TAG, `Context feedback: ruleId=${ruleId}, ruleName=${ruleName}, feedback=${feedback}`);

      // Update rule based on feedback
      let engine = ContextEngineService.getInstance();
      let fbService = FeedbackService.getInstance();
      // Register rule name for stats display
      if (ruleName.length > 0) {
        fbService.setRuleName(ruleId, ruleName);
      }
      if (feedback === 'accept') {
        // Positive: increase priority slightly
        let delta = 0.2;
        this.adjustRulePriority(engine, ruleId, delta);
        fbService.onThumbsUp(ruleId);
        let displayName = ruleName.length > 0 ? ruleName : ruleId;
        let acceptMsg = `✅ ${I18n.t('ctx.fb.accepted')}\n\n` +
          `📋 ${I18n.t('ctx.fb.rule')}：${displayName}\n` +
          `📈 ${I18n.t('ctx.fb.weightUp').replace('{0}', delta.toString())}`;
        this.sendFeedbackResponse(acceptMsg);
        this.pushA2UIConfirmation(acceptMsg);

        // Execute the recommended action
        let cachedRec = this._activeRecommendations.get(ruleId);
        if (cachedRec && cachedRec.action) {
          this.executeRecommendedAction(cachedRec.action);
        }
      } else if (feedback === 'reject') {
        // Negative: decrease priority
        let delta = -0.3;
        fbService.onThumbsDown(ruleId);
        let displayName = ruleName.length > 0 ? ruleName : ruleId;
        // Check current priority to determine action
        let willDisable = false;
        let rulesJson = engine.exportRules();
        let allRules: ContextRule[] = JSON.parse(rulesJson) as ContextRule[];
        for (let i = 0; i < allRules.length; i++) {
          if (allRules[i].id === ruleId) {
            let newP = (allRules[i].priority ?? 1.0) + delta;
            willDisable = newP <= 0.3;
            break;
          }
        }
        this.adjustRulePriority(engine, ruleId, delta);
        let actionText = willDisable
          ? `🚫 ${I18n.t('ctx.fb.ruleDisabled')}`
          : `📉 ${I18n.t('ctx.fb.weightDown')}`;
        this.sendFeedbackResponse(
          `❌ ${I18n.t('ctx.fb.rejected')}\n\n` +
          `📋 ${I18n.t('ctx.fb.rule')}：${displayName}\n` +
          `${actionText}\n\n` +
          `👇 ${I18n.t('ctx.fb.askScene')}`
        );
        // Show follow-up: ask user what they're actually doing
        this.showSceneCorrectionCard(ruleId);
      } else if (feedback === 'scene_correct_combined') {
        // Combined location + activity from ChoicePicker form
        let locText = (ctx['choice_loc_picker'] ?? '') as string;   // "🏠 在家"
        let actText = (ctx['choice_act_picker'] ?? '') as string;   // "💻 工作中"
        // Extract pure text (remove emoji prefix)
        let location = locText.replace(/^[^\u4e00-\u9fa5a-zA-Z]*/, '').replace(/^在/, '');  // "家"
        let scene = actText.replace(/^[^\u4e00-\u9fa5a-zA-Z]*/, '').replace(/中$/, '').replace(/了$/, '');  // "工作"
        this.log.info(TAG, `Scene correction combined: ruleId=${ruleId} location=${location} scene=${scene} (raw: loc="${locText}" act="${actText}")`);

        let boostedCount = this.boostRulesMatchingScene(engine, location, scene);

        let detail = '';
        if (location.length > 0 && scene.length > 0) {
          detail = I18n.t('ctx.fb.atPlace').replace('{0}', location).replace('{1}', scene);
        } else if (location.length > 0) {
          detail = I18n.t('ctx.fb.atPlaceOnly').replace('{0}', location);
        } else if (scene.length > 0) {
          detail = scene;
        } else {
          detail = I18n.t('ctx.fb.notSelected');
        }
        let boostText = boostedCount > 0
          ? `\n📈 ${I18n.t('ctx.fb.boosted').replace('{0}', boostedCount.toString())}`
          : '';
        let feedbackMsg = `📝 ${I18n.t('ctx.fb.corrected')}\n\n` +
          `🎯 ${I18n.t('ctx.fb.actualScene')}：${detail}\n` +
          `🧠 ${I18n.t('ctx.fb.learnPattern')}${boostText}`;
        this.sendFeedbackResponse(feedbackMsg);
        // Replace form card with confirmation
        this.pushA2UIConfirmation(feedbackMsg);

        // Persist activity to geofence's typicalActivities
        let cas = ContextAwarenessService.getInstance();
        if (scene.length > 0) {
          cas.learnActivityForCurrentGeofence(scene);
        }
      } else if (feedback === 'scene_correct') {
        // Legacy: single button scene correction (kept for backward compat)
        let scene = ctx['scene'] ?? '';
        let location = ctx['location'] ?? '';
        this.log.info(TAG, `Scene correction: ruleId=${ruleId} scene=${scene} location=${location}`);

        // Boost rules that match the user's actual scene
        let boostedCount = this.boostRulesMatchingScene(engine, location, scene);

        let detail = '';
        if (location.length > 0 && scene.length > 0) {
          detail = I18n.t('ctx.fb.atPlace').replace('{0}', location).replace('{1}', scene);
        } else if (location.length > 0) {
          detail = I18n.t('ctx.fb.atPlaceOnly').replace('{0}', location);
        } else if (scene.length > 0) {
          detail = scene;
        }
        let boostText = boostedCount > 0
          ? `\n📈 ${I18n.t('ctx.fb.boosted').replace('{0}', boostedCount.toString())}`
          : '';
        let legacyMsg = `📝 ${I18n.t('ctx.fb.corrected')}\n\n` +
          `🎯 ${I18n.t('ctx.fb.actualScene')}：${detail}\n` +
          `🧠 ${I18n.t('ctx.fb.learnPattern')}${boostText}`;
        this.sendFeedbackResponse(legacyMsg);
        this.pushA2UIConfirmation(legacyMsg);
      } else if (feedback === 'view_snapshot') {
        // Show current scene snapshot with all sensor data
        this.showSceneSnapshotCard();
      } else if (feedback === 'back_to_rec') {
        // Return from snapshot to recommendation card
        if (this._lastRecRuleId.length > 0) {
          let a2uiJsonl = this.buildContextRecommendationA2UI(
            this._lastRecRuleId, this._lastRecRuleName, this._lastRecReason, this._lastRecConfidence);
          this.dispatchA2UI('push', a2uiJsonl);
        }
      } else if (feedback === 'dismiss') {
        // Dismiss is a mild negative signal, don't record as thumbs_down
        this.sendFeedbackResponse('🙈 ' + I18n.t('ctx.fb.dismissed'));
        this.pushA2UIConfirmation('🙈 ' + I18n.t('ctx.fb.dismissedShort'));
      }
      // Handle new place detection events
      else if (name === 'new_place_save') {
        let lat = parseFloat(ctx['lat'] ?? '0');
        let lng = parseFloat(ctx['lng'] ?? '0');
        let wifi = ctx['wifi'] ?? '';
        let placeName = ctx['name'] ?? '新地点';
        let category = ctx['category'] ?? 'other';
        this.saveNewPlace(lat, lng, wifi, placeName, category);
      } else if (name === 'new_place_rename') {
        // TODO: Show rename dialog
        this.sendFeedbackResponse('✏️ 重命名功能开发中，暂时保存为新地点');
        let lat = parseFloat(ctx['lat'] ?? '0');
        let lng = parseFloat(ctx['lng'] ?? '0');
        this.saveNewPlace(lat, lng, '', '新地点', 'other');
      } else if (name === 'new_place_ignore') {
        this.sendFeedbackResponse('👌 ' + I18n.t('ctx.fb.ignoredPlace'));
      }
    } catch (err) {
      this.log.warn(TAG, `handleA2UIAction error: ${(err as Error).message}`);
    }
  }

  /** Execute the recommended action via ActionExecutor, send result to chat */
  private executeRecommendedAction(action: UserAction): void {
    if (!this._actionExecutor) {
      try {
        let cas = ContextAwarenessService.getInstance();
        let calPlugin = cas.getCalendarPlugin();
        if (calPlugin) {
          this._actionExecutor = new ActionExecutor(calPlugin);
        }
      } catch { /* CalendarPlugin not available */ }
    }
    if (!this._actionExecutor) return;

    this._actionExecutor.execute(action).then((result: ActionResult) => {
      if (result.success && result.message.length > 0) {
        let event: GatewayChatEvent = {
          runId: `ctx-action-${Date.now()}`,
          sessionKey: '',
          seq: 0,
          state: 'final',
          message: {
            role: 'assistant',
            content: [{ type: 'text', text: result.message }],
          },
        };
        this.dispatchChatEvent(event);
      }
    }).catch((err: Error) => {
      this.log.warn(TAG, `Action execution failed: ${err.message}`);
    });
  }

  private saveNewPlace(lat: number, lng: number, wifi: string, name: string, category: string): void {
    try {
      let cas = ContextAwarenessService.getInstance();
      let learnedSignals: LearnedPlaceSignals = {
        wifiSSIDs: wifi ? [wifi] : [],
        bluetoothDevices: [],
        typicalTimes: [],
        lastSeen: Date.now(),
        visitCount: 1
      };
      let gf: Geofence = {
        id: 'place_' + Date.now(),
        name: name,
        latitude: lat,
        longitude: lng,
        radiusMeters: 100,
        category: category as GeofenceCategory,
        metadata: wifi ? { 'wifi': wifi } as Record<string, string> : undefined,
        learnedSignals: learnedSignals
      };
      cas.addGeofence(gf);
      this.log.info(TAG, `Saved new place: ${name} at (${lat}, ${lng})`);
      
      // Show confirmation card in chat
      let savedText = I18n.t('context.geofence.saved');
      let categoryText = I18n.t('context.geofence.category');
      let wifiText = I18n.t('context.geofence.newWifi');
      
      let detailParts: string[] = [];
      detailParts.push(`${categoryText}: ${category}`);
      if (wifi) {
        detailParts.push(`${wifiText}: ${wifi}`);
      }
      
      let jsonl = '{"type":"form","id":"place_saved_' + Date.now() + '","children":[' +
        '{"type":"text","text":"✅ ' + savedText + '","style":{"fontSize":16,"fontWeight":"bold"}},' +
        '{"type":"text","text":"' + name + '","style":{"fontSize":14}},' +
        '{"type":"text","text":"' + detailParts.join(' | ') + '","style":{"fontSize":12,"color":"#666"}}' +
        ']}';
      this.dispatchA2UI('push', jsonl);
    } catch (err) {
      this.log.warn(TAG, `saveNewPlace error: ${(err as Error).message}`);
    }
  }

  /**
   * Boost rules that match the user's actual scene after correction.
   * Returns count of rules boosted.
   */
  private boostRulesMatchingScene(engine: ContextEngineService, location: string, scene: string): number {
    // Map location/scene to keywords for matching
    let keywords: string[] = [];
    if (location.length > 0) {
      let locKeywords: Record<string, string[]> = {
        '家': ['家', 'home', 'evening', 'night'],
        '公司': ['公司', 'work', '工作', 'office'],
        '路上': ['路上', 'transit', '通勤', 'commute', 'driving'],
        '商场': ['商场', 'shopping', '购物'],
        '餐厅': ['餐厅', 'restaurant', '吃饭', 'dining'],
        '机场': ['机场', 'airport', 'transit', '飞机'],
        '火车站': ['火车站', 'train', 'transit', '高铁'],
        '咖啡厅': ['咖啡', 'cafe', 'coffee'],
        '健身房': ['健身', 'gym', '运动'],
      };
      if (locKeywords[location]) {
        for (let i = 0; i < locKeywords[location].length; i++) {
          keywords.push(locKeywords[location][i].toLowerCase());
        }
      } else {
        // Dynamic: use the location text itself and try geofence category match
        keywords.push(location.toLowerCase());
        // Check if location matches any geofence name → use its category
        try {
          let cas = ContextAwarenessService.getInstance();
          let allGf = cas.getAllGeofences();
          for (let g = 0; g < allGf.length; g++) {
            if (allGf[g].name === location || allGf[g].name.includes(location)) {
              keywords.push(allGf[g].category.toLowerCase());
              break;
            }
          }
        } catch { /* ignore */ }
      }
    }
    if (scene.length > 0) {
      let sceneKeywords: Record<string, string[]> = {
        '工作': ['工作', 'work', 'office', '公司'],
        '休息': ['休息', 'relax', 'home', 'evening', '家'],
        '运动': ['运动', 'gym', '健身', 'exercise', '健身房'],
        '吃饭': ['吃饭', 'dining', '餐厅', 'restaurant', 'lunch', 'dinner'],
        '通勤': ['通勤', 'commute', 'transit', 'driving', '路上'],
        '睡觉': ['睡觉', 'sleep', 'bedtime', 'night', '家'],
        '准备睡觉': ['睡觉', 'sleep', 'bedtime', 'night', '家'],
        '赶飞机': ['飞机', 'airport', 'transit', 'flight'],
        '坐火车': ['火车', 'train', 'transit', '高铁'],
        '逛街': ['逛街', 'shopping', '商场', '购物'],
        '开车': ['开车', 'driving', 'vehicle', '路上'],
      };
      if (sceneKeywords[scene]) {
        for (let i = 0; i < sceneKeywords[scene].length; i++) {
          keywords.push(sceneKeywords[scene][i].toLowerCase());
        }
      } else {
        // Dynamic: use the scene text itself
        keywords.push(scene.toLowerCase());
      }
    }

    if (keywords.length === 0) return 0;

    // Find and boost matching rules
    let rulesJson = engine.exportRules();
    let rules: ContextRule[] = JSON.parse(rulesJson) as ContextRule[];
    let boosted = 0;

    for (let i = 0; i < rules.length; i++) {
      let rule = rules[i];
      if (!rule.enabled) continue;

      // Match by rule name
      let ruleNameLower = (rule.name ?? '').toLowerCase();
      let matches = false;
      for (let j = 0; j < keywords.length; j++) {
        if (ruleNameLower.includes(keywords[j])) {
          matches = true;
          break;
        }
      }

      // Also check condition values
      if (!matches && rule.conditions) {
        for (let k = 0; k < rule.conditions.length; k++) {
          let condValue = (rule.conditions[k].value ?? '').toLowerCase();
          for (let j = 0; j < keywords.length; j++) {
            if (condValue.includes(keywords[j])) {
              matches = true;
              break;
            }
          }
          if (matches) break;
        }
      }

      if (matches) {
        let currentPriority = rule.priority ?? 1.0;
        let newPriority = Math.min(5.0, currentPriority + 0.15);
        rule.priority = newPriority;
        engine.addRule(rule);
        boosted++;
        this.log.info(TAG, `Boosted rule ${rule.id} (${rule.name}) priority: ${currentPriority} → ${newPriority}`);
      }
    }

    return boosted;
  }

  private async adjustRulePriority(engine: ContextEngineService, ruleId: string, delta: number): Promise<void> {
    try {
      let rulesJson = engine.exportRules();
      let rules: ContextRule[] = JSON.parse(rulesJson) as ContextRule[];
      for (let i = 0; i < rules.length; i++) {
        if (rules[i].id === ruleId) {
          let currentPriority = rules[i].priority ?? 1.0;
          let newPriority = Math.max(0.1, Math.min(5.0, currentPriority + delta));
          rules[i].priority = newPriority;

          // If negative feedback: extend cooldown significantly
          if (delta < 0) {
            // Double the cooldown each time (min 4h, max 48h)
            let currentCooldown = rules[i].cooldownMs ?? 14400000;
            rules[i].cooldownMs = Math.min(currentCooldown * 2, 172800000);
          }

          // Auto-disable rule if priority drops too low (user keeps rejecting)
          if (newPriority <= 0.3) {
            rules[i].enabled = false;
            this.log.info(TAG, `Rule ${ruleId} AUTO-DISABLED: priority ${newPriority} <= 0.3`);
          }

          let ok = await engine.addRule(rules[i]);
          this.log.info(TAG, `Rule ${ruleId} priority: ${currentPriority} → ${newPriority}, cooldown=${rules[i].cooldownMs}ms, enabled=${rules[i].enabled}, ok=${ok}`);
          break;
        }
      }
    } catch (err) {
      this.log.warn(TAG, `adjustRulePriority error: ${(err as Error).message}`);
    }
  }

  private async showSceneCorrectionCard(ruleId: string): Promise<void> {
    let safeRuleId = ruleId.replace(/\\/g, '\\\\').replace(/"/g, '\\"');

    // Try smart inference
    let locOptions: string[] = [];
    let actOptions: string[] = [];
    let detectedSummary = '';

    try {
      let cas = ContextAwarenessService.getInstance();
      this.log.info(TAG, `showSceneCorrectionCard: starting smart inference...`);
      let locations = await cas.getLocationCandidates();
      this.log.info(TAG, `showSceneCorrectionCard: got ${locations.length} location candidates`);
      let activities = cas.inferActivityCandidates(locations);
      this.log.info(TAG, `showSceneCorrectionCard: got ${activities.length} activity candidates`);

      // Build detected summary from top candidate (skip "Other")
      if (locations.length > 1 && locations[0].source !== 'manual') {
        detectedSummary = `📡 ${I18n.t('ctx.correction.detected')}: ${locations[0].emoji} ${locations[0].name}`;
      }

      // Build location options: "emoji name"
      for (let i = 0; i < locations.length; i++) {
        let loc = locations[i];
        locOptions.push(`${loc.emoji} ${loc.name}`);
      }

      // Build activity options: "emoji name"
      for (let i = 0; i < activities.length; i++) {
        let act = activities[i];
        actOptions.push(`${act.emoji} ${act.name}`);
      }
    } catch (err) {
      this.log.warn(TAG, `Smart correction error, using fallback: ${(err as Error).message}`);
    }

    // Fallback to hardcoded if inference failed
    if (locOptions.length === 0) {
      locOptions = ['🏠 在家', '🏢 在公司', '🚇 在路上', '🛒 在商场', '🍜 在餐厅'];
    }
    if (actOptions.length === 0) {
      actOptions = ['💻 工作中', '🛋️ 休息中', '🏃 运动中', '🍽️ 吃饭中', '🚶 通勤中', '😴 要睡了'];
    }

    let locJson = JSON.stringify(locOptions);
    let actJson = JSON.stringify(actOptions);

    let summaryLine = detectedSummary.length > 0
      ? `{"type":"text","text":"${detectedSummary}","style":{"fontSize":14,"color":"#4CAF50"}},`
      : '';

    let jsonl = `{"type":"form","id":"scene_correct_${Date.now()}","children":[` +
      `{"type":"text","text":"你现在在哪儿，在干什么？","style":{"fontSize":16,"fontWeight":"bold"}},` +
      summaryLine +
      `{"type":"text","text":"可同时选择位置和活动","style":{"fontSize":13,"color":"#888"}},` +
      `{"type":"text","text":"📍 位置","style":{"fontSize":14,"fontWeight":"bold"}},` +
      `{"type":"choice","id":"loc_picker","options":${locJson}},` +
      `{"type":"text","text":"🎯 在做什么","style":{"fontSize":14,"fontWeight":"bold"}},` +
      `{"type":"choice","id":"act_picker","options":${actJson}},` +
      `{"type":"button","text":"✅ 确认","variant":"primary","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","feedback":"scene_correct_combined"}}}},` +
      `{"type":"button","text":"🙅 跳过","variant":"borderless","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","feedback":"dismiss"}}}}` +
      `]}`;

    this.dispatchA2UI('push', jsonl);
  }

  private showSceneSnapshotCard(): void {
    let cas = ContextAwarenessService.getInstance();
    // Use both sources: digital world service for latest + cached data
    let digitalService = cas.getDigitalWorldService();
    let digitalData = digitalService.getDigitalData();

    // Build sensor data lines
    let lines: string[] = [];

    // Time
    let now = new Date();
    let dayNames = ['日', '一', '二', '三', '四', '五', '六'];
    let h = now.getHours();
    let m = now.getMinutes();
    lines.push(`⏰ 时间: ${h}:${m < 10 ? '0' + m : m} 周${dayNames[now.getDay()]} ${h >= 9 && h < 18 && now.getDay() > 0 && now.getDay() < 6 ? '(工作时间)' : ''}`);

    // Location / Geofence
    let geofence = digitalData['geofence'] ?? '';
    let wifiSsid = digitalData['wifi_ssid'] ?? digitalData['ssid'] ?? '';
    if (geofence.length > 0) {
      lines.push(`📍 位置: ${geofence}`);
    }
    if (wifiSsid.length > 0) {
      lines.push(`📶 WiFi: ${wifiSsid}`);
    }

    // Motion & Steps
    let stepCount = digitalData['step_count_today'] ?? '';
    let isActive = digitalData['is_active'] ?? '';
    if (stepCount.length > 0) {
      lines.push(`🚶 步数: 今日 ${stepCount} 步 | ${isActive === 'true' ? '活动中' : '静止'}`);
    }

    // Heart rate (wearable)
    let heartRate = digitalData['heart_rate'] ?? '';
    let hrStatus = digitalData['heart_rate_status'] ?? '';
    let wearing = digitalData['wearing_state'] ?? '';
    if (heartRate.length > 0 && heartRate !== '0') {
      let statusMap: Record<string, string> = {
        'resting': '休息', 'active': '活跃', 'exercise': '运动',
        'low': '偏低', 'unknown': '未知'
      };
      lines.push(`❤️ 心率: ${heartRate} bpm | ${statusMap[hrStatus] ?? hrStatus}`);
    }
    if (wearing.length > 0) {
      lines.push(`⌚ 穿戴: ${wearing === 'on_wrist' ? '佩戴中' : '未佩戴'}`);
    }

    // Bluetooth
    let btDevices = digitalData['connected_devices'] ?? digitalData['bt_connected'] ?? '';
    let btState = digitalData['bluetooth_state'] ?? '';
    if (btDevices.length > 0) {
      lines.push(`🔵 蓝牙: ${btDevices}`);
    } else if (btState.length > 0) {
      lines.push(`🔵 蓝牙: ${btState === 'on' ? '开启' : '关闭'}`);
    }

    // Screen
    let screenState = digitalData['screen_state'] ?? '';
    if (screenState.length > 0) {
      lines.push(`📱 屏幕: ${screenState === 'on' ? '亮屏' : '息屏'}`);
    }

    // Calendar
    let calEvent = digitalData['cal_nextEvent'] ?? digitalData['next_event'] ?? '';
    let inMeeting = digitalData['cal_inMeeting'] ?? '';
    if (calEvent.length > 0) {
      lines.push(`📅 日历: ${calEvent}`);
    }
    if (inMeeting === 'true') {
      lines.push(`📅 状态: 会议中`);
    }

    // Battery
    let battery = digitalData['battery_level'] ?? '';
    let charging = digitalData['is_charging'] ?? '';
    if (battery.length > 0) {
      lines.push(`🔋 电量: ${battery}% ${charging === 'true' ? '(充电中)' : ''}`);
    }

    // Media
    let mediaState = digitalData['media_playing'] ?? '';
    if (mediaState === 'true') {
      lines.push(`🎵 媒体: 播放中`);
    }

    // App category
    let appCat = digitalData['app_category'] ?? '';
    if (appCat.length > 0 && appCat !== 'unknown') {
      lines.push(`📱 前台App: ${appCat}`);
    }

    // Build A2UI card with back button
    let linesText = lines.join('\\n');
    let jsonl = `{"type":"form","id":"snapshot_${Date.now()}","children":[` +
      `{"type":"text","text":"🔍 场景快照","style":{"fontSize":18,"fontWeight":"bold"}},` +
      `{"type":"text","text":"当前系统感知到的所有信号：","style":{"fontSize":13,"color":"#888"}},` +
      `{"type":"text","text":"${linesText}","style":{"fontSize":14}},` +
      `{"type":"button","text":"← 返回","variant":"borderless","action":{"event":{"name":"context_feedback","context":{"feedback":"back_to_rec"}}}}` +
      `]}`;

    this.dispatchA2UI('push', jsonl);
  }

  private sendFeedbackResponse(text: string): void {
    let event: GatewayChatEvent = {
      runId: `feedback-${Date.now()}`,
      sessionKey: '',
      seq: 0,
      state: 'final',
      message: {
        role: 'assistant',
        content: [{ type: 'text', text: text }],
      },
    };
    this.dispatchChatEvent(event);
  }

  /**
   * Push a brief A2UI confirmation card that replaces the current form.
   * Used to dismiss form cards after user feedback.
   */
  private pushA2UIConfirmation(text: string): void {
    let safeText = text.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');
    let jsonl = `{"type":"form","id":"confirm_${Date.now()}","children":[` +
      `{"type":"text","text":"${safeText}","style":{"fontSize":14,"color":"#4CAF50"}}` +
      `]}`;
    this.dispatchA2UI('push', jsonl);
  }

  addIdentityListener(listener: (identity: AgentIdentity | undefined) => void): void {
    this._identityListeners.push(listener);
  }

  removeIdentityListener(listener: (identity: AgentIdentity | undefined) => void): void {
    let idx = this._identityListeners.indexOf(listener);
    if (idx >= 0) {
      this._identityListeners.splice(idx, 1);
    }
  }

  private dispatchIdentity(identity: AgentIdentity | undefined): void {
    this.log.info(TAG, `dispatchIdentity: name=${identity ? identity.name : '(none)'} emoji=${identity ? identity.emoji : ''} avatar=${identity ? identity.avatar : ''} cachedAvatar=${this._cachedAvatarPath}`);
    for (let listener of this._identityListeners) {
      try {
        listener(identity);
      } catch { /* ignore */ }
    }
    // Trigger avatar download if identity has avatar but not yet cached
    if (identity && identity.avatar.length > 0 && this._cachedAvatarPath.length === 0) {
      this.downloadAndCacheAvatar();
    }
    // Persist identity for faster resume
    if (identity && identity.name.length > 0) {
      this.saveCachedIdentity();
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
    let cleanHost = ep.host.endsWith('/') ? ep.host.slice(0, ep.host.lastIndexOf('/')) : ep.host;
    return `${scheme}://${cleanHost}:${ep.port}/media/${path}`;
  }

  /** Resolve gateway agent avatar to a loadable URL. Returns undefined if not resolvable. */
  resolveAgentAvatarUrl(): string | undefined {
    // Prefer cached local file (already downloaded)
    if (this._cachedAvatarPath.length > 0) {
      return this._cachedAvatarPath;
    }
    let identity = this._agentIdentity;
    if (!identity || identity.avatar.length === 0) return undefined;
    let av = identity.avatar;
    if (av.startsWith('data:')) {
      return av;
    }
    if (av.startsWith('http://') || av.startsWith('https://')) {
      return av;
    }
    let ep = this._endpoint;
    if (!ep) return undefined;
    let path = av.startsWith('/') ? av.substring(1) : av;
    let scheme = ep.useTls ? 'https' : 'http';
    let cleanHost = ep.host.endsWith('/') ? ep.host.slice(0, ep.host.lastIndexOf('/')) : ep.host;
    return `${scheme}://${cleanHost}:${ep.port}/media/${path}`;
  }

  /** Download avatar image from URL and cache locally. Dispatches identity again with updated avatar. */
  async downloadAndCacheAvatar(): Promise<void> {
    // Skip if already cached and file still exists
    if (this._cachedAvatarPath.length > 0) {
      try {
        fileIo.accessSync(this._cachedAvatarPath);
        return; // file exists, skip download
      } catch {
        this._cachedAvatarPath = ''; // file gone, re-download
      }
    }
    let ep = this._endpoint;
    if (!ep) return;
    let identity = this._agentIdentity;
    if (!identity || identity.avatar.length === 0) return;

    // Build candidate URLs: try /avatar/{agentId} first (OpenClaw gateway), then /media/{path}
    let scheme = ep.useTls ? 'https' : 'http';
    let cleanHost = ep.host.endsWith('/') ? ep.host.slice(0, ep.host.lastIndexOf('/')) : ep.host;
    let baseUrl = `${scheme}://${cleanHost}:${ep.port}`;
    let urls: string[] = [
      `${baseUrl}/avatar/${this._agentId}`,
      `${baseUrl}/media/${identity.avatar}`,
    ];
    // If avatar is already an absolute URL, try that too
    let av = identity.avatar;
    if (av.startsWith('http://') || av.startsWith('https://')) {
      urls = [av, ...urls];
    }

    this.log.info(TAG, `Downloading avatar, trying ${urls.length} URLs: ${urls.join(' | ')}`);

    for (let url of urls) {
      let req = http.createHttp();
      try {
        this.log.info(TAG, `Trying avatar URL: ${url}`);
        let response = await req.request(url, {
          method: http.RequestMethod.GET,
          expectDataType: http.HttpDataType.ARRAY_BUFFER,
          connectTimeout: 8000,
          readTimeout: 10000,
        });
        let headers = response.header as Record<string, string>;
        let ct = headers['content-type'] ?? headers['Content-Type'] ?? '';
        let data = response.result as ArrayBuffer;
        this.log.info(TAG, `Avatar response: HTTP ${response.responseCode}, content-type: ${ct}, size: ${data ? data.byteLength : 0}`);

        // Must be HTTP 200 with image content-type
        if (response.responseCode !== 200 || !data) continue;
        if (!ct.includes('image/')) {
          this.log.warn(TAG, `Skipping non-image response: ${ct}`);
          continue;
        }

        // Save to local cache
        let ctx = this._context;
        if (!ctx) return;
        let ext = 'jpg';
        if (ct.includes('png')) ext = 'png';
        else if (ct.includes('gif')) ext = 'gif';
        else if (ct.includes('webp')) ext = 'webp';
        let destPath = `${ctx.cacheDir}/gw_avatar.${ext}`;
        let file = fileIo.openSync(destPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
        fileIo.writeSync(file.fd, data);
        fileIo.closeSync(file);
        this._cachedAvatarPath = destPath;
        this.log.info(TAG, `Avatar cached to: ${destPath} (${data.byteLength} bytes)`);
        // Save to preferences for next launch
        this.saveCachedIdentity();
        // Re-dispatch identity so listeners pick up the cached avatar
        if (this._agentIdentity) {
          this.dispatchIdentity(this._agentIdentity);
        }
        return; // Success — stop trying
      } catch (err) {
        this.log.warn(TAG, `Avatar URL failed: ${url} — ${(err as Error).message ?? ''}`);
      } finally {
        req.destroy();
      }
    }
    this.log.warn(TAG, 'All avatar URLs failed');
  }

  /**
   * Report current Push Kit token to the Gateway so it can reach the device
   * via push notification when WebSocket is disconnected.
   * Non-blocking; silently ignored if token is empty or server rejects it.
   */
  private reportPushToken(): void {
    if (!this.operatorSession) return;
    let token = this.pushCapability.getToken();
    if (!token || token.length === 0) {
      this.log.info(TAG, 'reportPushToken: no token available yet, skipping');
      return;
    }
    let payload = JSON.stringify({ token: token, platform: 'harmony' });
    this.operatorSession.request('node.pushToken', payload, 10000).then(() => {
      this.log.info(TAG, `Push token reported to gateway (${token.substring(0, 20)}...)`);
    }).catch((err: Error) => {
      // Server may not support this method yet — non-fatal
      this.log.warn(TAG, `reportPushToken failed (server may not support node.pushToken): ${err.message}`);
    });
  }

  /** Fetch agent identity from gateway config via operator session RPC. */
  async fetchAgentIdentity(): Promise<void> {
    if (!this.operatorSession) return;
    if (this._operatorState !== ConnectionState.Connected) return;
    this.log.info(TAG, 'Fetching agent identity from gateway config...');

    // Strategy 0: Extract identity from connect response (most reliable source)
    let connectRes = this.operatorSession.getConnectResult();
    if (connectRes) {
      this.log.debug(TAG, `Connect response keys: [${Object.keys(connectRes).join(',')}]`);
      let identity: AgentIdentity | undefined = undefined;

      // Check agent.identity (common OpenClaw format)
      let agent = connectRes['agent'] as Record<string, Object> | undefined;
      if (agent && typeof agent === 'object') {
        this.log.info(TAG, `Connect response agent keys: [${Object.keys(agent).join(',')}]`);
        let agentIdentity = agent['identity'] as Record<string, string> | undefined;
        if (agentIdentity && (agentIdentity['name'] ?? '').length > 0) {
          identity = {
            name: agentIdentity['name'] ?? '',
            theme: agentIdentity['theme'] ?? '',
            emoji: agentIdentity['emoji'] ?? '',
            avatar: agentIdentity['avatar'] ?? '',
          };
          this.log.info(TAG, `Identity from connect agent.identity: name="${identity.name}" emoji="${identity.emoji}"`);
        }
        // Check agent.name (simpler format)
        if (!identity) {
          let agentName = (agent['name'] as string) ?? '';
          if (agentName.length > 0) {
            identity = { name: agentName, theme: '', emoji: '', avatar: '' };
            this.log.info(TAG, `Identity from connect agent.name: "${agentName}"`);
          }
        }
      }

      // Check top-level identity
      if (!identity) {
        let topIdentity = connectRes['identity'] as Record<string, string> | undefined;
        if (topIdentity && (topIdentity['name'] ?? '').length > 0) {
          identity = {
            name: topIdentity['name'] ?? '',
            theme: topIdentity['theme'] ?? '',
            emoji: topIdentity['emoji'] ?? '',
            avatar: topIdentity['avatar'] ?? '',
          };
          this.log.info(TAG, `Identity from connect identity: name="${identity.name}"`);
        }
      }

      // Check config.agents (embedded config in connect response)
      if (!identity) {
        let embeddedConfig = connectRes['config'] as Record<string, Object> | undefined;
        if (embeddedConfig && typeof embeddedConfig === 'object') {
          identity = this.extractAgentIdentityFromConfig(embeddedConfig) ?? undefined;
          if (identity) {
            this.log.info(TAG, `Identity from connect config.agents: name="${identity.name}"`);
          }
        }
      }

      if (identity) {
        this._agentIdentity = identity;
        this.dispatchIdentity(identity);
        return;
      }
      this.log.info(TAG, 'No identity in connect response, falling through to config.get...');
    }

    // Strategy 1: config.get RPC
    try {
      let resJson = await this.operatorSession.request('config.get', '{}', 10000);
      this.log.debug(TAG, `config.get response (500): ${resJson.substring(0, 500)}`);
      if (resJson.length === 0) return;
      let wrapper = JSON.parse(resJson) as Record<string, Object>;
      // config.get returns { path, exists, raw: "<json string>" } — parse raw field
      let config: Record<string, Object>;
      let rawStr = wrapper['raw'] as string | undefined;
      if (rawStr && rawStr.length > 0) {
        config = JSON.parse(rawStr) as Record<string, Object>;
      } else {
        config = wrapper;
      }
      this.log.debug(TAG, `config keys: [${Object.keys(config).join(',')}]`);

      // Strategy 1a: Look for agent identity in agents block
      let identity = this.extractAgentIdentityFromConfig(config);
      if (identity) {
        this._agentIdentity = identity;
        this.dispatchIdentity(identity);
        return;
      }

      // Strategy 1b: Check gateway.name or gateway.identity
      let gw = config['gateway'] as Record<string, Object> | undefined;
      if (gw) {
        let gwKeys = Object.keys(gw);
        this.log.info(TAG, `gateway keys: [${gwKeys.join(',')}]`);
        let gwIdentity = gw['identity'] as Record<string, string> | undefined;
        if (gwIdentity && (gwIdentity['name'] ?? '').length > 0) {
          identity = {
            name: gwIdentity['name'] ?? '',
            theme: gwIdentity['theme'] ?? '',
            emoji: gwIdentity['emoji'] ?? '',
            avatar: gwIdentity['avatar'] ?? '',
          };
          this.log.info(TAG, `Using gateway.identity: name="${identity.name}"`);
          this._agentIdentity = identity;
          this.dispatchIdentity(identity);
          return;
        }
        let gwName = (gw['name'] as string) ?? '';
        if (gwName.length > 0) {
          this.log.info(TAG, `Using gateway.name: "${gwName}"`);
          this._agentIdentity = { name: gwName, theme: '', emoji: '', avatar: '' };
          this.dispatchIdentity(this._agentIdentity);
          return;
        }
      }

      // Strategy 3: Try reading clawdbot.json (agent config, separate from gateway config)
      this.log.info(TAG, 'No identity in openclaw.json, trying clawdbot.json...');
      let agentIdentity = await this.fetchIdentityFromAgentConfig();
      if (agentIdentity) {
        this._agentIdentity = agentIdentity;
        this.dispatchIdentity(agentIdentity);
        return;
      }

      // Strategy 4: Try status RPC
      this.log.info(TAG, 'No identity in config, trying status RPC...');
      await this.fetchIdentityFromStatus();
    } catch (err) {
      this.log.system(TAG, `fetchAgentIdentity failed: ${(err as Error).message ?? ''}`);
    }
  }

  /** Extract agent identity from config.agents block. Returns null if not found. */
  private extractAgentIdentityFromConfig(config: Record<string, Object>): AgentIdentity | null {
    let agents = config['agents'] as Object | undefined;
    if (!agents || typeof agents !== 'object') return null;

    let agentsObj = agents as Record<string, Object>;

    // Check agents.defaults.identity first (common in openclaw.json)
    let defaults = agentsObj['defaults'] as Record<string, Object> | undefined;
    if (defaults && typeof defaults === 'object') {
      let defIdentity = defaults['identity'] as Record<string, string> | undefined;
      if (defIdentity && (defIdentity['name'] ?? '').length > 0) {
        let identity: AgentIdentity = {
          name: defIdentity['name'] ?? '',
          theme: defIdentity['theme'] ?? '',
          emoji: defIdentity['emoji'] ?? '',
          avatar: defIdentity['avatar'] ?? '',
        };
        this.log.info(TAG, `Agent identity from defaults: name="${identity.name}" emoji="${identity.emoji}" theme="${identity.theme}"`);
        return identity;
      }
    }

    // Try agents.list (array format)
    let agentList: Record<string, Object>[] = [];
    if (Array.isArray(agents)) {
      agentList = agents as Record<string, Object>[];
    } else if (agentsObj['list'] && Array.isArray(agentsObj['list'])) {
      agentList = agentsObj['list'] as Record<string, Object>[];
    } else {
      // Map format: named agents as keys (skip 'defaults' which is shared settings)
      let keys = Object.keys(agentsObj).filter((k: string) => k !== 'defaults');
      for (let k of keys) {
        let val = agentsObj[k];
        if (typeof val === 'object' && val !== null) {
          let entry = val as Record<string, Object>;
          if (!entry['id']) entry['id'] = k as Object;
          agentList.push(entry);
        }
      }
    }
    if (agentList.length === 0) return null;
    this.log.info(TAG, `Found ${agentList.length} agent(s) in config`);

    // Find default agent, or first
    let target = agentList[0];
    for (let agent of agentList) {
      if (agent['default'] === true || String(agent['default']) === 'true') {
        target = agent;
        break;
      }
    }
    // Save agent ID for avatar URL construction
    let agentId = (target['id'] as string) ?? 'main';
    this._agentId = agentId;
    this.log.info(TAG, `Agent id: "${agentId}"`);

    let identityObj = target['identity'] as Record<string, string> | undefined;
    if (identityObj) {
      let identity: AgentIdentity = {
        name: identityObj['name'] ?? '',
        theme: identityObj['theme'] ?? '',
        emoji: identityObj['emoji'] ?? '',
        avatar: identityObj['avatar'] ?? '',
      };
      this.log.info(TAG, `Agent identity: name="${identity.name}" emoji="${identity.emoji}" theme="${identity.theme}" avatar="${identity.avatar}"`);
      if (identity.name.length > 0) return identity;
    }
    // Use agent id as fallback name
    if (agentId.length > 0) {
      this.log.info(TAG, `Using agent id as name: "${agentId}"`);
      return { name: agentId, theme: '', emoji: '', avatar: '' };
    }
    return null;
  }

  /** Try reading agent config (clawdbot.json) for identity. */
  private async fetchIdentityFromAgentConfig(): Promise<AgentIdentity | null> {
    if (!this.operatorSession) return null;
    try {
      let resJson = await this.operatorSession.request('config.get', '{"name":"clawdbot"}', 8000);
      this.log.info(TAG, `clawdbot config response (500): ${resJson.substring(0, 500)}`);
      if (resJson.length === 0) return null;
      let wrapper = JSON.parse(resJson) as Record<string, Object>;
      let rawStr = wrapper['raw'] as string | undefined;
      let config: Record<string, Object>;
      if (rawStr && rawStr.length > 0) {
        config = JSON.parse(rawStr) as Record<string, Object>;
      } else {
        config = wrapper;
      }
      this.log.info(TAG, `clawdbot config keys: [${Object.keys(config).join(',')}]`);
      return this.extractAgentIdentityFromConfig(config);
    } catch (err) {
      this.log.info(TAG, `clawdbot config.get failed: ${(err as Error).message ?? ''}`);
      return null;
    }
  }

  /** Fallback: try status RPC to get gateway/agent name. */
  private async fetchIdentityFromStatus(): Promise<void> {
    if (!this.operatorSession) return;
    try {
      let resJson = await this.operatorSession.request('status', '{}', 8000);
      this.log.info(TAG, `status response (500): ${resJson.substring(0, 500)}`);
      if (resJson.length > 0) {
        let status = JSON.parse(resJson) as Record<string, Object>;
        this.log.info(TAG, `status keys: [${Object.keys(status).join(',')}]`);
        let name = (status['name'] as string) ?? (status['agentName'] as string) ??
          (status['hostname'] as string) ?? '';
        if (name.length > 0) {
          this.log.info(TAG, `Using status name: "${name}"`);
          this._agentIdentity = { name: name, theme: '', emoji: '', avatar: '' };
          this.dispatchIdentity(this._agentIdentity);
        }
      }
    } catch (err) {
      this.log.info(TAG, `status RPC failed: ${(err as Error).message ?? ''}`);
    }
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

  /** Load cached identity and avatar from ConfigManager. Call before connect(). */
  async loadCachedIdentity(context: common.UIAbilityContext): Promise<void> {
    try {
      let configMgr = ConfigManager.getInstance();
      await configMgr.init(context);
      
      let identity = configMgr.getIdentity();
      
      if (identity.cachedAvatarPath.length > 0) {
        try {
          fileIo.accessSync(identity.cachedAvatarPath);
          this._cachedAvatarPath = identity.cachedAvatarPath;
          this.log.info(TAG, `Loaded cached avatar: ${identity.cachedAvatarPath}`);
        } catch {
          this._cachedAvatarPath = '';
        }
      }

      if (identity.name.length > 0) {
        let obj: AgentIdentity = {
          name: identity.name,
          theme: identity.theme,
          emoji: identity.emoji,
          avatar: identity.avatar
        };
        this._agentIdentity = obj;
        this.log.info(TAG, `Loaded cached identity: ${obj.name}`);
        // 立即派发给 UI
        this.dispatchIdentity(obj);
      }
    } catch { /* ignore */ }
  }

  /** Save identity and avatar path to ConfigManager. */
  private async saveCachedIdentity(): Promise<void> {
    try {
      let configMgr = ConfigManager.getInstance();
      if (this._agentIdentity) {
        configMgr.updateIdentity(
          this._agentIdentity.name,
          this._agentIdentity.theme ?? '',
          this._agentIdentity.emoji ?? '',
          this._agentIdentity.avatar ?? '',
          this._cachedAvatarPath
        );
      } else {
        configMgr.updateCachedAvatarPath(this._cachedAvatarPath);
      }
      await configMgr.flush();
    } catch { /* ignore */ }
  }

  /**
   * Connect both operator and node sessions.
   * Use connectOperator() or connectNode() to connect individually.
   */
  connect(context: common.UIAbilityContext, endpoint: GatewayEndpoint, token?: string, password?: string, connectOperatorSession: boolean = true, connectNodeSession: boolean = true): void {

    // Disconnect existing sessions if connecting new ones
    if (connectOperatorSession && this.operatorSession) {
      this.operatorSession.disconnect();
      this.operatorSession = undefined;
    }
    if (connectNodeSession && this.nodeSession) {
      this.nodeSession.disconnect();
      this.nodeSession = undefined;
    }

    this._endpoint = endpoint;
    this._context = context;
    this._connectToken = token;
    this._connectPassword = password;
    this._pairingApproved = false;
    this._pairingNotified = false;
    this.log.info(TAG, `connect() called: ${endpoint.host}:${endpoint.port} tls=${endpoint.useTls} token=${token ? 'yes' : 'no'} password=${password ? 'yes' : 'no'} displayName="${this._displayName}"`);
    // Set context for capabilities that need file system access
    this.cameraCapability.setContext(context);
    this.screenCapability.setContext(context);
    this.canvasCapability.setContext(context);
    this.microphoneCapability.setContext(context);
    this.speakerCapability.setContext(context);
    this.emailCapability.setContext(context);
    this.calendarCapability.setContext(context);

    // Wire push token refresh so re-connect and token rotations re-report to gateway
    this.pushCapability.onTokenChanged = (_token: string) => {
      this.reportPushToken();
    };

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

    // Initialize NotificationHelper for background message alerts (click-to-open)
    let notifHelper = NotificationHelper.getInstance();
    notifHelper.init(context.abilityInfo.bundleName);
    notifHelper.requestPermission();

    // Start Context Awareness Service only if user enabled it
    this.maybeStartContextAwareness(context);

    // Wire up A2UI action callback
    this.canvasCapability.onA2UIAction = (actionJson: string) => {
      this.log.info(TAG, `A2UI callback (CanvasPage): ${actionJson.substring(0, 200)}`);
      // Handle locally, same as inline A2UI
      this.handleA2UIAction(actionJson);
    };

    // Create operator session (if requested)
    if (connectOperatorSession) {
      let operatorOpts = this.buildOperatorOptions();
      this.log.info(TAG, `Creating operator session: clientId=${operatorOpts.client.id} mode=${operatorOpts.client.mode} role=${operatorOpts.role}`);
      this.operatorSession = new GatewaySession(operatorOpts, this.identityStore, this.authStore);
      this.operatorSession.onStateChanged = (state, message) => {
        this._operatorState = state;
        this.updateStatus();
        this.log.system(TAG, `operator state: ${state} - ${message}`);
        if (state === ConnectionState.Connected) {
          Monitor.startModule('Gateway');
          this.fetchAgentIdentity().catch(() => { /* ignore */ });
          this.reportPushToken();
          // syncExperiencePack removed from auto-connect — user triggers manually via UI buttons
        } else if (state === ConnectionState.Disconnected) {
          Monitor.stopModule('Gateway');
        }
      };
      this.operatorSession.onEvent = (event, payloadJson) => {
        this.handleOperatorEvent(event, payloadJson);
      };
    }

    // Create node session (if requested)
    if (connectNodeSession) {
      let nodeOpts = this.buildNodeOptions();
      this.log.info(TAG, `Creating node session: clientId=${nodeOpts.client.id} mode=${nodeOpts.client.mode} role=${nodeOpts.role} caps=[${nodeOpts.caps.join(',')}] commands=[${nodeOpts.commands.join(',')}]`);
      this.nodeSession = new GatewaySession(nodeOpts, this.identityStore, this.authStore);
      this.nodeSession.onStateChanged = (state, message) => {
        this._nodeState = state;
        // Reset pairing flags when node disconnects so re-pairing notification can happen on reconnect
        if (state === ConnectionState.Reconnecting || state === ConnectionState.Disconnected) {
          this._pairingApproved = false;
          this._pairingNotified = false;
          this._pairingPending = false;
        }
        // Clear pending flag when connected
        if (state === ConnectionState.Connected) {
          this._pairingPending = false;
        }
        this.updateStatus();
        this.log.system(TAG, `node state: ${state} - ${message}`);
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
    }

    // Connect sessions (fire-and-forget, state updates via callbacks)
    if (connectOperatorSession && this.operatorSession) {
      this.log.info(TAG, 'Connecting operator session...');
      this.operatorSession.connect(context, endpoint, token, password);
    }
    if (connectNodeSession && this.nodeSession) {
      this.log.info(TAG, 'Connecting node session...');
      this.nodeSession.connect(context, endpoint, token, password);
    }

    // Start network change listener so reconnect fires immediately on WiFi/4G/VPN switch
    this.setupNetworkMonitor();
  }

  /** Connect only operator session */
  connectOperator(context: common.UIAbilityContext, endpoint: GatewayEndpoint, token?: string, password?: string): void {
    this.connect(context, endpoint, token, password, true, false);
  }

  /** Connect only node session */
  connectNode(context: common.UIAbilityContext, endpoint: GatewayEndpoint, token?: string, password?: string): void {
    this.connect(context, endpoint, token, password, false, true);
  }

  disconnect(disconnectOperatorSession: boolean = true, disconnectNodeSession: boolean = true): void {
    this.log.info(TAG, `disconnect() called: operator=${disconnectOperatorSession} node=${disconnectNodeSession}`);
    if (disconnectOperatorSession && this.operatorSession) {
      this.log.info(TAG, 'Disconnecting operator session');
      this.operatorSession.disconnect();
      this.operatorSession = undefined;
      this._operatorState = ConnectionState.Disconnected;
      if (this._agentIdentity) {
        this._agentIdentity = undefined;
        // Keep cached avatar path — file is still on disk, will be reused on reconnect
        this.dispatchIdentity(undefined);
      }
    }
    if (disconnectNodeSession && this.nodeSession) {
      this.log.info(TAG, 'Disconnecting node session');
      this.nodeSession.disconnect();
      this.nodeSession = undefined;
      this._nodeState = ConnectionState.Disconnected;
    }
    if (disconnectOperatorSession && disconnectNodeSession) {
      this._endpoint = undefined;
      // Tear down network monitor only on full disconnect
      this.teardownNetworkMonitor();
    }
    this.updateStatus();
  }

  /** Disconnect only operator session */
  disconnectOperator(): void {
    this.disconnect(true, false);
  }

  /** Disconnect only node session */
  disconnectNode(): void {
    this.disconnect(false, true);
  }

  // ── Network change monitoring ────────────────────────────────────────────

  /** Register a NetConnection listener that triggers forceReconnect() on both
   *  sessions whenever the active network changes (WiFi↔Cellular↔VPN).
   *  Call once at the start of connect(); safe to call repeatedly (no-op if
   *  already registered). */
  private setupNetworkMonitor(): void {
    if (this._netConnection) {
      return; // already registered
    }
    try {
      this._netConnection = connection.createNetConnection();

      this._netConnection.on('netAvailable', (netHandle: connection.NetHandle) => {
        this.log.info(TAG, `[NetMonitor] netAvailable netId=${netHandle.netId} — scheduling reconnect`);
        this.scheduleNetReconnect();
      });

      this._netConnection.on('netLost', (netHandle: connection.NetHandle) => {
        this.log.info(TAG, `[NetMonitor] netLost netId=${netHandle.netId}`);
        // Existing session error/close callbacks will handle reconnect backoff.
        // Cancel any pending net-triggered reconnect so we don't reconnect into dead air.
        if (this._netReconnectTimer >= 0) {
          clearTimeout(this._netReconnectTimer);
          this._netReconnectTimer = -1;
        }
      });

      this._netConnection.on('netCapabilitiesChange', (info: connection.NetCapabilityInfo) => {
        let typeName = this.bearerTypesToString(info.netCap.bearerTypes ?? []);
        this.log.info(TAG, `[NetMonitor] netCapabilitiesChange netId=${info.netHandle.netId} bearers=[${typeName}]`);
      });

      this._netConnection.register((err) => {
        if (err) {
          this.log.error(TAG, `[NetMonitor] register failed: code=${err.code} msg=${err.message}`);
        } else {
          this.log.info(TAG, '[NetMonitor] registered');
        }
      });
    } catch (e) {
      this.log.error(TAG, `[NetMonitor] setup error: ${e}`);
    }
  }

  /** Unregister the NetConnection listener. */
  private teardownNetworkMonitor(): void {
    if (this._netReconnectTimer >= 0) {
      clearTimeout(this._netReconnectTimer);
      this._netReconnectTimer = -1;
    }
    if (!this._netConnection) {
      return;
    }
    try {
      this._netConnection.unregister((err) => {
        if (err) {
          this.log.error(TAG, `[NetMonitor] unregister failed: code=${err.code} msg=${err.message}`);
        } else {
          this.log.info(TAG, '[NetMonitor] unregistered');
        }
      });
    } catch (e) {
      this.log.error(TAG, `[NetMonitor] teardown error: ${e}`);
    }
    this._netConnection = undefined;
  }

  /** Debounced reconnect: waits NET_RECONNECT_DEBOUNCE_MS after the last
   *  netAvailable event before calling forceReconnect() on both sessions. */
  private scheduleNetReconnect(): void {
    if (this._netReconnectTimer >= 0) {
      clearTimeout(this._netReconnectTimer);
    }
    this._netReconnectTimer = setTimeout(() => {
      this._netReconnectTimer = -1;
      this.log.info(TAG, '[NetMonitor] debounce elapsed — calling forceReconnect on sessions');
      if (this.operatorSession) {
        this.operatorSession.forceReconnect();
      }
      if (this.nodeSession) {
        this.nodeSession.forceReconnect();
      }
    }, NodeRuntime.NET_RECONNECT_DEBOUNCE_MS);
  }

  private bearerTypesToString(bearerTypes: number[]): string {
    return bearerTypes.map((t: number) => {
      if (t === connection.NetBearType.BEARER_WIFI) return 'WiFi';
      if (t === connection.NetBearType.BEARER_CELLULAR) return 'Cellular';
      if (t === connection.NetBearType.BEARER_VPN) return 'VPN';
      if (t === connection.NetBearType.BEARER_ETHERNET) return 'Ethernet';
      return `Unknown(${t})`;
    }).join(',') || 'none';
  }

  // ── End network change monitoring ────────────────────────────────────────

  private _pairingApproved: boolean = false;
  private _pairingNotified: boolean = false;
  private _pairingPending: boolean = false;  // true when waiting for pairing approval

  /**
   * Handle node pairing when Gateway returns NOT_PAIRED.
   *
   * The app cannot auto-approve pairing because operator session uses password auth,
   * which does NOT grant the required operator.pairing scope.
   *
   * Instead, we notify the user to approve pairing manually via CLI or Control UI.
   * The node session will keep reconnecting until pairing is approved.
   */
  private async autoApproveNodePairing(_oldRequestId: string): Promise<void> {
    if (this._pairingApproved) {
      if (this.nodeSession) this.nodeSession.notifyPairingDone();
      return;
    }

    // Only notify once per connection attempt
    if (!this._pairingNotified) {
      this._pairingNotified = true;
      this._pairingPending = true;
      this.updateStatus();  // Trigger UI update

      // Get nodeId for the notification
      let nodeId = '';
      if (this._context) {
        try {
          let identity = await this.identityStore.loadOrCreate(this._context);
          nodeId = identity.deviceId;
        } catch (e) {
          // ignore
        }
      }

      let shortId = nodeId.length > 12 ? nodeId.substring(0, 12) + '...' : nodeId;
      this.log.warn(TAG, `Node pairing required! Approve via CLI: openclaw nodes pending && openclaw nodes approve <requestId>`);
      this.log.info(TAG, `Node ID: ${shortId}`);
    }

    // Let node session keep reconnecting - it will succeed once pairing is approved
    if (this.nodeSession) {
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
      this._statusText = this._pairingNotified
        ? 'Connected (node pairing required)'
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
        case Command.CANVAS_PRESENT: {
          // Inline canvas: dispatch to ChatPage, don't open full-screen CanvasPage
          this.log.info(TAG, `canvas.present inline: params=${paramsStr.substring(0, 200)}`);
          this._inlineCanvasController = undefined;
          this.dispatchA2UI('canvas.present', '');
          // Wait for inline WebView controller to be ready
          try {
            await this.waitForInlineCanvas(5000);
            result = '{"ok":true,"action":"presented_inline"}';
          } catch {
            result = '{"ok":true,"action":"presented_inline","warning":"controller_timeout"}';
          }
          break;
        }
        case Command.CANVAS_NAVIGATE: {
          // Inline canvas: load URL in inline WebView
          let url = '';
          if (paramsJson) {
            try {
              let p = JSON.parse(paramsJson) as Record<string, string>;
              if (p['url'] !== undefined) url = p['url'];
            } catch { /* ignore */ }
          }
          this.log.info(TAG, `canvas.navigate inline: url=${url.substring(0, 200)}`);

          // Markdown files: check if content was passed in params, or try to fetch
          if (url.endsWith('.md')) {
            this.log.info(TAG, `Markdown file detected, opening DocViewer`);
            let mdPath = url.startsWith('file://') ? url.substring(7) : url;
            let mdTitle = 'Document';
            let mdSlash = mdPath.lastIndexOf('/');
            if (mdSlash >= 0) mdTitle = mdPath.substring(mdSlash + 1);
            try { mdTitle = decodeURIComponent(mdTitle); } catch { /* keep as-is */ }

            // Check if content was passed directly in params (from server-side)
            let mdContent = '';
            if (paramsJson) {
              try {
                let mp = JSON.parse(paramsJson) as Record<string, string>;
                if (mp['content'] !== undefined) mdContent = mp['content'];
              } catch { /* ignore */ }
            }

            // If no content in params, try fetching via operator session
            if (mdContent.length === 0) {
              this.log.info(TAG, `DocViewer: no content in params, trying requestFile`);
              try {
                let fileResult = await this.requestFile(mdPath);
                let rawStr = fileResult.data;
                let commaIdx = rawStr.indexOf(',');
                if (commaIdx >= 0 && commaIdx < 100) rawStr = rawStr.substring(commaIdx + 1);
                let bytes = buffer.from(rawStr, 'base64');
                mdContent = bytes.toString('utf-8');
              } catch (mdErr) {
                this.log.error(TAG, `DocViewer fetch error: ${(mdErr as Error).message ?? ''}`);
              }
            }

            if (mdContent.length > 0) {
              this._pendingDocTitle = mdTitle;
              this._pendingDocContent = mdContent;
              this.dispatchA2UI('doc.open', mdTitle);
              result = '{"ok":true,"action":"doc_viewer"}';
            } else {
              result = '{"ok":false,"error":"no content available"}';
            }
            break;
          }

          this.dispatchA2UI('canvas.navigate', url);
          if (this._inlineCanvasController) {
            this._inlineCanvasController.loadUrl(url);
          }
          result = `{"ok":true,"url":${JSON.stringify(url)}}`;
          break;
        }
        case Command.CANVAS_EVAL: {
          // Inline canvas: eval JS in inline WebView
          let js = '';
          if (paramsJson) {
            try {
              let p = JSON.parse(paramsJson) as Record<string, string>;
              if (p['javaScript'] !== undefined) js = p['javaScript'];
              if (p['javascript'] !== undefined) js = p['javascript'];
              if (p['js'] !== undefined) js = p['js'];
            } catch { /* ignore */ }
          }
          this.log.info(TAG, `canvas.eval inline: js=${js.substring(0, 200)}`);
          if (this._inlineCanvasController && js.length > 0) {
            let evalResult: string = await this._inlineCanvasController.runJavaScript(js);
            result = `{"ok":true,"result":${JSON.stringify(evalResult)}}`;
          } else {
            result = '{"ok":false,"error":"No inline canvas controller"}';
          }
          break;
        }
        case Command.CANVAS_SNAPSHOT: {
          // Inline canvas: snapshot from inline WebView
          this.log.info(TAG, 'canvas.snapshot inline');
          let quality: number = 80;
          if (paramsJson) {
            try {
              let p = JSON.parse(paramsJson) as Record<string, Object>;
              if (p['quality'] !== undefined) {
                let q: number = p['quality'] as number;
                quality = q <= 1 ? Math.round(q * 100) : Math.round(q);
              }
            } catch { /* ignore */ }
          }
          try {
            let pixelMap: image.PixelMap = await componentSnapshot.get('inlineCanvasWebView');
            let imageInfo: image.ImageInfo = await pixelMap.getImageInfo();
            let width: number = imageInfo.size.width;
            let height: number = imageInfo.size.height;
            let packer: image.ImagePacker = image.createImagePacker();
            let packOpts: image.PackingOption = { format: 'image/jpeg', quality: quality };
            let jpegData: ArrayBuffer = await packer.packing(pixelMap, packOpts);
            packer.release();
            pixelMap.release();
            let base64Str: string = buffer.from(jpegData).toString('base64');
            this.log.info(TAG, `snapshot inline: ${jpegData.byteLength} bytes, base64=${base64Str.length}`);
            result = `{"format":"jpg","base64":${JSON.stringify(base64Str)},"width":${width},"height":${height}}`;
          } catch (e) {
            this.log.warn(TAG, `snapshot inline failed: ${(e as Error).message}`);
            result = '{"ok":false,"error":"Snapshot failed"}';
          }
          break;
        }
        case Command.CANVAS_HIDE: {
          // Inline canvas: dispatch hide event
          this.log.info(TAG, 'canvas.hide inline');
          this.dispatchA2UI('canvas.hide', '');
          this._inlineCanvasController = undefined;
          result = '{"ok":true,"action":"hidden_inline"}';
          break;
        }
        case Command.CANVAS_A2UI_PUSH:
        case Command.CANVAS_A2UI_PUSH_JSONL: {
          // Dispatch A2UI content inline to chat (not full-screen CanvasPage)
          let a2uiContent = this.extractA2UIContent(paramsJson);
          this.log.info(TAG, `A2UI push inline: ${a2uiContent.length} chars`);
          this.dispatchA2UI('push', a2uiContent);
          result = '{"ok":true}';
          break;
        }
        case Command.CANVAS_A2UI_RESET: {
          this.log.info(TAG, 'A2UI reset inline');
          this.dispatchA2UI('reset', '');
          result = '{"ok":true}';
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
        case Command.CONTEXT_TEST: {
          this.log.info(TAG, 'Executing context.test...');
          result = await this.handleContextTest(paramsJson);
          break;
        }
        case Command.CONTEXT_SIMULATE: {
          this.log.info(TAG, 'Executing context.simulate...');
          result = await this.handleContextSimulate(paramsJson);
          break;
        }
        case Command.CONTEXT_ADD_RULE: {
          this.log.info(TAG, 'Executing context.addRule...');
          result = await this.handleContextAddRule(paramsJson);
          break;
        }
        case Command.CONTEXT_REMOVE_RULE: {
          this.log.info(TAG, 'Executing context.removeRule...');
          result = await this.handleContextRemoveRule(paramsJson);
          break;
        }
        case Command.CONTEXT_LIST_RULES: {
          this.log.info(TAG, 'Executing context.listRules...');
          result = await this.handleContextListRules();
          break;
        }
        case Command.CONTEXT_FEDERATED_SYNC: {
          this.log.info(TAG, 'Executing context.federatedSync...');
          result = await this.handleContextFederatedSync(paramsJson);
          break;
        }
        // ---- UI automation ----
        case Command.UI_SCREENSHOT: {
          this.log.info(TAG, 'Executing ui.screenshot...');
          result = await this.handleUiScreenshot(paramsJson);
          break;
        }
        case Command.UI_NAVIGATE: {
          this.log.info(TAG, 'Executing ui.navigate...');
          result = await this.handleUiNavigate(paramsJson);
          break;
        }
        case Command.UI_BACK: {
          this.log.info(TAG, 'Executing ui.back...');
          result = await this.handleUiBack();
          break;
        }
        case Command.UI_GET_STATE: {
          this.log.info(TAG, 'Executing ui.get_state...');
          result = await this.handleUiGetState();
          break;
        }
        case Command.UI_TAP: {
          this.log.info(TAG, 'Executing ui.tap...');
          result = await this.handleUiTap(paramsJson);
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

  /** Extract JSONL content from A2UI push params. */
  /**
   * Handle context.test invoke: accept a test scenario, evaluate through C++ engine,
   * return matched rules and scores.
   *
   * Params JSON format:
   * {
   *   "scenario": "string — description for logging",
   *   "snapshot": { ContextSnapshot fields },
   *   "maxResults": number (optional, default 5),
   *   "loadDefaultRules": boolean (optional — reload built-in rules before eval),
   *   "geofences": [{ id, category }] (optional — rebind geofence placeholders)
   * }
   *
   * Returns:
   * {
   *   "scenario": "...",
   *   "ruleCount": N,
   *   "matches": [ { ruleId, confidence, action: { id, type, payload } } ],
   *   "snapshot": { ... the snapshot that was evaluated }
   * }
   */
  private async handleContextTest(paramsJson: string | undefined): Promise<string> {
    if (!paramsJson || paramsJson.length === 0) {
      return '{"error":"missing params"}';
    }

    try {
      let params = JSON.parse(paramsJson) as Record<string, Object>;
      let scenario = (params['scenario'] as string) ?? 'unnamed';
      let maxResults = (params['maxResults'] as number) ?? 5;

      let engine = ContextEngineService.getInstance();

      // Ensure engine is initialized
      if (this._context) {
        await engine.init(this._context);
      }

      // Optionally reload default rules
      if (params['loadDefaultRules'] === true) {
        await engine.loadDefaultRules();
        this.log.info(TAG, `context.test: reloaded default rules, count=${engine.getRuleCount()}`);
      }

      // Optionally rebind geofences
      if (params['geofences'] !== undefined) {
        let geoArr = params['geofences'] as Array<Record<string, string>>;
        let bindings: GeofenceBinding[] = [];
        for (let i = 0; i < geoArr.length; i++) {
          let b: GeofenceBinding = { id: geoArr[i]['id'] ?? '', category: geoArr[i]['category'] ?? '' };
          bindings.push(b);
        }
        await engine.rebindGeofences(bindings);
        this.log.info(TAG, `context.test: rebound ${bindings.length} geofences`);
      }

      // Build snapshot from params
      let snapObj = params['snapshot'] as Record<string, string>;
      let snapshot: ContextSnapshot = {
        timeOfDay: snapObj['timeOfDay'] ?? 'morning',
        hour: snapObj['hour'] ?? '9',
        dayOfWeek: snapObj['dayOfWeek'] ?? '1',
        isWeekend: snapObj['isWeekend'] ?? 'false',
        motionState: snapObj['motionState'] ?? 'stationary',
        batteryLevel: snapObj['batteryLevel'] ?? '80',
        isCharging: snapObj['isCharging'] ?? 'false',
        networkType: snapObj['networkType'] ?? 'wifi',
        geofence: snapObj['geofence'],
        latitude: snapObj['latitude'],
        longitude: snapObj['longitude'],
        stepCount: snapObj['stepCount'],
      };

      // Evaluate
      let matches: MatchResult[] = engine.evaluate(snapshot, maxResults);

      this.log.info(TAG, `context.test [${scenario}]: ${matches.length} matches from ${engine.getRuleCount()} rules`);

      let resultObj: Record<string, Object> = {
        'scenario': scenario as Object,
        'ruleCount': engine.getRuleCount() as Object,
        'matches': matches as Object,
        'snapshot': snapshot as Object,
      };

      return JSON.stringify(resultObj);
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown error';
      this.log.error(TAG, `context.test error: ${msg}`);
      return `{"error":${JSON.stringify(msg)}}`;
    }
  }

  /**
   * Handle context.simulate invoke: run the full UI delivery pipeline
   * (cooldown check, notifyRecommendation, system notification) and return results.
   *
   * Params JSON format: same as context.test
   * Returns: { scenario, ruleCount, matches, delivered, snapshot }
   */
  private async handleContextSimulate(paramsJson: string | undefined): Promise<string> {
    if (!paramsJson || paramsJson.length === 0) {
      return '{"error":"missing params"}';
    }

    try {
      let cas = ContextAwarenessService.getInstance();
      if (!cas.isActive()) {
        return '{"error":"情景智能服务未启动，请先启动 Context Awareness Service"}';
      }

      let params = JSON.parse(paramsJson) as Record<string, Object>;
      let scenario = (params['scenario'] as string) ?? 'unnamed';
      let maxResults = (params['maxResults'] as number) ?? 5;

      let engine = ContextEngineService.getInstance();

      // Ensure engine is initialized
      if (this._context) {
        await engine.init(this._context);
      }

      // Optionally reload default rules
      if (params['loadDefaultRules'] === true) {
        await engine.loadDefaultRules();
        this.log.info(TAG, `context.simulate: reloaded default rules, count=${engine.getRuleCount()}`);
      }

      // Optionally rebind geofences
      if (params['geofences'] !== undefined) {
        let geoArr = params['geofences'] as Array<Record<string, string>>;
        let bindings: GeofenceBinding[] = [];
        for (let i = 0; i < geoArr.length; i++) {
          let b: GeofenceBinding = { id: geoArr[i]['id'] ?? '', category: geoArr[i]['category'] ?? '' };
          bindings.push(b);
        }
        await engine.rebindGeofences(bindings);
        this.log.info(TAG, `context.simulate: rebound ${bindings.length} geofences`);
      }

      // Build snapshot from params
      let snapObj = params['snapshot'] as Record<string, string>;
      let snapshot: ContextSnapshot = {
        timeOfDay: snapObj['timeOfDay'] ?? 'morning',
        hour: snapObj['hour'] ?? '9',
        dayOfWeek: snapObj['dayOfWeek'] ?? '1',
        isWeekend: snapObj['isWeekend'] ?? 'false',
        motionState: snapObj['motionState'] ?? 'stationary',
        batteryLevel: snapObj['batteryLevel'] ?? '80',
        isCharging: snapObj['isCharging'] ?? 'false',
        networkType: snapObj['networkType'] ?? 'wifi',
        geofence: snapObj['geofence'],
        latitude: snapObj['latitude'],
        longitude: snapObj['longitude'],
        stepCount: snapObj['stepCount'],
      };

      // Run full pipeline: evaluateAndDeliver (cooldown, notifyRecommendation, system notification)
      let matches: MatchResult[] = await cas.simulateContext(snapshot);
      let delivered = matches.length > 0;

      this.log.info(TAG, `context.simulate [${scenario}]: ${matches.length} matches, delivered=${delivered}`);

      let resultObj: Record<string, Object> = {
        'scenario': scenario as Object,
        'ruleCount': engine.getRuleCount() as Object,
        'matches': matches as Object,
        'delivered': delivered as Object,
        'snapshot': snapshot as Object,
      };

      return JSON.stringify(resultObj);
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown error';
      this.log.error(TAG, `context.simulate error: ${msg}`);
      return `{"error":${JSON.stringify(msg)}}`;
    }
  }

  /**
   * Handle context.addRule: dynamically add a rule to the C++ engine and persist it.
   * Params: { rule: ContextRule } or directly a ContextRule object
   * The rule id should start with 'user_' for user-created rules.
   */
  private async handleContextAddRule(paramsJson: string | undefined): Promise<string> {
    if (!paramsJson || paramsJson.length === 0) {
      return '{"error":"missing params"}';
    }
    try {
      let params = JSON.parse(paramsJson) as Record<string, Object>;
      let ruleObj = (params['rule'] ?? params) as Record<string, Object>;

      // Ensure the rule has an id starting with 'user_'
      let ruleId = ruleObj['id'] as string;
      if (!ruleId || ruleId.length === 0) {
        ruleId = `user_${Date.now()}`;
        ruleObj['id'] = ruleId as Object;
      }
      if (!ruleId.startsWith('user_')) {
        ruleId = `user_${ruleId}`;
        ruleObj['id'] = ruleId as Object;
      }

      let engine = ContextEngineService.getInstance();
      if (this._context) {
        await engine.init(this._context);
      }

      let rule: ContextRule = {
        id: ruleObj['id'] as string,
        name: (ruleObj['name'] as string) ?? ruleId,
        conditions: ruleObj['conditions'] as ContextCondition[],
        excludeConditions: ruleObj['excludeConditions'] as ContextCondition[][] | undefined,
        action: ruleObj['action'] as ContextAction,
        priority: (ruleObj['priority'] as number) ?? 1.0,
        cooldownMs: (ruleObj['cooldownMs'] as number) ?? 3600000,
        enabled: (ruleObj['enabled'] as boolean) ?? true,
      };

      let ok = await engine.addRule(rule);
      this.log.info(TAG, `context.addRule: id=${rule.id}, name=${rule.name}, ok=${ok}`);

      return JSON.stringify({
        'ok': ok,
        'ruleId': rule.id,
        'ruleCount': engine.getRuleCount()
      });
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown error';
      this.log.error(TAG, `context.addRule error: ${msg}`);
      return `{"error":${JSON.stringify(msg)}}`;
    }
  }

  /**
   * Handle context.removeRule: remove a user rule by id.
   * Params: { ruleId: string }
   */
  private async handleContextRemoveRule(paramsJson: string | undefined): Promise<string> {
    if (!paramsJson || paramsJson.length === 0) {
      return '{"error":"missing params"}';
    }
    try {
      let params = JSON.parse(paramsJson) as Record<string, Object>;
      let ruleId = params['ruleId'] as string;
      if (!ruleId || ruleId.length === 0) {
        return '{"error":"missing ruleId"}';
      }

      let engine = ContextEngineService.getInstance();
      let ok = await engine.removeRule(ruleId);
      this.log.info(TAG, `context.removeRule: id=${ruleId}, ok=${ok}`);

      return JSON.stringify({
        'ok': ok,
        'ruleId': ruleId,
        'ruleCount': engine.getRuleCount()
      });
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown error';
      this.log.error(TAG, `context.removeRule error: ${msg}`);
      return `{"error":${JSON.stringify(msg)}}`;
    }
  }

  /**
   * Handle context.listRules: export all current rules from the C++ engine.
   */
  private async handleContextListRules(): Promise<string> {
    try {
      let engine = ContextEngineService.getInstance();
      let rulesJson = engine.exportRules();
      let rules: Object[] = JSON.parse(rulesJson) as Object[];
      return JSON.stringify({
        'ruleCount': rules.length,
        'rules': rules
      });
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown error';
      this.log.error(TAG, `context.listRules error: ${msg}`);
      return `{"error":${JSON.stringify(msg)}}`;
    }
  }

  /**
   * Handle context.federatedSync: trigger or query federated learning sync.
   * params: { action: 'sync' | 'stats' | 'enable' | 'disable' }
   */
  private async handleContextFederatedSync(paramsJson: string | undefined): Promise<string> {
    try {
      let fedSync = FederatedSync.getInstance();
      let action = 'stats';
      if (paramsJson && paramsJson.length > 0) {
        let params = JSON.parse(paramsJson) as Record<string, Object>;
        action = (params['action'] as string) || 'stats';
      }

      switch (action) {
        case 'sync': {
          let ok = await fedSync.forceSync();
          return JSON.stringify({ 'ok': ok, 'stats': fedSync.getStats() });
        }
        case 'enable': {
          fedSync.setEnabled(true);
          return JSON.stringify({ 'ok': true, 'enabled': true });
        }
        case 'disable': {
          fedSync.setEnabled(false);
          return JSON.stringify({ 'ok': true, 'enabled': false });
        }
        case 'stats':
        default:
          return JSON.stringify(fedSync.getStats());
      }
    } catch (err) {
      let msg = (err as Error).message ?? 'unknown error';
      this.log.error(TAG, `context.federatedSync error: ${msg}`);
      return `{"error":${JSON.stringify(msg)}}`;
    }
  }

  // ---- UI automation handlers ----

  private async handleUiScreenshot(paramsJson: string | undefined): Promise<string> {
    let quality: number = 75;
    if (paramsJson) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['quality'] !== undefined) {
          let q: number = p['quality'] as number;
          quality = q <= 1 ? Math.round(q * 100) : Math.round(q);
        }
      } catch { /* ignore */ }
    }

    let pixelMap: image.PixelMap | undefined = undefined;

    // Try window.snapshot() using UIAbilityContext
    if (this._context) {
      try {
        let win: window.Window = await window.getLastWindow(this._context);
        pixelMap = await win.snapshot();
        this.log.info(TAG, 'ui.screenshot: window.snapshot() succeeded');
      } catch (err) {
        this.log.warn(TAG, `ui.screenshot window.snapshot() failed: ${(err as Error).message ?? String(err)}`);
      }
    }

    // Fallback: componentSnapshot on appRoot
    if (!pixelMap) {
      try {
        pixelMap = await componentSnapshot.get('appRoot');
        this.log.info(TAG, 'ui.screenshot: componentSnapshot(appRoot) succeeded');
      } catch (err) {
        this.log.warn(TAG, `ui.screenshot componentSnapshot failed: ${(err as Error).message ?? String(err)}`);
      }
    }

    if (!pixelMap) {
      return '{"ok":false,"error":"All screenshot methods failed"}';
    }

    let info: image.ImageInfo = await pixelMap.getImageInfo();
    let width: number = info.size.width;
    let height: number = info.size.height;

    let packer: image.ImagePacker = image.createImagePacker();
    let packOpts: image.PackingOption = { format: 'image/jpeg', quality: quality };
    let jpegData: ArrayBuffer = await packer.packing(pixelMap, packOpts);
    packer.release();
    pixelMap.release();

    let base64Str: string = buffer.from(jpegData).toString('base64');
    this.log.info(TAG, `ui.screenshot: ${width}x${height}, ${jpegData.byteLength} bytes`);

    return `{"width":${width},"height":${height},"format":"jpeg","data":${JSON.stringify(base64Str)}}`;
  }

  private async handleUiNavigate(paramsJson: string | undefined): Promise<string> {
    let page: string = '';
    if (paramsJson) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, string>;
        if (p['page'] !== undefined) page = p['page'];
      } catch { /* ignore */ }
    }
    if (page.length === 0) {
      return '{"ok":false,"error":"missing page parameter"}';
    }
    try {
      await router.pushUrl({ url: page });
      this.log.info(TAG, `ui.navigate: navigated to ${page}`);
      return `{"success":true,"page":${JSON.stringify(page)}}`;
    } catch (err) {
      let msg: string = (err as Error).message ?? 'navigation failed';
      this.log.error(TAG, `ui.navigate error: ${msg}`);
      return `{"success":false,"error":${JSON.stringify(msg)}}`;
    }
  }

  private async handleUiBack(): Promise<string> {
    try {
      router.back();
      this.log.info(TAG, 'ui.back: navigated back');
      return '{"success":true}';
    } catch (err) {
      let msg: string = (err as Error).message ?? 'back failed';
      this.log.error(TAG, `ui.back error: ${msg}`);
      return `{"success":false,"error":${JSON.stringify(msg)}}`;
    }
  }

  private async handleUiGetState(): Promise<string> {
    let currentPage: string = '';
    try {
      let state: router.RouterState = router.getState();
      currentPage = state.path + state.name;
    } catch { /* ignore */ }

    let isConnected: boolean = this.connectionState === ConnectionState.Connected;

    return `{"currentPage":${JSON.stringify(currentPage)},"isConnected":${isConnected},"version":"${APP_VERSION}"}`;
  }

  private async handleUiTap(paramsJson: string | undefined): Promise<string> {
    // ui.tap attempts to simulate touch events at specified coordinates.
    // Approach: Try shell 'input tap' via ExecCapability, fall back to external execution.
    let x: number = 0;
    let y: number = 0;
    let external: boolean = false;  // if true, return instruction for external execution
    
    if (paramsJson) {
      try {
        let p = JSON.parse(paramsJson) as Record<string, Object>;
        if (p['x'] !== undefined) x = p['x'] as number;
        if (p['y'] !== undefined) y = p['y'] as number;
        if (p['external'] !== undefined) external = p['external'] as boolean;
      } catch { /* ignore */ }
    }
    
    if (x === 0 && y === 0) {
      return '{"ok":false,"error":"Missing coordinates. Provide x and y.","hint":"Use ui.screenshot to get dimensions first"}';
    }
    
    // If external mode requested, return instruction for external execution via MSI
    if (external) {
      let cmd = 'hdc shell input tap ' + x + ' ' + y;
      return '{"ok":true,"mode":"external","message":"Execute on MSI: ' + cmd + '","command":"' + cmd + '","x":' + x + ',"y":' + y + '}';
    }
    
    // Try local execution via shell
    this.log.info(TAG, 'ui.tap: attempting local tap at (' + x + ', ' + y + ')');
    try {
      let execResult = await this.execCapability.execute('{"command":"input tap ' + x + ' ' + y + '","timeoutMs":5000}');
      let result = JSON.parse(execResult) as Record<string, Object>;
      if (result['ok'] === true && result['exitCode'] === 0) {
        this.log.info(TAG, 'ui.tap: success at (' + x + ', ' + y + ')');
        return '{"ok":true,"x":' + x + ',"y":' + y + ',"method":"shell"}';
      } else {
        // Local execution failed, suggest external
        let stderr = (result['stderr'] as string) ?? '';
        this.log.warn(TAG, 'ui.tap local failed: ' + stderr);
        let cmd = 'hdc shell input tap ' + x + ' ' + y;
        return '{"ok":false,"error":"Local tap failed: ' + stderr.replace(/"/g, "'") + '","hint":"Try external mode: ui.tap with {x, y, external: true}","fallback_command":"' + cmd + '","x":' + x + ',"y":' + y + '}';
      }
    } catch (err) {
      let msg = (err as Error).message ?? String(err);
      this.log.error(TAG, 'ui.tap exception: ' + msg);
      let cmd = 'hdc shell input tap ' + x + ' ' + y;
      return '{"ok":false,"error":"Exception: ' + msg.replace(/"/g, "'") + '","hint":"Try external mode: ui.tap with {x, y, external: true}","fallback_command":"' + cmd + '","x":' + x + ',"y":' + y + '}';
    }
  }

  /**
   * Build A2UI JSONL for a context recommendation card using simplified format.
   * Shows: rule name, recommendation, confidence, and feedback buttons.
   */
  private buildContextRecommendationA2UI(ruleId: string, ruleName: string, reason: string, confidence: number): string {
    // Escape strings for JSON embedding
    let safeReason = reason.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    let safeRuleId = ruleId.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    let safeRuleName = ruleName.replace(/\\/g, '\\\\').replace(/"/g, '\\"');

    // Get localized strings
    let titleText = I18n.t('context.notification.recommendation');
    let confidenceText = I18n.t('context.confidence');
    let usefulText = I18n.t('context.feedback.useful');
    let inaccurateText = I18n.t('context.feedback.inaccurate');
    let dismissText = I18n.t('context.feedback.dismiss');
    let detailsText = I18n.t('context.feedback.viewDetails');

    // Stream RL learning label
    let rlLabel = this.getStreamRLLabel(ruleId);
    let rlBadge = rlLabel.length > 0 ? `  |  🧠 ${rlLabel}` : '';

    // Use simplified A2UI format: {"type":"form","children":[...]}
    let jsonl = `{"type":"form","id":"ctx_rec_${Date.now()}","children":[` +
      `{"type":"text","text":"💡 ${titleText}","style":{"fontSize":20,"fontWeight":"bold"}},` +
      `{"type":"text","text":"${safeReason}","style":{"fontSize":15}},` +
      `{"type":"text","text":"📋 ${safeRuleName}  |  ${confidenceText}: ${confidence}%${rlBadge}","style":{"fontSize":12,"color":"#888"}},` +
      `{"type":"button","text":"✅ ${usefulText}","variant":"primary","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","ruleName":"${safeRuleName}","feedback":"accept"}}}},` +
      `{"type":"button","text":"❌ ${inaccurateText}","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","ruleName":"${safeRuleName}","feedback":"reject"}}}},` +
      `{"type":"button","text":"🙈 ${dismissText}","variant":"borderless","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","ruleName":"${safeRuleName}","feedback":"dismiss"}}}},` +
      `{"type":"button","text":"🔍 ${detailsText}","variant":"borderless","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","feedback":"view_snapshot"}}}}` +
      `]}`;

    return jsonl;
  }

  /**
   * Build A2UI card for explore mode: shows detected state + suggestion with action buttons.
   */
  private buildExploreStateA2UI(ruleId: string, ruleName: string, reason: string, confidence: number, stateInfo: string): string {
    let safeReason = reason.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    let safeRuleId = ruleId.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    let safeRuleName = ruleName.replace(/\\/g, '\\\\').replace(/"/g, '\\"');
    let safeState = stateInfo.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n');

    let usefulText = I18n.t('context.feedback.useful');
    let inaccurateText = I18n.t('context.feedback.inaccurate');
    let dismissText = I18n.t('context.feedback.dismiss');
    let detailsText = I18n.t('context.feedback.viewDetails');
    let confidenceText = I18n.t('context.confidence');

    // Stream RL learning label
    let rlLabel = this.getStreamRLLabel(ruleId);
    let rlBadge = rlLabel.length > 0 ? `  |  🧠 ${rlLabel}` : '';

    let jsonl = `{"type":"form","id":"ctx_explore_${Date.now()}","children":[` +
      `{"type":"text","text":"🔍 探索模式 — 状态检测","style":{"fontSize":18,"fontWeight":"bold"}},` +
      `{"type":"text","text":"${safeState}","style":{"fontSize":14}},` +
      `{"type":"text","text":"─────────────────","style":{"fontSize":12,"color":"#ccc"}},` +
      `{"type":"text","text":"💡 建议","style":{"fontSize":16,"fontWeight":"bold"}},` +
      `{"type":"text","text":"${safeReason}","style":{"fontSize":15}},` +
      `{"type":"text","text":"📋 ${safeRuleName}  |  ${confidenceText}: ${confidence}%${rlBadge}","style":{"fontSize":12,"color":"#888"}},` +
      `{"type":"button","text":"✅ ${usefulText}","variant":"primary","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","ruleName":"${safeRuleName}","feedback":"accept"}}}},` +
      `{"type":"button","text":"❌ ${inaccurateText}","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","ruleName":"${safeRuleName}","feedback":"reject"}}}},` +
      `{"type":"button","text":"🙈 ${dismissText}","variant":"borderless","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","ruleName":"${safeRuleName}","feedback":"dismiss"}}}},` +
      `{"type":"button","text":"🔍 ${detailsText}","variant":"borderless","action":{"event":{"name":"context_feedback","context":{"ruleId":"${safeRuleId}","feedback":"view_snapshot"}}}}` +
      `]}`;

    return jsonl;
  }

  /** Get RL learning label for a rule/arm: 探索中 / 学习中 / 已学习 */
  private getStreamRLLabel(ruleId: string): string {
    try {
      let engine = ContextEngineService.getInstance();
      let armSamples = engine.getStreamRLArmSamples(ruleId);
      if (armSamples < 5) {
        return '探索中';
      } else if (armSamples < 20) {
        return `学习中 (${armSamples}次)`;
      } else {
        return `已学习 (${armSamples}次)`;
      }
    } catch {
      return '';
    }
  }

  /**
   * Fallback: build explore state info directly from DigitalWorldService
   * Used when rec.exploreStateInfo is not available (ArkTS optional field issue)
   */
  private buildExploreStateFromDigital(cas: ContextAwarenessService): string {
    let digitalService = cas.getDigitalWorldService();
    let d = digitalService.getDigitalData();
    let lines: string[] = [];

    // 时间
    let now = new Date();
    let dayNames: string[] = ['日', '一', '二', '三', '四', '五', '六'];
    let h = now.getHours();
    let m = now.getMinutes();
    let todMap: Record<string, string> = {
      'dawn': '黎明', 'morning': '上午', 'afternoon': '下午',
      'evening': '傍晚', 'night': '深夜'
    };
    let tod = d['time_of_day'] ?? '';
    let todLabel = todMap[tod] ?? tod;
    let weekend = now.getDay() === 0 || now.getDay() === 6;
    lines.push(`⏰ ${todLabel} ${h}:${m < 10 ? '0' + m : m} 周${dayNames[now.getDay()]}${weekend ? '（周末）' : ''}`);

    // 运动状态
    let motion = d['motion_state'] ?? d['motionState'] ?? '';
    if (motion.length > 0) {
      let motionMap: Record<string, string> = {
        'stationary': '静止', 'walking': '步行', 'running': '跑步',
        'driving': '驾车', 'transit': '乘车', 'cycling': '骑行'
      };
      lines.push(`🏃 ${motionMap[motion] ?? motion}`);
    }

    // 位置
    let geofence = d['geofence'] ?? '';
    if (geofence.length > 0) {
      lines.push(`📍 ${geofence}`);
    }
    let wifiSsid = d['wifi_ssid'] ?? d['ssid'] ?? '';
    if (wifiSsid.length > 0) {
      lines.push(`📶 WiFi: ${wifiSsid}`);
    }

    // 蓝牙
    let btDevices = d['bt_device_names'] ?? d['connected_devices'] ?? '';
    if (btDevices.length > 0) {
      lines.push(`🔵 蓝牙: ${btDevices}`);
    }
    let btInVehicle = d['bt_in_vehicle'] ?? '';
    if (btInVehicle === 'true') {
      lines.push(`🚗 车载蓝牙已连接`);
    }

    // 心率
    let heartRate = d['heart_rate'] ?? '';
    if (heartRate.length > 0 && heartRate !== '0') {
      let hrStatus = d['heart_rate_status'] ?? '';
      let hrMap: Record<string, string> = {
        'resting': '休息', 'active': '活跃', 'exercise': '运动'
      };
      lines.push(`❤️ 心率: ${heartRate} bpm${hrMap[hrStatus] ? ' (' + hrMap[hrStatus] + ')' : ''}`);
    }

    // 步数
    let steps = d['step_count_today'] ?? '';
    if (steps.length > 0 && steps !== '0') {
      lines.push(`🚶 今日 ${steps} 步`);
    }

    // 电量
    let battery = d['battery_level'] ?? '';
    if (battery.length > 0) {
      let charging = d['is_charging'] ?? '';
      lines.push(`🔋 ${battery}%${charging === 'true' ? ' 充电中' : ''}`);
    }

    return lines.join('\n');
  }

  private extractA2UIContent(paramsJson: string | undefined): string {
    if (!paramsJson || paramsJson.length === 0) return '';
    try {
      let p = JSON.parse(paramsJson) as Record<string, Object>;
      if (p['lines'] !== undefined) return p['lines'] as string;
      if (p['content'] !== undefined) return p['content'] as string;
      if (p['jsonl'] !== undefined) return p['jsonl'] as string;
      return paramsJson;
    } catch {
      return paramsJson;
    }
  }

  private handleOperatorEvent(event: string, payloadJson: string | undefined): void {
    this.log.debug(TAG, `operator event: "${event}" payloadLen=${payloadJson ? payloadJson.length : 0} payload(500)=${payloadJson ? payloadJson.substring(0, 500) : '(none)'}`);

    if (!payloadJson) return;

    // Handle experience_update from gateway (server learned something new)
    if (event === 'experience_update') {
      this.handleExperienceUpdate(payloadJson);
      return;
    }

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
        this.log.debug(TAG, `agent event keys: [${rawKeys.join(',')}] payload(300): ${payloadJson.substring(0, 300)}`);

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
                  if (fullText.length > 0) {
                    fullText += '\n\n';
                  }
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
                if (fullText.length > 0) {
                  fullText += '\n\n';
                }
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

        // Extract token usage from response (usually present in final event)
        let usage: GatewayTokenUsage | undefined = undefined;
        if (raw['usage'] !== undefined) {
          let usageRaw = raw['usage'] as Record<string, number>;
          let inputToks = usageRaw['input_tokens'] ?? usageRaw['inputTokens'] ?? usageRaw['prompt_tokens'] ?? 0;
          let outputToks = usageRaw['output_tokens'] ?? usageRaw['outputTokens'] ?? usageRaw['completion_tokens'] ?? 0;
          let totalToks = usageRaw['total_tokens'] ?? usageRaw['totalTokens'] ?? (inputToks + outputToks);
          usage = {
            inputTokens: inputToks,
            outputTokens: outputToks,
            totalTokens: totalToks
          };
          this.log.debug(TAG, `Token usage: input=${inputToks} output=${outputToks} total=${totalToks}`);
        }

        let chatEvent: GatewayChatEvent = {
          runId: runId,
          sessionKey: sessionKey,
          seq: seq,
          state: chatState,
          message: { role: msgRole, content: blocks, timestamp: msgTs },
          errorMessage: errorMsg,
          stopReason: stopReason.length > 0 ? stopReason : undefined,
          usage: usage,
        };

        this.log.info(TAG, `agentChat: state=${chatState} runId=${runId} seq=${seq} textLen=${fullText.length} blocks=${blocks.length} text(100)="${fullText.substring(0, 100)}"`);

        // Check for experience pull response in chat messages.
        // Use data.text (accumulated) instead of fullText (delta) to see full content.
        if (dataObj !== undefined && dataObj !== null && typeof dataObj !== 'string') {
          let accumulatedText = dataObj['text'] !== undefined ? String(dataObj['text']) : '';
          if (accumulatedText.length > 0) {
            let isExperiencePull = this.detectExperienceInChat(accumulatedText);
            this.detectExperiencePushConfirm(accumulatedText);
            if (isExperiencePull) {
              this.log.info(TAG, 'Suppressing experience pull response from chat display');
              return;
            }
          }
        }

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

        // Don't show experience sync messages in chat UI
        if (this._experienceSyncActive) {
          this.log.info(TAG, 'Suppressing experience sync message from chat display');
          return;
        }

        // Filter: only show harmony-originated runs in chat UI
        // For other channels (whatsapp, cron, etc.), show as notification on final message
        let isHarmonyRun = runId.length > 0 && this._harmonyRunIds.has(runId);
        let isHarmonySession = sessionKey.indexOf('harmony') >= 0;
        if (!isHarmonyRun && !isHarmonySession) {
          // Non-harmony session: show notification for final messages with content
          if (chatState === 'final' && fullText.length > 0) {
            let notifyTitle = 'Linda';
            if (sessionKey.indexOf('whatsapp') >= 0) {
              notifyTitle = 'Linda (WhatsApp)';
            } else if (sessionKey.indexOf('cron') >= 0 || sessionKey.indexOf('isolated') >= 0) {
              notifyTitle = 'Linda (定时任务)';
            } else if (sessionKey.indexOf('discord') >= 0) {
              notifyTitle = 'Linda (Discord)';
            }
            let notifyText = fullText.length > 200 ? fullText.substring(0, 200) + '...' : fullText;
            this.log.info(TAG, `Non-harmony final message → notification: session=${sessionKey} textLen=${fullText.length}`);
            NotificationHelper.getInstance().send(notifyTitle, notifyText).catch(() => {});
          } else {
            this.log.debug(TAG, `Skipping non-harmony agent event: runId=${runId} sessionKey=${sessionKey} state=${chatState}`);
          }
          return;
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
      scopes: ['operator.read', 'operator.write', 'operator.pairing', 'operator.approvals', 'operator.admin'],
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

    // Context engine test / simulate — always available
    commands.push(Command.CONTEXT_TEST);
    commands.push(Command.CONTEXT_SIMULATE);
    commands.push(Command.CONTEXT_ADD_RULE);
    commands.push(Command.CONTEXT_REMOVE_RULE);
    commands.push(Command.CONTEXT_LIST_RULES);
    commands.push(Command.CONTEXT_FEDERATED_SYNC);

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

  /**
   * One-click extract: fetch all workspace memory files from the server.
   * Pulls MEMORY.md, SOUL.md, USER.md, IDENTITY.md, and memory/*.md diary files.
   * Returns a map of filePath → content (text).
   */
  async fetchWorkspaceFiles(): Promise<Map<string, string>> {
    if (!this.operatorSession || this._operatorState !== ConnectionState.Connected) {
      throw new Error('Gateway not connected');
    }

    let result = new Map<string, string>();
    let filesToFetch: string[] = [
      'workspace/MEMORY.md',
      'workspace/SOUL.md',
      'workspace/USER.md',
      'workspace/IDENTITY.md',
      'workspace/AGENTS.md',
      'workspace/TOOLS.md',
      'workspace/HEARTBEAT.md',
    ];

    // Fetch known files
    for (let filePath of filesToFetch) {
      try {
        let fileResult = await this.requestFile(filePath);
        if (fileResult.data.length > 0) {
          let decoded = buffer.from(fileResult.data, 'base64').toString('utf-8');
          result.set(filePath, decoded);
          this.log.info(TAG, `fetchWorkspace: got ${filePath} (${decoded.length} chars)`);
        }
      } catch {
        this.log.info(TAG, `fetchWorkspace: ${filePath} not found (skipped)`);
      }
    }

    // Try to fetch memory diary files by listing directory
    // Use file.list RPC if available, otherwise try common date patterns
    try {
      let listJson = await this.operatorSession.request('file.list', '{"path":"workspace/memory"}', 10000);
      if (listJson.length > 0) {
        let listRes = JSON.parse(listJson) as Record<string, Object>;
        let files = listRes['files'] as string[] | undefined;
        if (files && Array.isArray(files)) {
          for (let fileName of files) {
            if (fileName.endsWith('.md')) {
              let diaryPath = `workspace/memory/${fileName}`;
              try {
                let fileResult = await this.requestFile(diaryPath);
                if (fileResult.data.length > 0) {
                  let decoded = buffer.from(fileResult.data, 'base64').toString('utf-8');
                  result.set(diaryPath, decoded);
                  this.log.info(TAG, `fetchWorkspace: got diary ${diaryPath} (${decoded.length} chars)`);
                }
              } catch {
                this.log.info(TAG, `fetchWorkspace: diary ${diaryPath} failed (skipped)`);
              }
            }
          }
        }
      }
    } catch {
      this.log.info(TAG, 'fetchWorkspace: file.list not available, trying recent dates');
      // Fallback: try last 30 days of diary files
      let now = Date.now();
      for (let dayOffset = 0; dayOffset < 30; dayOffset++) {
        let d = new Date(now - dayOffset * 86400000);
        let dateStr = `${d.getFullYear()}-${(d.getMonth()+1).toString().padStart(2,'0')}-${d.getDate().toString().padStart(2,'0')}`;
        let diaryPath = `workspace/memory/${dateStr}.md`;
        try {
          let fileResult = await this.requestFile(diaryPath);
          if (fileResult.data.length > 0) {
            let decoded = buffer.from(fileResult.data, 'base64').toString('utf-8');
            result.set(diaryPath, decoded);
          }
        } catch {
          // skip
        }
      }
    }

    this.log.info(TAG, `fetchWorkspace: total ${result.size} files fetched`);
    return result;
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

  // ---- Experience Pack sync ----

  /** Send the local experience pack and memories to the gateway after connecting.
   *  Uses agent.request so the AI agent processes and persists the data
   *  to workspace files (MEMORY.md, skills, etc.). */
  async syncExperiencePack(): Promise<void> {
    if (!this._context || !this.operatorSession) return;

    let storage = ExperienceStorage.getInstance();
    let memSvc = MemoryService.getInstance();

    // Collect experience pack
    let pack: ExperiencePack | null = null;
    try {
      pack = await storage.load(this._context);
    } catch (err) {
      this.log.warn(TAG, `Experience load failed: ${(err as Error).message ?? ''}`);
    }

    // Collect memory items
    let memItems: Record<string, string | number>[] = [];
    try {
      let items = await memSvc.loadAll(this._context);
      for (let item of items) {
        let entry: Record<string, string | number> = {
          'type': item.memType,
          'content': item.content,
          'importance': item.importance,
          'createdAt': item.createdAt,
        };
        memItems.push(entry);
      }
    } catch (err) {
      this.log.warn(TAG, `Memory load failed: ${(err as Error).message ?? ''}`);
    }

    if (!pack && memItems.length === 0) {
      this.log.info(TAG, 'No experience or memory to sync');
      return;
    }

    // Build a concise summary for the agent
    let parts: string[] = [];
    parts.push('[System: Experience sync from mobile device]');

    if (pack && pack.experiences.length > 0) {
      parts.push(`\nExperience Pack (${pack.experiences.length} experiences):`);
      parts.push('```json');
      parts.push(storage.exportForSharing());
      parts.push('```');
    }

    if (memItems.length > 0) {
      parts.push(`\nMemory Items (${memItems.length}):`);
      parts.push('```json');
      parts.push(JSON.stringify(memItems, null, 2));
      parts.push('```');
    }

    parts.push('\nPlease merge these into the workspace:');
    parts.push('- Skills → workspace skill files or TOOLS.md');
    parts.push('- Memories → MEMORY.md or memory/ files');
    parts.push('- Use append-only: do not overwrite existing content');
    parts.push('- Respond briefly confirming what was saved.');

    let message = parts.join('\n');

    try {
      let agentPayload = JSON.stringify({
        'message': message,
        'sessionKey': 'main',
        'deliver': false,
      });
      // node.event requires the node-role session (operator role is unauthorized)
      if (this.nodeSession) {
        await this.nodeSession.sendNodeEvent('agent.request', agentPayload);
      } else {
        this.log.warn(TAG, 'No node session available for experience sync');
        return;
      }
      await storage.markSynced(this._context);
      this.log.info(TAG, 'Experience pack sent to agent for processing');
    } catch (err) {
      this.log.warn(TAG, `Experience sync via agent.request failed: ${(err as Error).message ?? ''}`);
    }

    // Phase 2: Pull server experience back to phone
    await this.pullServerExperience();
  }

  /** Pull experience/memories from the server by asking the AI agent to read
   *  workspace files and return them in a structured format.
   *  The response arrives via chat events; detectExperienceInChat() parses it. */
  /** Public method: trigger a server experience pull and get notified on completion.
   *  Returns a Promise that resolves with [success, count] when the pull finishes. */
  pullServerExperienceWithCallback(): Promise<number[]> {
    return new Promise<number[]>((resolve) => {
      let resolved = false;
      // Register callback
      this._experiencePullCallbacks.push((success: boolean, count: number) => {
        if (!resolved) {
          resolved = true;
          resolve([success ? 1 : 0, count]);
        }
      });
      // Set a timeout in case no response arrives
      setTimeout(() => {
        if (!resolved) {
          resolved = true;
          this._experiencePullCallbacks = [];
          resolve([0, 0]);
        }
      }, 60000); // 60s timeout
      this.pullServerExperience();
    });
  }

  private async pullServerExperience(): Promise<void> {
    if (!this.nodeSession) return;
    this._experienceSyncActive = true;
    try {
      let pullMessage = '[System: Experience pull request from mobile device]\n\n'
        + 'Read these workspace files: MEMORY.md, TOOLS.md, USER.md, SOUL.md, IDENTITY.md.\n'
        + 'Also list and read skill files: `find ~/.openclaw/workspace/skills/ -name "SKILL.md"`\n\n'
        + 'IMPORTANT: Split large files into sections. For markdown files:\n'
        + '- Split by ## headings. Each section = one memory entry.\n'
        + '- Use source format: "FILENAME#SectionName" (e.g. "MEMORY.md#Mobile Sync")\n'
        + '- For bullet-list sections, each bullet can be a separate entry with source "FILENAME#Section:key"\n'
        + '- Small files (<20 lines) can stay as one entry.\n\n'
        + 'Return ONLY a JSON block in <!--EXPERIENCE_PULL_START--> / <!--EXPERIENCE_PULL_END--> markers:\n'
        + '<!--EXPERIENCE_PULL_START-->\n'
        + '{"skills":[{"name":"skill-name","description":"desc","instructions":"SKILL.md content","shareLevel":"public"}],'
        + '"memories":[{"type":"fact","content":"section content","source":"MEMORY.md#SectionName","importance":1.0}]}\n'
        + '<!--EXPERIENCE_PULL_END-->\n'
        + 'Replace placeholders with actual content. Omit missing files. No text outside markers.';

      let pullPayload = JSON.stringify({
        'message': pullMessage,
        'sessionKey': 'main',
        'deliver': false,
      });
      await this.nodeSession.sendNodeEvent('agent.request', pullPayload);
      this.log.info(TAG, 'Experience pull request sent');
    } catch (err) {
      this.log.warn(TAG, `Experience pull failed: ${(err as Error).message ?? ''}`);
    }
  }

  /** Detect experience data in chat messages (from pull response).
   *  Called from chat event handlers. */
  detectExperienceInChat(text: string): boolean {
    let startMarker = '<!--EXPERIENCE_PULL_START-->';
    let endMarker = '<!--EXPERIENCE_PULL_END-->';
    let startIdx = text.indexOf(startMarker);
    if (startIdx < 0) return false;
    let endIdx = text.indexOf(endMarker, startIdx);
    if (endIdx < 0) return false;

    let jsonStr = text.substring(startIdx + startMarker.length, endIdx).trim();
    this.log.info(TAG, `Detected experience pull response: ${jsonStr.length} chars`);

    try {
      let data = JSON.parse(jsonStr) as Record<string, Object>;
      let memCount = (data['memories'] as Object[])?.length ?? 0;
      let skillCount = (data['skills'] as Object[])?.length ?? 0;
      this.handleExperienceUpdate(JSON.stringify(data));
      this.log.info(TAG, `Experience pull data merged: ${memCount} memories, ${skillCount} skills`);
      this._experienceSyncActive = false;
      for (let cb of this._experiencePullCallbacks) {
        cb(true, memCount);
      }
      this._experiencePullCallbacks = [];
      return true;
    } catch (err) {
      this.log.error(TAG, `Failed to parse experience pull data: ${(err as Error).message ?? ''}`);
      this._experienceSyncActive = false;
      for (let cb of this._experiencePullCallbacks) {
        cb(false, 0);
      }
      this._experiencePullCallbacks = [];
      return true;  // Still suppress display even on parse error
    }
  }

  /** Handle experience_update events from the server (learning feedback).
   *  Also syncs new memory items to local MemoryService (append-only). */
  private async handleExperienceUpdate(payloadJson: string): Promise<void> {
    if (!this._context) return;
    try {
      let raw = JSON.parse(payloadJson) as Record<string, Object>;
      let ctx = this._context;

      // Merge experience pack (append-only)
      let storage = ExperienceStorage.getInstance();
      await storage.mergeUpdate(ctx, raw);

      // Also sync memory items to local MemoryService + Experience memory
      if (raw['memories'] && Array.isArray(raw['memories'])) {
        let memItems = raw['memories'] as Record<string, Object>[];
        let memSvc = MemoryService.getInstance();

        // Convert to Experience Memory format for mergeUpdate (key=source, value=content)
        let pack = await storage.ensureLoaded(ctx);
        let defaultExp = pack.experiences.find((e: Experience) => e.name === 'Server Workspace');
        if (!defaultExp) {
          defaultExp = {
            id: generateId(),
            name: 'Server Workspace',
            description: 'Workspace files synced from server',
            skills: [],
            memory: [],
            createdAt: Date.now(),
            updatedAt: Date.now(),
          };
          pack.experiences.push(defaultExp);
        }

        let existingKeys = new Map<string, Memory>();
        for (let m of defaultExp.memory) {
          existingKeys.set(m.key.toLowerCase(), m);
        }

        let added = 0;
        let updated = 0;
        for (let mem of memItems) {
          let content = String(mem['content'] ?? '');
          let source = String(mem['source'] ?? '');
          let memType = String(mem['type'] ?? mem['memType'] ?? 'fact');
          let importance = (mem['importance'] as number) ?? 0.5;

          // Sync to MemoryService (with dedup)
          if (content.length > 0) {
            await memSvc.addIfNew(ctx, memType, content, importance);
          }

          // Sync to Experience memory (by source key)
          if (source.length > 0 && content.length > 0) {
            let existing = existingKeys.get(source.toLowerCase());
            let remoteModified = (mem['lastModified'] as number) ?? Date.now();
            if (!existing) {
              let newMem: Memory = { key: source, value: content, shareLevel: 'private', lastModified: remoteModified, deletedAt: 0 };
              defaultExp.memory.push(newMem);
              existingKeys.set(source.toLowerCase(), newMem);
              added++;
            } else {
              let localModified = existing.lastModified ?? 0;
              if (existing.value !== content && remoteModified > localModified) {
                // Remote is newer — update
                existing.value = content;
                existing.lastModified = remoteModified;
                updated++;
              }
            }
          }
        }

        if (added > 0 || updated > 0) {
          defaultExp.updatedAt = Date.now();
          await storage.save(ctx, pack);
        }
        this.log.info(TAG, `Memory sync: ${memItems.length} items, +${added} new, ~${updated} updated`);
      }

      // Also sync skills into experience pack
      if (raw['skills'] && Array.isArray(raw['skills'])) {
        let newSkills = raw['skills'] as Record<string, Object>[];
        let pack = await storage.ensureLoaded(ctx);
        // Create or get a default experience to hold server skills
        let defaultExp = pack.experiences.find((e: Experience) => e.name === 'Server Skills');
        if (!defaultExp) {
          defaultExp = {
            id: generateId(),
            name: 'Server Skills',
            description: 'Skills synced from server',
            skills: [],
            memory: [],
            createdAt: Date.now(),
            updatedAt: Date.now(),
          };
          pack.experiences.push(defaultExp);
        }
        let existingNames = new Set<string>();
        for (let s of defaultExp.skills) { existingNames.add(s.name); }
        let addedSkills = 0;
        for (let sk of newSkills) {
          let name = String(sk['name'] ?? '');
          if (name.length > 0 && !existingNames.has(name)) {
            let skill: Skill = {
              name: name,
              description: String(sk['description'] ?? ''),
              instructions: String(sk['instructions'] ?? ''),
              shareLevel: (String(sk['shareLevel'] ?? 'public')) as ShareLevel,
            };
            defaultExp.skills.push(skill);
            existingNames.add(name);
            addedSkills++;
          }
        }
        if (addedSkills > 0) {
          defaultExp.updatedAt = Date.now();
          await storage.save(ctx, pack);
          this.log.info(TAG, `Skills synced: ${addedSkills} new skills added`);
        }
      }

      this.log.info(TAG, 'Experience update received and merged (append-only)');
    } catch (err) {
      this.log.error(TAG, `Failed to parse experience_update: ${(err as Error).message ?? ''}`);
    }
  }

  // ==================== Push: Phone → Server ====================

  private _experiencePushCallbacks: ((success: boolean) => void)[] = [];

  /** Push local memories to the server. Returns Promise<boolean> for UI. */
  pushMemoriesToServerWithCallback(): Promise<boolean> {
    return new Promise<boolean>((resolve) => {
      let resolved = false;
      this._experiencePushCallbacks.push((success: boolean) => {
        if (!resolved) {
          resolved = true;
          resolve(success);
        }
      });
      setTimeout(() => {
        if (!resolved) {
          resolved = true;
          this._experienceSyncActive = false;
          this._experiencePushCallbacks = [];
          resolve(false);
        }
      }, 90000); // 90s timeout (writing files takes longer)
      this.pushMemoriesToServer();
    });
  }

  private async pushMemoriesToServer(): Promise<void> {
    if (!this.nodeSession || !this._context) {
      for (let cb of this._experiencePushCallbacks) { cb(false); }
      this._experiencePushCallbacks = [];
      return;
    }
    this._experienceSyncActive = true;
    try {
      let ctx = this._context;
      let memSvc = MemoryService.getInstance();
      let storage = ExperienceStorage.getInstance();
      let allItems = await memSvc.loadAll(ctx);
      let pack = await storage.ensureLoaded(ctx);

      // Collect skills from experience pack
      let allSkills: Skill[] = [];
      for (let exp of pack.experiences) {
        for (let sk of exp.skills) {
          allSkills.push(sk);
        }
      }

      if (allItems.length === 0 && allSkills.length === 0) {
        this.log.info(TAG, 'Push: nothing to push');
        for (let cb of this._experiencePushCallbacks) { cb(true); }
        this._experiencePushCallbacks = [];
        return;
      }

      // Group memories by source file if available, otherwise into MEMORY.md
      let memoryLines: string[] = [];
      let toolsLines: string[] = [];
      let identityLines: string[] = [];
      let userLines: string[] = [];
      let soulLines: string[] = [];

      for (let item of allItems) {
        let content = item.content;
        if (content.startsWith('[TOOLS]') || content.startsWith('[TOOLS.md]')) {
          toolsLines.push(content);
        } else if (content.startsWith('[IDENTITY]') || content.startsWith('[IDENTITY.md]')) {
          identityLines.push(content);
        } else if (content.startsWith('[USER]') || content.startsWith('[USER.md]')) {
          userLines.push(content);
        } else if (content.startsWith('[SOUL]') || content.startsWith('[SOUL.md]')) {
          soulLines.push(content);
        } else {
          memoryLines.push('- ' + content);
        }
      }

      let pushMessage = '[System: Experience push from mobile device]\n\n'
        + 'The user\'s mobile device is pushing its local memories and skills to this server.\n'
        + 'Please APPEND the following content to the appropriate workspace files.\n'
        + 'Do NOT overwrite existing content — only append new information.\n'
        + 'If a section header like "## Mobile Sync" doesn\'t exist in MEMORY.md, create it.\n\n';

      if (memoryLines.length > 0) {
        pushMessage += '=== APPEND TO MEMORY.md (under "## Mobile Sync" section) ===\n'
          + memoryLines.join('\n') + '\n\n';
      }

      if (toolsLines.length > 0) {
        pushMessage += '=== APPEND TO TOOLS.md ===\n'
          + toolsLines.join('\n') + '\n\n';
      }

      if (identityLines.length > 0) {
        pushMessage += '=== FOR REFERENCE (IDENTITY.md content from another server) ===\n'
          + identityLines.join('\n') + '\n\n';
      }

      if (userLines.length > 0) {
        pushMessage += '=== FOR REFERENCE (USER.md content from another server) ===\n'
          + userLines.join('\n') + '\n\n';
      }

      if (soulLines.length > 0) {
        pushMessage += '=== FOR REFERENCE (SOUL.md content from another server) ===\n'
          + soulLines.join('\n') + '\n\n';
      }

      // Include skills
      if (allSkills.length > 0) {
        pushMessage += '=== SKILLS TO INSTALL ===\n'
          + 'For each skill below, create a skill directory under ~/.openclaw/workspace/skills/<name>/ '
          + 'and write the instructions as SKILL.md. Skip if the skill directory already exists.\n\n';
        for (let sk of allSkills) {
          pushMessage += `--- Skill: ${sk.name} ---\n`;
          pushMessage += `Description: ${sk.description}\n`;
          pushMessage += `SKILL.md content:\n\`\`\`\n${sk.instructions}\n\`\`\`\n\n`;
        }
      }

      pushMessage += 'After writing, respond with exactly: <!--EXPERIENCE_PUSH_OK-->';

      let pushPayload = JSON.stringify({
        'message': pushMessage,
        'sessionKey': 'main',
        'deliver': false,
      });
      await this.nodeSession.sendNodeEvent('agent.request', pushPayload);
      this.log.info(TAG, `Experience push sent: ${allItems.length} items, ${allSkills.length} skills`);
    } catch (err) {
      this.log.warn(TAG, `Experience push failed: ${(err as Error).message ?? ''}`);
      this._experienceSyncActive = false;
      for (let cb of this._experiencePushCallbacks) { cb(false); }
      this._experiencePushCallbacks = [];
    }
  }

  /** Detect push confirmation in chat stream */
  detectExperiencePushConfirm(text: string): void {
    if (text.indexOf('<!--EXPERIENCE_PUSH_OK-->') >= 0) {
      this.log.info(TAG, 'Experience push confirmed by server');
      this._experienceSyncActive = false;
      for (let cb of this._experiencePushCallbacks) { cb(true); }
      this._experiencePushCallbacks = [];
    }
  }
}
