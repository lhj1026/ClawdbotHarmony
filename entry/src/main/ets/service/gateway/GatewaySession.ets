/**
 * WebSocket-based RPC session to an OpenClaw Gateway.
 * Ported from Android GatewaySession.kt.
 *
 * Each session connects with a specific role ('operator' or 'node').
 * - operator: receives chat/config events
 * - node: receives node.invoke.request events to execute device capabilities
 *
 * Wire protocol (JSON):
 *   Request:  { type:"req", id, method, params? }
 *   Response: { type:"res", id, ok, payload?, error? }
 *   Event:    { type:"event", event, payload? }
 */
import { webSocket } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { Constants } from '../../common/Constants';
import { LogService } from '../../common/LogService';
import { GatewayProtocol } from './GatewayProtocol';
import {
  GatewayEndpoint,
  ConnectionState,
  ConnectOptions,
  InvokeRequest,
  InvokeResult,
  RpcFrame,
} from './GatewayModels';
import { DeviceIdentityStore } from './DeviceIdentityStore';
import { DeviceAuthStore } from './DeviceAuthStore';

const TAG = 'GW-Session';

interface PendingRpc {
  resolve: (payload: object | undefined) => void;
  reject: (err: Error) => void;
  timer: number;
}

export class GatewaySession {
  // --- configuration ---
  private options: ConnectOptions;
  private identityStore: DeviceIdentityStore;
  private authStore: DeviceAuthStore;
  private log: LogService = LogService.getInstance();
  private logTag: string;

  // --- WebSocket ---
  private ws: webSocket.WebSocket | undefined = undefined;
  private wsGeneration: number = 0;
  private endpoint: GatewayEndpoint | undefined = undefined;
  private token: string | undefined = undefined;
  private password: string | undefined = undefined;
  private context: common.UIAbilityContext | undefined = undefined;

  // --- RPC state ---
  private nextId: number = 1;
  private pending: Map<string, PendingRpc> = new Map();

  // --- connection state ---
  private _state: ConnectionState = ConnectionState.Disconnected;
  private reconnectAttempt: number = 0;
  private reconnectTimer: number = -1;
  private shouldReconnect: boolean = false;
  private closedHandled: boolean = false;
  private connectNonce: string | undefined = undefined;
  private connectNonceResolve: ((nonce: string | undefined) => void) | undefined = undefined;
  private pairingResolve: (() => void) | undefined = undefined;
  private connectResult: Record<string, Object> | undefined = undefined;

  // --- callbacks ---
  onStateChanged: (state: ConnectionState, message: string) => void = () => {};
  onInvokeRequest: ((req: InvokeRequest) => Promise<InvokeResult>) | undefined = undefined;
  onEvent: (event: string, payloadJson: string | undefined) => void = () => {};
  onPairingRequired: ((requestId: string) => void) | undefined = undefined;

  constructor(
    options: ConnectOptions,
    identityStore: DeviceIdentityStore,
    authStore: DeviceAuthStore,
  ) {
    this.options = options;
    this.identityStore = identityStore;
    this.authStore = authStore;
    this.logTag = `${TAG}:${options.role}`;
  }

  get state(): ConnectionState {
    return this._state;
  }

  getConnectResult(): Record<string, Object> | undefined {
    return this.connectResult;
  }

  connect(
    context: common.UIAbilityContext,
    endpoint: GatewayEndpoint,
    token?: string,
    password?: string,
  ): void {
    this.context = context;
    this.endpoint = endpoint;
    this.token = token?.trim();
    this.password = password?.trim();
    this.shouldReconnect = true;
    this.reconnectAttempt = 0;
    this.log.info(this.logTag, `connect() called: ${endpoint.host}:${endpoint.port} tls=${endpoint.useTls} token=${token ? 'yes(' + token.length + ')' : 'no'} password=${password ? 'yes' : 'no'}`);
    this.connectOnce();
  }

  disconnect(): void {
    this.log.info(this.logTag, 'disconnect() called');
    this.shouldReconnect = false;
    this.pairingResolve = undefined;
    this.connectResult = undefined;
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.closeSocket();
    this.failAllPending();
    this.setState(ConnectionState.Disconnected, 'Offline');
  }

  reconnect(): void {
    this.log.info(this.logTag, 'reconnect() called');
    this.closeSocket();
  }

  /** Cancel any pending reconnect timer and immediately attempt to reconnect. */
  forceReconnect(): void {
    this.log.info(this.logTag, 'forceReconnect() called');
    if (this.reconnectTimer >= 0) {
      clearTimeout(this.reconnectTimer);
      this.reconnectTimer = -1;
    }
    this.closeSocket();
    this.reconnectAttempt = 0;
    if (this.shouldReconnect) {
      this.connectOnce();
    }
  }

  /** Signal that pairing approval is done (success or failure). */
  notifyPairingDone(): void {
    if (this.pairingResolve) {
      let resolve = this.pairingResolve;
      this.pairingResolve = undefined;
      resolve();
    }
  }

  async request(method: string, paramsJson?: string, timeoutMs?: number): Promise<string> {
    if (!this.ws) {
      throw new Error('not connected');
    }
    let wsRef: webSocket.WebSocket = this.ws;
    let id = (this.nextId++).toString();
    let timeout = timeoutMs ?? Constants.GATEWAY_RPC_TIMEOUT_MS;

    this.log.debug(this.logTag, `RPC send: id=${id} method=${method} timeout=${timeout}ms`);

    return new Promise<string>((resolve, reject) => {
      let timer = setTimeout(() => {
        this.pending.delete(id);
        this.log.warn(this.logTag, `RPC timeout: id=${id} method=${method}`);
        reject(new Error('request timeout'));
      }, timeout);

      let rpc: PendingRpc = {
        resolve: (payload) => {
          resolve(payload !== undefined ? JSON.stringify(payload) : '');
        },
        reject: reject,
        timer: timer,
      };
      this.pending.set(id, rpc);

      let frameJson: string;
      if (paramsJson && paramsJson.length > 0) {
        frameJson = `{"type":"req","id":"${id}","method":"${method}","params":${paramsJson}}`;
      } else {
        frameJson = `{"type":"req","id":"${id}","method":"${method}"}`;
      }
      wsRef.send(frameJson, (err) => {
        if (err) {
          this.pending.delete(id);
          clearTimeout(timer);
          this.log.error(this.logTag, `RPC send failed: id=${id} method=${method} err=${err.message ?? ''}`);
          reject(new Error(`send failed: ${err.message ?? ''}`));
        }
      });
    });
  }

  async sendNodeEvent(event: string, payloadJson?: string): Promise<void> {
    if (!this.ws) {
      return;
    }
    let paramsInner: string = `"event":${JSON.stringify(event)}`;
    if (payloadJson && payloadJson.length > 0) {
      try {
        JSON.parse(payloadJson);
        paramsInner += `,"payload":${payloadJson}`;
      } catch {
        paramsInner += `,"payloadJSON":${JSON.stringify(payloadJson)}`;
      }
    }
    let paramsStr = `{${paramsInner}}`;
    try {
      await this.request('node.event', paramsStr, 8000);
    } catch (err) {
      this.log.warn(this.logTag, `node.event failed: ${(err as Error).message ?? ''}`);
    }
  }

  // ===================== Internal =====================

  private setState(state: ConnectionState, message?: string): void {
    this._state = state;
    let msg = message ?? state.toString();
    this.log.info(this.logTag, `state -> ${state} (${msg})`);
    try {
      this.onStateChanged(state, msg);
    } catch {
      // ignore callback errors
    }
  }

  private connectOnce(): void {
    let ep = this.endpoint;
    if (!ep) {
      this.log.warn(this.logTag, 'connectOnce: no endpoint');
      return;
    }
    this.setState(ConnectionState.Connecting, 'Connecting…');
    this.closeSocket();

    let scheme = ep.useTls ? 'wss' : 'ws';
    let host = ep.host.includes(':') ? `[${ep.host}]` : ep.host;
    let url = `${scheme}://${host}:${ep.port}`;

    this.log.info(this.logTag, `WebSocket connecting to ${url}`);

    let ws = webSocket.createWebSocket();
    this.ws = ws;
    this.wsGeneration++;
    this.closedHandled = false;
    let gen = this.wsGeneration;

    ws.on('open', (_err, _value) => {
      if (gen !== this.wsGeneration) return;
      this.log.info(this.logTag, `WebSocket OPEN to ${url}`);
      this.onWsOpen();
    });

    ws.on('message', (err, value) => {
      if (gen !== this.wsGeneration) return;
      let text: string = '';
      if (typeof value === 'string') {
        text = value;
      } else if (value instanceof ArrayBuffer) {
        try {
          let decoder = new util.TextDecoder('utf-8');
          text = decoder.decodeToString(new Uint8Array(value));
        } catch {
          this.log.error(this.logTag, `WS recv: ArrayBuffer decode failed`);
          return;
        }
      } else {
        this.log.warn(this.logTag, `WS recv: unexpected type ${typeof value}`);
        return;
      }
      if (text.length === 0) {
        this.log.debug(this.logTag, 'WS recv: ignoring empty message');
        return;
      }
      this.log.debug(this.logTag, `WS recv (${text.length}): ${text.substring(0, 300)}`);
      this.handleMessage(text);
    });

    ws.on('close', (_err, value) => {
      if (gen !== this.wsGeneration) return;
      let closeCode = 0;
      let closeReason = '';
      let isMock = false;
      if (value) {
        try {
          closeCode = value.code ?? 0;
          closeReason = value.reason ?? '';
          // Check isAutoMock via JSON roundtrip to avoid type issues
          let jsonStr = JSON.stringify(value);
          if (jsonStr.includes('"isAutoMock":true')) {
            isMock = true;
          }
        } catch { /* ignore */ }
      }
      if (isMock) {
        this.log.error(this.logTag, '*** WebSocket is AUTO-MOCKED! Not a real connection. Must test on real device or disable mock in DevEco. ***');
      }
      this.log.warn(this.logTag, `WebSocket CLOSED: code=${closeCode} reason="${closeReason}" mock=${isMock} raw=${JSON.stringify(value)}`);
      this.onWsClosedOnce(isMock ? 'WebSocket mocked (use real device)' : `Gateway closed (code=${closeCode})`);
    });

    ws.on('error', (err) => {
      if (gen !== this.wsGeneration) return;
      this.log.error(this.logTag, `WebSocket ERROR: ${err?.message ?? 'unknown'} code=${err?.code ?? ''}`);
      this.onWsClosedOnce(`Gateway error: ${err?.message ?? 'unknown'}`);
    });

    // Connect with header — do NOT set Origin manually!
    // HarmonyOS WebSocket auto-adds Origin; setting it explicitly causes
    // a duplicate "Origin: X, Y" which the gateway rejects.
    let connectHeader: Record<string, string> = {
      'User-Agent': this.options.userAgent ?? 'ClawdBotHarmony/1.0.0',
    };
    this.log.info(this.logTag, `ws.connect() with header: ${JSON.stringify(connectHeader)}`);
    ws.connect(url, { header: connectHeader }, (err, _connected) => {
      if (gen !== this.wsGeneration) return;
      if (err) {
        this.log.error(this.logTag, `ws.connect() callback error: code=${err.code ?? ''} msg=${err.message ?? ''}`);
        this.onWsClosedOnce(`Connect failed: ${err.message ?? ''}`);
      } else {
        this.log.info(this.logTag, 'ws.connect() callback: success');
      }
    });
  }

  private onWsOpen(): void {
    this.performConnectAsync();
  }

  private performConnectAsync(): void {
    let gen = this.wsGeneration;
    let savedNonce: string | undefined = undefined;
    this.log.info(this.logTag, 'Starting connect handshake (awaiting nonce)...');
    this.awaitConnectNonce().then((nonce) => {
      if (gen !== this.wsGeneration) return;
      savedNonce = nonce;
      this.log.info(this.logTag, `Nonce received: ${nonce ?? '(none/timeout)'}`);
      return this.performConnect(nonce);
    }).then(() => {
      if (gen !== this.wsGeneration) return;
      this.reconnectAttempt = 0;
      this.log.info(this.logTag, 'Connect handshake SUCCESS');
    }).catch((err: Error) => {
      if (gen !== this.wsGeneration) return;
      let errMsg = err.message ?? '';
      this.log.error(this.logTag, `Connect handshake FAILED: ${errMsg}`);

      if (errMsg.includes('NOT_PAIRED')) {
        // Keep WebSocket alive while pairing is being approved by operator session.
        // The gateway invalidates the pairing requestId when the node WS closes,
        // so we must stay connected until the approve completes.
        this.log.info(this.logTag, 'Waiting for pairing approval (keeping WS alive)...');
        let pairingTimeout = setTimeout(() => {
          if (this.pairingResolve) {
            this.log.warn(this.logTag, 'Pairing approval timed out after 12s');
            let resolve = this.pairingResolve;
            this.pairingResolve = undefined;
            resolve();
          }
        }, 12000);
        new Promise<void>((resolve) => {
          this.pairingResolve = resolve;
        }).then(() => {
          clearTimeout(pairingTimeout);
          if (gen !== this.wsGeneration) return;
          // Retry connect RPC on the SAME WebSocket with password auth.
          // Token auth fails after pairing because gateway may not issue a node token during approve.
          // Password auth bypasses the pairing requirement entirely.
          this.log.info(this.logTag, 'Pairing done, retrying connect on same WebSocket (forcePassword=true)...');
          return this.performConnect(savedNonce, true);
        }).then(() => {
          if (gen !== this.wsGeneration) return;
          this.reconnectAttempt = 0;
          this.log.info(this.logTag, 'Connect handshake SUCCESS (after pairing)');
        }).catch((retryErr: Error) => {
          if (gen !== this.wsGeneration) return;
          let retryMsg = retryErr.message ?? '';
          this.log.error(this.logTag, `Connect retry after pairing FAILED: ${retryMsg}`);
          this.closeSocket();
          this.reconnectAttempt = 0;
          this.onWsClosedOnce(`Auth failed after pairing: ${retryMsg}`);
        });
        return;
      }

      // Clear stale device token on auth failure so next reconnect uses fresh credentials
      this.clearStoredToken();
      this.closeSocket();
      this.onWsClosedOnce(`Auth failed: ${errMsg}`);
    });
  }

  private clearStoredToken(): void {
    let ctx = this.context;
    if (!ctx) return;
    let safeCtx: common.UIAbilityContext = ctx;
    this.identityStore.loadOrCreate(safeCtx).then((identity) => {
      this.log.info(this.logTag, `Clearing stale token for role=${this.options.role}`);
      return this.authStore.clearToken(safeCtx, identity.deviceId, this.options.role);
    }).catch(() => {
      // ignore
    });
  }

  private async awaitConnectNonce(): Promise<string | undefined> {
    let ep = this.endpoint;
    if (ep && this.isLoopback(ep.host)) {
      this.log.debug(this.logTag, 'Skipping nonce (loopback)');
      return undefined;
    }
    this.log.debug(this.logTag, 'Waiting for connect.challenge event (3s timeout)...');
    return new Promise<string | undefined>((resolve) => {
      this.connectNonceResolve = resolve;
      setTimeout(() => {
        if (this.connectNonceResolve === resolve) {
          this.connectNonceResolve = undefined;
          this.log.warn(this.logTag, 'Nonce timeout (3s) - proceeding without nonce');
          resolve(undefined);
        }
      }, 3000);
    });
  }

  private async performConnect(nonce: string | undefined, forcePassword?: boolean): Promise<void> {
    let ctx = this.context;
    if (!ctx) {
      throw new Error('no context');
    }

    this.log.info(this.logTag, 'Loading device identity...');
    let identity = await this.identityStore.loadOrCreate(ctx);
    this.log.info(this.logTag, `Device ID: ${identity.deviceId.substring(0, 16)}...`);

    let storedToken = await this.authStore.loadToken(ctx, identity.deviceId, this.options.role);
    let trimmedToken = this.token ?? '';
    let authToken = (storedToken && storedToken.length > 0) ? storedToken : trimmedToken;
    this.log.info(this.logTag, `Auth: storedToken=${storedToken ? 'yes(' + storedToken.length + ')' : 'no'} inputToken=${trimmedToken.length > 0 ? 'yes(' + trimmedToken.length + ')' : 'no'} using=${authToken.length > 0 ? 'token(' + authToken.length + ')' : 'none'}`);

    // Decide auth method BEFORE signing — the signature must match the auth method used.
    // Strategy for node role:
    //   - If stored device token exists → use it (device was previously paired successfully)
    //   - If no stored token + password available → use password (need to go through pairing first time)
    //   - forcePassword=true → always use password (e.g. retry after pairing on same WS)
    let hasPassword: boolean = (this.password !== undefined && this.password !== null && this.password.length > 0);
    let hasStoredToken: boolean = (storedToken !== undefined && storedToken !== null && storedToken.length > 0);
    let isNodeRole: boolean = (this.options.role === 'node');
    let usePassword: boolean = false;
    if (forcePassword === true && hasPassword) {
      usePassword = true;
    } else if (isNodeRole && hasPassword && !hasStoredToken) {
      // Node without stored device token: use password auth for initial pairing flow
      usePassword = true;
    }
    this.log.info(this.logTag, `Auth decision: role=${this.options.role} hasPassword=${hasPassword} hasStoredToken=${hasStoredToken} forcePassword=${forcePassword ?? false} usePassword=${usePassword}`);
    // When using password auth, do NOT include token in the signed payload.
    // The gateway verifies the signature against the connect params it receives,
    // and password auth params don't include a token — so the payload must match.
    let tokenForSignature: string | undefined = usePassword ? undefined : (authToken.length > 0 ? authToken : undefined);

    let signedAtMs = Date.now();
    let payload = this.identityStore.buildAuthPayload(
      identity.deviceId,
      this.options.client.id,
      this.options.client.mode,
      this.options.role,
      this.options.scopes,
      signedAtMs,
      tokenForSignature,
      nonce,
    );
    this.log.debug(this.logTag, `Auth payload: ${payload.substring(0, 200)}`);

    let signature = await this.identityStore.signPayload(payload);
    let publicKey = this.identityStore.getPublicKeyBase64Url();
    this.log.info(this.logTag, `Signature: ${signature.length > 0 ? signature.substring(0, 20) + '...' : '(EMPTY!)'} pubKey: ${publicKey.length > 0 ? publicKey.substring(0, 20) + '...' : '(EMPTY!)'}`);

    // Build auth JSON fragment
    let authFragment: string = '';
    if (usePassword) {
      authFragment = `,"auth":{"password":${JSON.stringify(this.password)}}`;
      this.log.info(this.logTag, `Using password auth (role=${this.options.role}, forcePassword=${forcePassword ?? false})`);
    } else if (authToken.length > 0) {
      authFragment = `,"auth":{"token":${JSON.stringify(authToken)}}`;
      this.log.info(this.logTag, 'Using token auth');
    } else if (this.password && this.password.length > 0) {
      authFragment = `,"auth":{"password":${JSON.stringify(this.password)}}`;
      this.log.info(this.logTag, 'Using password auth');
    } else {
      this.log.warn(this.logTag, 'NO auth (no token, no password)');
    }

    // Build device JSON fragment
    let deviceFragment: string = '';
    if (signature.length > 0 && publicKey.length > 0) {
      let deviceParts: string = `"id":${JSON.stringify(identity.deviceId)},"publicKey":${JSON.stringify(publicKey)},"signature":${JSON.stringify(signature)},"signedAt":${signedAtMs}`;
      if (nonce && nonce.length > 0) {
        deviceParts += `,"nonce":${JSON.stringify(nonce)}`;
      }
      deviceFragment = `,"device":{${deviceParts}}`;
      this.log.info(this.logTag, `Device identity included (nonce=${nonce ? 'yes' : 'no'})`);
    } else {
      this.log.warn(this.logTag, 'NO device identity (sig or pubKey empty)');
    }

    let capsFragment: string = '';
    if (this.options.caps.length > 0) {
      capsFragment = `,"caps":${JSON.stringify(this.options.caps)}`;
    }
    let commandsFragment: string = '';
    if (this.options.commands.length > 0) {
      commandsFragment = `,"commands":${JSON.stringify(this.options.commands)}`;
    }
    let scopesFragment: string = '';
    if (this.options.scopes.length > 0) {
      scopesFragment = `,"scopes":${JSON.stringify(this.options.scopes)}`;
    }
    let userAgentFragment: string = '';
    if (this.options.userAgent && this.options.userAgent.length > 0) {
      userAgentFragment = `,"userAgent":${JSON.stringify(this.options.userAgent)}`;
    }

    let clientJson: string = `{"id":${JSON.stringify(this.options.client.id)},"version":${JSON.stringify(this.options.client.version)},"platform":${JSON.stringify(this.options.client.platform)},"mode":${JSON.stringify(this.options.client.mode)}`;
    if (this.options.client.displayName && this.options.client.displayName.length > 0) {
      clientJson += `,"displayName":${JSON.stringify(this.options.client.displayName)}`;
    }
    if (this.options.client.deviceFamily) {
      clientJson += `,"deviceFamily":${JSON.stringify(this.options.client.deviceFamily)}`;
    }
    clientJson += '}';

    let locale = 'zh-CN';
    let connectParamsJson: string = `{"minProtocol":${GatewayProtocol.VERSION},"maxProtocol":${GatewayProtocol.VERSION},"client":${clientJson},"role":${JSON.stringify(this.options.role)},"locale":${JSON.stringify(locale)}${capsFragment}${commandsFragment}${scopesFragment}${authFragment}${deviceFragment}${userAgentFragment}}`;

    this.log.info(this.logTag, `Sending connect RPC: clientId=${this.options.client.id} mode=${this.options.client.mode} role=${this.options.role}`);
    this.log.debug(this.logTag, `Connect params (first 500): ${connectParamsJson.substring(0, 500)}`);

    let resJson = await this.request('connect', connectParamsJson, Constants.GATEWAY_CONNECT_TIMEOUT_MS);

    this.log.info(this.logTag, `Connect response: ${resJson.substring(0, 300)}`);

    // Store device token if returned
    if (resJson.length > 0) {
      try {
        let resObj = JSON.parse(resJson) as Record<string, Object>;
        this.connectResult = resObj;
        let authResult = resObj['auth'] as Record<string, string> | undefined;
        if (authResult) {
          let deviceToken = authResult['deviceToken'];
          let authRole = authResult['role'] ?? this.options.role;
          if (deviceToken && deviceToken.length > 0) {
            this.log.info(this.logTag, `Saving device token for role=${authRole} (${deviceToken.length} chars)`);
            await this.authStore.saveToken(ctx, identity.deviceId, authRole, deviceToken);
          } else {
            this.log.info(this.logTag, `Connect response auth has no deviceToken, keys: [${Object.keys(authResult).join(',')}]`);
          }
        } else {
          this.log.info(this.logTag, `Connect response has no auth block, keys: [${Object.keys(resObj).join(',')}]`);
        }
      } catch {
        // ignore parse errors
      }
    }

    this.setState(ConnectionState.Connected, 'Connected');
  }

  private handleMessage(text: string): void {
    let frame: RpcFrame;
    try {
      frame = JSON.parse(text) as RpcFrame;
    } catch {
      this.log.warn(this.logTag, `Failed to parse message: ${text.substring(0, 100)}`);
      return;
    }

    if (frame.type === 'res') {
      this.handleResponse(frame);
    } else if (frame.type === 'event') {
      this.handleEvent(frame);
    }
  }

  private handleResponse(frame: RpcFrame): void {
    let id = frame.id;
    if (!id) {
      return;
    }
    let rpc = this.pending.get(id);
    if (!rpc) {
      this.log.warn(this.logTag, `RPC response for unknown id=${id}`);
      return;
    }
    this.pending.delete(id);
    clearTimeout(rpc.timer);

    if (frame.ok) {
      this.log.debug(this.logTag, `RPC ok: id=${id}`);
      rpc.resolve(frame.payload);
    } else {
      let errMsg = frame.error ? `${frame.error.code}: ${frame.error.message}` : 'request failed';
      this.log.error(this.logTag, `RPC error: id=${id} ${errMsg}`);
      rpc.reject(new Error(errMsg));
      // Handle NOT_PAIRED: notify caller to auto-approve pairing
      if (frame.error && frame.error.code === 'NOT_PAIRED' && frame.error.details) {
        let reqId = frame.error.details['requestId'] ?? '';
        if (reqId.length > 0 && this.onPairingRequired) {
          this.log.info(this.logTag, `NOT_PAIRED detected, requesting auto-pair: requestId=${reqId}`);
          this.onPairingRequired(reqId);
        }
      }
    }
  }

  private handleEvent(frame: RpcFrame): void {
    let event = frame.event;
    if (!event) {
      return;
    }
    let payloadJson: string | undefined = undefined;
    if (frame.payload) {
      payloadJson = JSON.stringify(frame.payload);
    } else if (frame.payloadJSON) {
      payloadJson = frame.payloadJSON;
    }

    this.log.info(this.logTag, `Event: ${event} payload=${payloadJson ? payloadJson.substring(0, 200) : '(none)'}`);

    // Connect challenge nonce
    if (event === 'connect.challenge') {
      if (payloadJson && this.connectNonceResolve) {
        try {
          let obj = JSON.parse(payloadJson) as Record<string, string>;
          let nonceVal = obj['nonce'];
          this.log.info(this.logTag, `connect.challenge nonce: ${nonceVal ?? '(none)'}`);
          this.connectNonceResolve(nonceVal);
          this.connectNonceResolve = undefined;
        } catch {
          this.log.warn(this.logTag, 'Failed to parse connect.challenge payload');
        }
      } else {
        this.log.warn(this.logTag, `connect.challenge: payload=${payloadJson ? 'yes' : 'no'} resolver=${this.connectNonceResolve ? 'yes' : 'no'}`);
      }
      return;
    }

    // Node invoke request
    if (event === 'node.invoke.request' && payloadJson && this.onInvokeRequest) {
      this.log.info(this.logTag, `Invoke request: ${payloadJson.substring(0, 200)}`);
      this.handleInvokeEvent(payloadJson);
      return;
    }

    // Generic event
    this.onEvent(event, payloadJson);
  }

  private handleInvokeEvent(payloadJson: string): void {
    let req: InvokeRequest;
    try {
      let obj = JSON.parse(payloadJson) as Record<string, Object>;
      let reqId: string = (obj['id'] as string) ?? '';
      let reqNodeId: string = (obj['nodeId'] as string) ?? '';
      let reqCommand: string = (obj['command'] as string) ?? '';
      let reqParamsJSON: string | undefined = (obj['paramsJSON'] as string) ?? undefined;
      let reqParams: object | undefined = obj['params'] as object | undefined;
      let reqTimeoutMs: number | undefined = obj['timeoutMs'] as number | undefined;
      req = {
        id: reqId,
        nodeId: reqNodeId,
        command: reqCommand,
        paramsJSON: reqParamsJSON,
        params: reqParams,
        timeoutMs: reqTimeoutMs,
      };
    } catch {
      return;
    }
    if (!req.id || !req.command) {
      return;
    }

    let handler = this.onInvokeRequest;
    if (!handler) {
      return;
    }

    handler(req).then((result) => {
      this.log.info(this.logTag, `Invoke result: ${req.command} ok=${result.ok}`);
      this.sendInvokeResult(req.id, req.nodeId, result);
    }).catch((err: Error) => {
      this.log.error(this.logTag, `Invoke error: ${req.command} ${err.message ?? ''}`);
      let errResult = InvokeResult.error('UNAVAILABLE', err.message ?? 'invoke failed');
      this.sendInvokeResult(req.id, req.nodeId, errResult);
    });
  }

  private async sendInvokeResult(id: string, nodeId: string, result: InvokeResult): Promise<void> {
    let parts: string = `"id":${JSON.stringify(id)},"nodeId":${JSON.stringify(nodeId)},"ok":${result.ok}`;
    if (result.payloadJson) {
      try {
        JSON.parse(result.payloadJson);
        parts += `,"payload":${result.payloadJson}`;
      } catch {
        parts += `,"payloadJSON":${JSON.stringify(result.payloadJson)}`;
      }
    }
    if (!result.ok && result.errorCode) {
      parts += `,"error":{"code":${JSON.stringify(result.errorCode)},"message":${JSON.stringify(result.errorMessage ?? '')}}`;
    }
    let paramsStr = `{${parts}}`;
    try {
      await this.request('node.invoke.result', paramsStr, 15000);
    } catch (err) {
      this.log.warn(this.logTag, `node.invoke.result send failed: ${(err as Error).message ?? ''}`);
    }
  }

  private onWsClosedOnce(message: string): void {
    if (this.closedHandled) {
      return;
    }
    this.closedHandled = true;
    this.onWsClosed(message);
  }

  private onWsClosed(message: string): void {
    this.ws = undefined;
    this.failAllPending();
    this.connectNonceResolve = undefined;

    if (!this.shouldReconnect) {
      this.setState(ConnectionState.Disconnected, message);
      return;
    }

    this.reconnectAttempt++;
    let delayMs = Math.min(
      Constants.GATEWAY_RECONNECT_MAX_MS,
      Constants.GATEWAY_RECONNECT_BASE_MS * Math.pow(Constants.GATEWAY_RECONNECT_MULTIPLIER, this.reconnectAttempt),
    );
    this.log.info(this.logTag, `Reconnecting in ${Math.round(delayMs)}ms (attempt ${this.reconnectAttempt}) reason: ${message}`);
    this.setState(ConnectionState.Reconnecting, `Reconnecting in ${Math.round(delayMs / 1000)}s…`);

    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = -1;
      this.connectOnce();
    }, delayMs);
  }

  private closeSocket(): void {
    let ws = this.ws;
    this.ws = undefined;
    this.wsGeneration++;
    if (ws) {
      try {
        ws.close({ code: 1000, reason: 'bye' }, () => {});
      } catch {
        // ignore
      }
    }
  }

  private failAllPending(): void {
    let err = new Error('disconnected');
    let count = this.pending.size;
    if (count > 0) {
      this.log.warn(this.logTag, `Failing ${count} pending RPCs`);
    }
    let keys = Array.from(this.pending.keys());
    for (let i = 0; i < keys.length; i++) {
      let rpc = this.pending.get(keys[i]);
      if (rpc) {
        clearTimeout(rpc.timer);
        rpc.reject(err);
      }
    }
    this.pending.clear();
  }

  private isLoopback(host: string): boolean {
    let h = host.trim().toLowerCase();
    if (h === 'localhost' || h === '::1' || h === '0.0.0.0' || h === '::') {
      return true;
    }
    return h.startsWith('127.');
  }
}
