export class Constants {
  static readonly PREFS_SETTINGS: string = 'clawdbot_settings';
  static readonly PREFS_MEMORY: string = 'clawdbot_memory';
  static readonly PREFS_MESSAGES: string = 'clawdbot_messages';
  static readonly PREFS_GATEWAY: string = 'clawdbot_gateway';
  static readonly PREFS_DEVICE_IDENTITY: string = 'clawdbot_device_identity';
  static readonly PREFS_DEVICE_AUTH: string = 'clawdbot_device_auth';
  static readonly PREFS_LOGIN: string = 'clawdbot_login';

  static readonly ANTHROPIC_URL: string = 'https://api.anthropic.com/v1/messages';
  static readonly OPENAI_URL: string = 'https://api.siliconflow.cn/v1/chat/completions';
  static readonly OPENROUTER_URL: string = 'https://openrouter.ai/api/v1/chat/completions';

  static readonly DEFAULT_MODEL_ANTHROPIC: string = 'claude-sonnet-4-20250514';
  static readonly DEFAULT_MODEL_OPENAI: string = 'Qwen/Qwen3-VL-30B-A3B-Instruct';
  static readonly DEFAULT_MODEL_OPENROUTER: string = 'openrouter/free';

  // Built-in OpenRouter API key for free models
  static readonly OPENROUTER_DEFAULT_KEY: string = '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';

  // Built-in SiliconFlow API key (default for OpenAI provider)
  static readonly SILICONFLOW_DEFAULT_KEY: string = 'sk-llzsefwbcyovbwqvtdtnyujqjwhlrypfowgmzianzndrihtg';

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
