// ============================================================
//  Observable data models used by UI components via @ObjectLink
// ============================================================

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

// Plain data interfaces for serialization (non-observed)
export interface ApiMessage {
  role: string;
  content: string;
  toolCalls?: string;    // JSON string of OpenAI tool_calls array (for assistant messages)
  toolCallId?: string;   // tool_call_id (for role:"tool" result messages)
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
  vector: number[];     // embedding vector (1024-dim for bge-m3)
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
