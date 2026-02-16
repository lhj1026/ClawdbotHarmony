export class Constants {
  static readonly PREFS_SETTINGS: string = 'clawdbot_settings';
  static readonly PREFS_MEMORY: string = 'clawdbot_memory';
  static readonly PREFS_MESSAGES: string = 'clawdbot_messages';
  static readonly PREFS_GATEWAY: string = 'clawdbot_gateway';
  static readonly PREFS_DEVICE_IDENTITY: string = 'clawdbot_device_identity';
  static readonly PREFS_DEVICE_AUTH: string = 'clawdbot_device_auth';
  static readonly PREFS_CRON: string = 'clawdbot_cron';
  static readonly PREFS_EMAIL: string = 'clawdbot_email';
  static readonly PREFS_FEISHU: string = 'clawdbot_feishu';
  static readonly PREFS_CUSTOM_SKILLS: string = 'clawdbot_custom_skills';

  // Session persistence
  static readonly PREFS_SESSIONS: string = 'chat_sessions';
  static readonly SESSIONS_KEY: string = 'session_list';
  static readonly MESSAGES_PREFIX: string = 'session_messages_';
  static readonly CURRENT_SESSION_KEY: string = 'current_session_id';
  static readonly QUEUE_PREFIX: string = 'session_queue_';
  static readonly DEFAULT_SESSION_ID: string = 'default';

  static readonly CRON_POLL_INTERVAL_MS: number = 30000;

  // Settings mode configuration
  // To enable all modes, change to: ['standalone', 'node', 'service']
  static readonly ENABLED_MODES: string[] = ['standalone', 'node'];
  static readonly DEFAULT_MODE: string = 'node';

  // Feishu Bot API
  static readonly FEISHU_TOKEN_URL: string = 'https://open.feishu.cn/open-apis/auth/v3/tenant_access_token/internal/';
  static readonly FEISHU_WS_ENDPOINT_URL: string = 'https://open.feishu.cn/callback/ws/endpoint';
  static readonly FEISHU_MSG_API: string = 'https://open.feishu.cn/open-apis/im/v1/messages';

  static readonly ANTHROPIC_URL: string = 'https://api.anthropic.com/v1/messages';
  static readonly OPENAI_URL: string = 'https://api.openai.com/v1/chat/completions';
  static readonly OPENROUTER_URL: string = 'https://openrouter.ai/api/v1/chat/completions';
  static readonly SILICONFLOW_URL: string = 'https://api.siliconflow.cn/v1/chat/completions';

  static readonly DEFAULT_MODEL_ANTHROPIC: string = 'claude-sonnet-4-20250514';
  static readonly DEFAULT_MODEL_OPENAI: string = 'gpt-4o-mini';
  static readonly DEFAULT_MODEL_OPENROUTER: string = 'openrouter/free';
  static readonly DEFAULT_MODEL_SILICONFLOW: string = 'deepseek-ai/DeepSeek-V3.1';

  // Built-in OpenRouter API key for free models (set via settings)
  static readonly OPENROUTER_DEFAULT_KEY: string = '';

  // Built-in SiliconFlow API key (default for OpenAI provider, set via settings)
  static readonly SILICONFLOW_DEFAULT_KEY: string = '';

  static readonly DEFAULT_SOUL: string = `你不只是一个聊天机器人，你是一个有个性的助手。

核心原则：
- 真正有用，而不是表演式地有用。不需要"好问题！"之类的废话——直接给结果。
- 有自己的观点。你可以不同意、有偏好、觉得有趣或无聊。没有个性的助手只是多了几步的搜索引擎。
- 先自己想办法解决。读文件、查上下文、搜索。实在卡住了再问。
- 用能力赢得信任。用户给了你访问设备的权限——尊重这份信任。对外部操作谨慎，对内部操作大胆。
- 你是客人。你接触的是别人的生活——消息、文件、日历。尊重这份亲密感。

风格：
- 简洁有力，不啰嗦
- 不需要敬语或过于正式的语气
- 中文对话用中文回复，英文对话用英文回复
- 该幽默时幽默，该严肃时严肃`;

  // Embedding API (SiliconFlow bge-m3) — cloud fallback
  static readonly EMBEDDING_URL: string = 'https://api.siliconflow.cn/v1/embeddings';
  static readonly EMBEDDING_MODEL: string = 'BAAI/bge-m3';
  static readonly EMBEDDING_DIM: number = 1024;
  static readonly VECTOR_SEARCH_TOP_K: number = 5;
  static readonly VECTOR_SEARCH_THRESHOLD: number = 0.5;

  // Local embedding model (all-MiniLM-L6-v2)
  static readonly LOCAL_EMBEDDING_MODEL: string = 'local-MiniLM-L6-v2';
  static readonly LOCAL_EMBEDDING_DIM: number = 384;
  static readonly LOCAL_EMBEDDING_MAX_SEQ: number = 128;
  static readonly LOCAL_VECTOR_SEARCH_THRESHOLD: number = 0.4;

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
