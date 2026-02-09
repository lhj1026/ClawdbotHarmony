export class Constants {
  static readonly PREFS_SETTINGS: string = 'clawdbot_settings';
  static readonly PREFS_MEMORY: string = 'clawdbot_memory';
  static readonly PREFS_MESSAGES: string = 'clawdbot_messages';
  static readonly PREFS_GATEWAY: string = 'clawdbot_gateway';
  static readonly PREFS_DEVICE_IDENTITY: string = 'clawdbot_device_identity';
  static readonly PREFS_DEVICE_AUTH: string = 'clawdbot_device_auth';

  static readonly ANTHROPIC_URL: string = 'https://api.anthropic.com/v1/messages';
  static readonly OPENAI_URL: string = 'https://api.openai.com/v1/chat/completions';

  static readonly DEFAULT_MODEL_ANTHROPIC: string = 'claude-sonnet-4-20250514';
  static readonly DEFAULT_MODEL_OPENAI: string = 'gpt-4o';

  static readonly MAX_TOKENS: number = 4096;
  static readonly MAX_HISTORY: number = 50;
  static readonly MAX_TOOL_LOOPS: number = 8;

  // Gateway / Node Mode
  static readonly DEFAULT_GATEWAY_PORT: number = 9315;
  static readonly GATEWAY_RPC_TIMEOUT_MS: number = 30000;
  static readonly GATEWAY_RECONNECT_BASE_MS: number = 350;
  static readonly GATEWAY_RECONNECT_MULTIPLIER: number = 1.7;
  static readonly GATEWAY_RECONNECT_MAX_MS: number = 8000;
  static readonly GATEWAY_CONNECT_TIMEOUT_MS: number = 8000;
}
