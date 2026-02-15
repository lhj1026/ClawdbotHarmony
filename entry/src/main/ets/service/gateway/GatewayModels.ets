/**
 * Data types for gateway wire protocol and configuration.
 * Ported from GatewaySession.kt data classes + GatewayEndpoint.kt.
 */

// --------------- Gateway endpoint ---------------

export interface GatewayEndpoint {
  host: string;
  port: number;
  useTls: boolean;
}

// --------------- Connection state ---------------

export enum ConnectionState {
  Disconnected = 'Offline',
  Connecting = 'Connecting…',
  Connected = 'Connected',
  Reconnecting = 'Reconnecting…',
  Error = 'Error',
}

// --------------- RPC wire frames ---------------

export interface RpcFrame {
  type: string;     // 'req' | 'res' | 'event'
  id?: string;
  method?: string;
  params?: object;
  ok?: boolean;
  payload?: object;
  payloadJSON?: string;
  error?: RpcError;
  event?: string;
}

export interface RpcError {
  code: string;
  message: string;
  details?: Record<string, string>;
}

// --------------- Connect handshake ---------------

export interface ClientInfo {
  id: string;
  displayName?: string;
  version: string;
  platform: string;
  mode: string;       // 'node' | 'ui'
  instanceId?: string;
  deviceFamily?: string;
  modelIdentifier?: string;
}

export interface ConnectOptions {
  role: string;          // 'operator' | 'node'
  scopes: string[];
  caps: string[];
  commands: string[];
  permissions: Record<string, boolean>;
  client: ClientInfo;
  userAgent?: string;
}

// --------------- Node invoke ---------------

export interface InvokeRequest {
  id: string;
  nodeId: string;
  command: string;
  paramsJSON?: string;
  params?: object;
  timeoutMs?: number;
}

export class InvokeResult {
  ok: boolean = true;
  payloadJson: string | undefined = undefined;
  errorCode: string | undefined = undefined;
  errorMessage: string | undefined = undefined;

  static success(payloadJson?: string): InvokeResult {
    let r = new InvokeResult();
    r.ok = true;
    r.payloadJson = payloadJson;
    return r;
  }

  static error(code: string, message: string): InvokeResult {
    let r = new InvokeResult();
    r.ok = false;
    r.errorCode = code;
    r.errorMessage = message;
    return r;
  }
}

// --------------- Chat via gateway (operator session) ---------------

export interface GatewayChatContentBlock {
  type: string;      // 'text' | 'tool_use' | 'tool_result' | ...
  text?: string;
}

export interface GatewayChatMessage {
  role: string;      // 'assistant'
  content: GatewayChatContentBlock[];
  timestamp?: number;
}

export interface GatewayChatEvent {
  runId: string;
  sessionKey: string;
  seq: number;
  state: string;     // 'delta' | 'final' | 'error' | 'aborted'
  message?: GatewayChatMessage;
  errorMessage?: string;
  stopReason?: string;
}

// --------------- Exec approval ---------------

export interface ExecApprovalRequest {
  id: string;           // approval UUID
  command: string;      // command being executed
  cwd: string;          // working directory
  host: string;         // execution host (node-id or "gateway")
  agentId: string;      // agent that requested the exec
  sessionKey: string;   // agent session key
  expiresAt: number;    // expiration timestamp (ms)
}

// --------------- Gateway settings (persisted) ---------------

export interface GatewaySettings {
  enabled: boolean;
  host: string;
  port: number;
  useTls: boolean;
  password: string;
}
