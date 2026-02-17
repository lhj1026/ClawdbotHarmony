// ============================================================
//  Observable data models used by UI components via @ObjectLink
// ============================================================

@Observed
export class InlineButton {
  label: string;
  action: string;

  constructor(label: string, action: string) {
    this.label = label;
    this.action = action;
  }
}

@Observed
export class ChatMessage {
  id: string;
  role: string;        // 'user' | 'assistant' | 'tool'
  content: string;
  timestamp: number;
  isToolCall: boolean;
  toolName: string;
  toolInput: string;
  toolOutput: string;
  imagePath: string;   // local file path for photos displayed in chat
  audioPath: string;   // local file path for audio playback in chat
  userImagePath: string;      // user-attached image path (first/primary, for API compat)
  userImagePaths: string[];   // all user-attached image paths (for multi-image display)
  videoPath: string;      // local file path for video playback
  buttons: InlineButton[];  // inline action buttons
  attachmentName: string;   // file attachment display name
  a2uiContent: string;      // accumulated A2UI JSONL content for inline rendering
  canvasUrl: string;        // URL for inline canvas rendering (data: or http:)
  replyToId: string;        // ID of the message being replied to
  replyToContent: string;   // Preview content of the replied message
  replyToRole: string;      // Role of the replied message ('user' | 'assistant')

  constructor(role: string, content: string) {
    this.id = `m_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    this.role = role;
    this.content = content;
    this.timestamp = Date.now();
    this.isToolCall = false;
    this.toolName = '';
    this.toolInput = '';
    this.toolOutput = '';
    this.imagePath = '';
    this.audioPath = '';
    this.userImagePath = '';
    this.userImagePaths = [];
    this.videoPath = '';
    this.buttons = [];
    this.attachmentName = '';
    this.a2uiContent = '';
    this.canvasUrl = '';
    this.replyToId = '';
    this.replyToContent = '';
    this.replyToRole = '';
  }
}

@Observed
export class MemoryItem {
  id: string;
  memType: string;     // 'fact' | 'preference' | 'instruction'
  content: string;
  importance: number;
  createdAt: number;

  constructor(memType: string, content: string, importance: number = 0.5) {
    this.id = `mem_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    this.memType = memType;
    this.content = content;
    this.importance = importance;
    this.createdAt = Date.now();
  }
}

@Observed
export class ToolDef {
  name: string;
  description: string;

  constructor(name: string, description: string) {
    this.name = name;
    this.description = description;
  }
}

@Observed
export class SkillItem {
  id: string;
  name: string;
  description: string;
  category: string;
  enabled: boolean;
  isBuiltin: boolean;
  toolCount: number;

  constructor(
    id: string, name: string, description: string,
    category: string, enabled: boolean, isBuiltin: boolean,
    toolCount: number
  ) {
    this.id = id;
    this.name = name;
    this.description = description;
    this.category = category;
    this.enabled = enabled;
    this.isBuiltin = isBuiltin;
    this.toolCount = toolCount;
  }
}

// Custom skill definition (user-created via AI)
export interface CustomSkillDef {
  id: string;           // 'custom_' + timestamp
  name: string;         // display name
  description: string;  // skill description
  category: string;     // category (default 'custom')
  enabled: boolean;     // whether enabled
  prompt: string;       // AI execution instructions (core)
  createdAt: number;    // creation timestamp
}

// Plain data interfaces for serialization (non-observed)
export interface ApiMessage {
  role: string;
  content: string;
  toolCalls?: string;    // JSON string of OpenAI tool_calls array (for assistant messages)
  toolCallId?: string;   // tool_call_id (for role:"tool" result messages)
  imageBase64?: string;  // base64-encoded image for multimodal messages
}

export interface ToolSchema {
  name: string;
  description: string;
  input_schema: object;
}

export interface MemoryData {
  id: string;
  memType: string;
  content: string;
  importance: number;
  createdAt: number;
}

export interface SettingsData {
  provider: string;
  apiKey: string;
  model: string;
  baseUrl: string;
  temperature: number;
}

// Vector embedding data for semantic memory search
export interface VectorData {
  id: string;           // corresponds to MemoryItem.id
  vector: number[];     // embedding vector (dimension depends on model)
}

export interface VectorStore {
  model: string;        // embedding model used
  vectors: VectorData[];
}

export interface ConversationFile {
  filename: string;
  timestamp: number;
  messageCount: number;
}

export interface CronParseResult {
  intervalMs: number;
  nextRunTime: number;
  oneShot: boolean;
  error: string;
}

export interface SettingsProfile {
  name: string;
  mode: string;        // 'standalone' | 'node'
  data: string;        // JSON-serialized settings
  createdAt: number;
}

export interface CronTask {
  id: string;
  prompt: string;
  cronExpr: string;
  intervalMs: number;
  nextRunTime: number;
  lastRunTime: number;
  enabled: boolean;
  oneShot: boolean;
}

// Token usage statistics
export interface TokenUsage {
  inputTokens: number;   // cumulative input tokens
  outputTokens: number;  // cumulative output tokens
  totalTokens: number;   // total tokens used
  lastUpdated: number;   // timestamp of last update
}

// Chat session for multi-conversation support
@Observed
export class ChatSession {
  id: string;           // unique session ID
  title: string;        // session title (auto-generated or user-defined)
  createdAt: number;    // creation timestamp
  updatedAt: number;    // last update timestamp
  messageCount: number; // number of messages
  lastMessage: string;  // last message preview
  isPinned: boolean;    // whether pinned to top
  isClosed: boolean;    // whether closed (hidden from drawer but history preserved)
  inputTokens: number;  // cumulative input tokens used
  outputTokens: number; // cumulative output tokens used
  totalTokens: number;  // total tokens (input + output)
  isActive: boolean;    // whether this session is currently processing

  constructor(title: string = '') {
    this.id = `session_${Date.now()}_${Math.floor(Math.random() * 100000)}`;
    this.title = title || '新对话';
    this.createdAt = Date.now();
    this.updatedAt = Date.now();
    this.messageCount = 0;
    this.lastMessage = '';
    this.isPinned = false;
    this.isClosed = false;
    this.inputTokens = 0;
    this.outputTokens = 0;
    this.totalTokens = 0;
    this.isActive = false;
  }
}

// Serializable session data
export interface ChatSessionData {
  id: string;
  title: string;
  createdAt: number;
  updatedAt: number;
  messageCount: number;
  lastMessage: string;
  isPinned: boolean;
  isClosed: boolean;
  inputTokens?: number;
  outputTokens?: number;
  totalTokens?: number;
}

// Queued message waiting to be sent to AI
export interface QueuedMessage {
  id: string;
  text: string;
  status: string;  // 'pending' | 'sending' | 'failed'
  timestamp: number;
  sessionId: string;
}

// Silent mode conversation entry (a single recognized speech segment)
export interface SilentConversationEntry {
  timestamp: number;       // when this segment was detected
  speaker: string;         // identified speaker name or 'Unknown'
  text: string;            // transcribed text
  confidence: number;      // speaker identification confidence (0-1)
}

// Full silent conversation record (persisted)
export interface SilentConversationRecord {
  id: string;              // unique record ID
  startTime: number;       // when recording started
  endTime: number;         // when recording ended (0 if still active)
  entries: SilentConversationEntry[];
  summary: string;         // AI-generated summary
  status: string;          // 'recording' | 'summarizing' | 'completed' | 'error'
  participants: string[];  // unique speaker names
}

// Lightweight observable item for UI list display
@Observed
export class SilentConversationItem {
  id: string;
  startTime: number;
  endTime: number;
  summary: string;
  status: string;
  participants: string[];
  entryCount: number;

  constructor(record: SilentConversationRecord) {
    this.id = record.id;
    this.startTime = record.startTime;
    this.endTime = record.endTime;
    this.summary = record.summary;
    this.status = record.status;
    this.participants = record.participants;
    this.entryCount = record.entries.length;
  }
}
