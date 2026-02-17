// Session management service for multi-conversation support
import { preferences } from '@kit.ArkData';
import { ChatSession, ChatSessionData, ChatMessage, QueuedMessage } from '../model/Models';
import { LogService } from '../common/LogService';
import { Constants } from '../common/Constants';

// Serializable message data structure
interface MessageData {
  id: string;
  role: string;
  content: string;
  timestamp: number;
  isToolCall: boolean;
  toolName: string;
  toolInput: string;
  toolOutput: string;
  imagePath: string;
  audioPath: string;
  userImagePath: string;
  userImagePaths: string[];
  videoPath: string;
  attachmentName: string;
  replyToId: string;
  replyToContent: string;
  replyToRole: string;
}

export class SessionService {
  private static instance: SessionService;
  private prefs: preferences.Preferences | undefined;
  private log: LogService = LogService.getInstance();
  private sessions: ChatSession[] = [];
  private currentSessionId: string = Constants.DEFAULT_SESSION_ID;
  private initialized: boolean = false;

  private constructor() {}

  static getInstance(): SessionService {
    if (!SessionService.instance) {
      SessionService.instance = new SessionService();
    }
    return SessionService.instance;
  }

  async initialize(context: Context): Promise<void> {
    if (this.initialized) return;
    
    try {
      this.prefs = await preferences.getPreferences(context, Constants.PREFS_SESSIONS);
      await this.loadSessions();
      await this.loadCurrentSessionId();
      
      // Ensure at least one session exists
      if (this.sessions.length === 0) {
        const defaultSession = new ChatSession('默认对话');
        defaultSession.id = Constants.DEFAULT_SESSION_ID;
        this.sessions.push(defaultSession);
        await this.saveSessions();
      }
      
      this.initialized = true;
      this.log.info('SessionService', `Initialized with ${this.sessions.length} sessions`);
    } catch (err) {
      this.log.error('SessionService', `Initialize failed: ${err}`);
    }
  }

  private async loadSessions(): Promise<void> {
    if (!this.prefs) return;
    
    try {
      const json = await this.prefs.get(Constants.SESSIONS_KEY, '[]') as string;
      const dataList: ChatSessionData[] = JSON.parse(json);
      
      this.sessions = dataList.map(data => {
        const session = new ChatSession(data.title);
        session.id = data.id;
        session.createdAt = data.createdAt;
        session.updatedAt = data.updatedAt;
        session.messageCount = data.messageCount;
        session.lastMessage = data.lastMessage;
        session.isPinned = data.isPinned || false;
        session.isClosed = data.isClosed || false;
        return session;
      });
    } catch (err) {
      this.log.error('SessionService', `Load sessions failed: ${err}`);
      this.sessions = [];
    }
  }

  private async saveSessions(): Promise<void> {
    if (!this.prefs) return;
    
    try {
      const dataList: ChatSessionData[] = this.sessions.map((s): ChatSessionData => {
        return {
          id: s.id,
          title: s.title,
          createdAt: s.createdAt,
          updatedAt: s.updatedAt,
          messageCount: s.messageCount,
          lastMessage: s.lastMessage,
          isPinned: s.isPinned,
          isClosed: s.isClosed
        };
      });
      
      await this.prefs.put(Constants.SESSIONS_KEY, JSON.stringify(dataList));
      await this.prefs.flush();
    } catch (err) {
      this.log.error('SessionService', `Save sessions failed: ${err}`);
    }
  }

  private async loadCurrentSessionId(): Promise<void> {
    if (!this.prefs) return;
    
    try {
      this.currentSessionId = await this.prefs.get(Constants.CURRENT_SESSION_KEY, Constants.DEFAULT_SESSION_ID) as string;
    } catch (err) {
      this.currentSessionId = Constants.DEFAULT_SESSION_ID;
    }
  }

  private async saveCurrentSessionId(): Promise<void> {
    if (!this.prefs) return;
    
    try {
      await this.prefs.put(Constants.CURRENT_SESSION_KEY, this.currentSessionId);
      await this.prefs.flush();
    } catch (err) {
      this.log.error('SessionService', `Save current session ID failed: ${err}`);
    }
  }

  // Get active (non-closed) sessions sorted by pinned first, then by updatedAt
  getSessions(): ChatSession[] {
    return [...this.sessions].filter(s => !s.isClosed).sort((a, b) => {
      if (a.isPinned && !b.isPinned) return -1;
      if (!a.isPinned && b.isPinned) return 1;
      return b.updatedAt - a.updatedAt;
    });
  }

  // Get all sessions including closed ones, sorted by updatedAt
  getAllSessions(): ChatSession[] {
    return [...this.sessions].sort((a, b) => b.updatedAt - a.updatedAt);
  }

  getCurrentSessionId(): string {
    return this.currentSessionId;
  }

  getCurrentSession(): ChatSession | undefined {
    return this.sessions.find(s => s.id === this.currentSessionId);
  }

  async setCurrentSession(sessionId: string): Promise<void> {
    if (this.sessions.find(s => s.id === sessionId)) {
      this.currentSessionId = sessionId;
      await this.saveCurrentSessionId();
      this.log.info('SessionService', `Switched to session: ${sessionId}`);
    }
  }

  async createSession(title: string = ''): Promise<ChatSession> {
    const session = new ChatSession(title || '新对话');
    this.sessions.unshift(session);
    await this.saveSessions();
    this.log.info('SessionService', `Created session: ${session.id} - ${session.title}`);
    return session;
  }

  async deleteSession(sessionId: string): Promise<boolean> {
    const index = this.sessions.findIndex(s => s.id === sessionId);
    if (index === -1) return false;

    // If deleting the last session, create a new empty one first
    if (this.sessions.length <= 1) {
      const newSession = new ChatSession('新对话');
      this.sessions.unshift(newSession);
      this.log.info('SessionService', `Created replacement session: ${newSession.id}`);
    }

    this.sessions.splice(this.sessions.findIndex(s => s.id === sessionId), 1);

    // Clear messages and queue for this session
    if (this.prefs) {
      await this.prefs.delete(Constants.MESSAGES_PREFIX + sessionId);
      await this.prefs.delete(Constants.QUEUE_PREFIX + sessionId);
    }

    // If deleted current session, switch to first available
    if (this.currentSessionId === sessionId) {
      this.currentSessionId = this.sessions[0].id;
      await this.saveCurrentSessionId();
    }

    await this.saveSessions();
    this.log.info('SessionService', `Deleted session: ${sessionId}`);
    return true;
  }

  // Close session: hide from drawer but preserve history data
  async closeSession(sessionId: string): Promise<boolean> {
    const session = this.sessions.find(s => s.id === sessionId);
    if (!session) return false;

    // If closing the last active session, create a new one first
    const activeSessions = this.sessions.filter(s => !s.isClosed);
    if (activeSessions.length <= 1) {
      const newSession = new ChatSession('新对话');
      this.sessions.unshift(newSession);
      this.log.info('SessionService', `Created replacement session: ${newSession.id}`);
    }

    session.isClosed = true;
    session.updatedAt = Date.now();

    // If closed current session, switch to first active
    if (this.currentSessionId === sessionId) {
      const firstActive = this.sessions.find(s => !s.isClosed);
      if (firstActive) {
        this.currentSessionId = firstActive.id;
        await this.saveCurrentSessionId();
      }
    }

    await this.saveSessions();
    this.log.info('SessionService', `Closed session: ${sessionId}`);
    return true;
  }

  // Permanently delete session: remove from list AND delete all history data
  async deleteSessionPermanently(sessionId: string): Promise<boolean> {
    const index = this.sessions.findIndex(s => s.id === sessionId);
    if (index === -1) return false;

    this.sessions.splice(index, 1);

    // Clear messages and queue for this session
    if (this.prefs) {
      await this.prefs.delete(Constants.MESSAGES_PREFIX + sessionId);
      await this.prefs.delete(Constants.QUEUE_PREFIX + sessionId);
    }

    // If deleted current session, switch to first available active
    if (this.currentSessionId === sessionId) {
      const firstActive = this.sessions.find(s => !s.isClosed);
      if (firstActive) {
        this.currentSessionId = firstActive.id;
      } else if (this.sessions.length > 0) {
        this.currentSessionId = this.sessions[0].id;
      }
      await this.saveCurrentSessionId();
    }

    await this.saveSessions();
    this.log.info('SessionService', `Permanently deleted session: ${sessionId}`);
    return true;
  }

  async renameSession(sessionId: string, newTitle: string): Promise<boolean> {
    const session = this.sessions.find(s => s.id === sessionId);
    if (!session) return false;
    
    session.title = newTitle;
    session.updatedAt = Date.now();
    await this.saveSessions();
    this.log.info('SessionService', `Renamed session ${sessionId} to: ${newTitle}`);
    return true;
  }

  async togglePinSession(sessionId: string): Promise<boolean> {
    const session = this.sessions.find(s => s.id === sessionId);
    if (!session) return false;
    
    session.isPinned = !session.isPinned;
    await this.saveSessions();
    return true;
  }

  // Load messages for a specific session
  async loadMessages(sessionId: string): Promise<ChatMessage[]> {
    if (!this.prefs) return [];
    
    try {
      const json = await this.prefs.get(Constants.MESSAGES_PREFIX + sessionId, '[]') as string;
      const dataList = JSON.parse(json) as object[];
      
      return dataList.map(data => {
        const d = data as Record<string, Object>;
        const msg = new ChatMessage(d['role'] as string || 'user', d['content'] as string || '');
        msg.id = d['id'] as string || msg.id;
        msg.timestamp = d['timestamp'] as number || Date.now();
        msg.isToolCall = d['isToolCall'] as boolean || false;
        msg.toolName = d['toolName'] as string || '';
        msg.toolInput = d['toolInput'] as string || '';
        msg.toolOutput = d['toolOutput'] as string || '';
        msg.imagePath = d['imagePath'] as string || '';
        msg.audioPath = d['audioPath'] as string || '';
        msg.userImagePath = d['userImagePath'] as string || '';
        msg.userImagePaths = d['userImagePaths'] as string[] || [];
        msg.videoPath = d['videoPath'] as string || '';
        msg.attachmentName = d['attachmentName'] as string || '';
        msg.replyToId = d['replyToId'] as string || '';
        msg.replyToContent = d['replyToContent'] as string || '';
        msg.replyToRole = d['replyToRole'] as string || '';
        return msg;
      });
    } catch (err) {
      this.log.error('SessionService', `Load messages failed for ${sessionId}: ${err}`);
      return [];
    }
  }

  // Save messages for a specific session
  async saveMessages(sessionId: string, messages: ChatMessage[]): Promise<void> {
    if (!this.prefs) return;
    
    try {
      const dataList: MessageData[] = [];
      for (let msg of messages) {
        let item: MessageData = {
          id: msg.id,
          role: msg.role,
          content: msg.content,
          timestamp: msg.timestamp,
          isToolCall: msg.isToolCall,
          toolName: msg.toolName,
          toolInput: msg.toolInput,
          toolOutput: msg.toolOutput,
          imagePath: msg.imagePath,
          audioPath: msg.audioPath,
          userImagePath: msg.userImagePath,
          userImagePaths: msg.userImagePaths,
          videoPath: msg.videoPath,
          attachmentName: msg.attachmentName,
          replyToId: msg.replyToId,
          replyToContent: msg.replyToContent,
          replyToRole: msg.replyToRole
        };
        dataList.push(item);
      }
      
      await this.prefs.put(Constants.MESSAGES_PREFIX + sessionId, JSON.stringify(dataList));
      await this.prefs.flush();
      
      // Update session metadata
      const session = this.sessions.find(s => s.id === sessionId);
      if (session && messages.length > 0) {
        session.messageCount = messages.length;
        session.updatedAt = Date.now();
        const lastMsg = messages[messages.length - 1];
        session.lastMessage = lastMsg.content.substring(0, 50);
        await this.saveSessions();
      }
    } catch (err) {
      this.log.error('SessionService', `Save messages failed for ${sessionId}: ${err}`);
    }
  }

  // Clear messages for a specific session
  async clearMessages(sessionId: string): Promise<void> {
    if (!this.prefs) return;
    
    try {
      await this.prefs.delete(Constants.MESSAGES_PREFIX + sessionId);
      await this.prefs.flush();
      
      const session = this.sessions.find(s => s.id === sessionId);
      if (session) {
        session.messageCount = 0;
        session.lastMessage = '';
        session.updatedAt = Date.now();
        await this.saveSessions();
      }
    } catch (err) {
      this.log.error('SessionService', `Clear messages failed for ${sessionId}: ${err}`);
    }
  }

  // Save message queue for a session
  async saveMessageQueue(sessionId: string, queue: QueuedMessage[]): Promise<void> {
    if (!this.prefs) return;

    try {
      await this.prefs.put(Constants.QUEUE_PREFIX + sessionId, JSON.stringify(queue));
      await this.prefs.flush();
    } catch (err) {
      this.log.error('SessionService', `Save queue failed for ${sessionId}: ${err}`);
    }
  }

  // Load message queue for a session
  async loadMessageQueue(sessionId: string): Promise<QueuedMessage[]> {
    if (!this.prefs) return [];

    try {
      const json = await this.prefs.get(Constants.QUEUE_PREFIX + sessionId, '[]') as string;
      const items = JSON.parse(json) as object[];
      return items.map((item): QueuedMessage => {
        const d = item as Record<string, Object>;
        return {
          id: d['id'] as string || '',
          text: d['text'] as string || '',
          status: d['status'] as string || 'pending',
          timestamp: d['timestamp'] as number || Date.now(),
          sessionId: d['sessionId'] as string || sessionId
        } as QueuedMessage;
      });
    } catch (err) {
      this.log.error('SessionService', `Load queue failed for ${sessionId}: ${err}`);
      return [];
    }
  }

  // Clear message queue for a session
  async clearMessageQueue(sessionId: string): Promise<void> {
    if (!this.prefs) return;

    try {
      await this.prefs.delete(Constants.QUEUE_PREFIX + sessionId);
      await this.prefs.flush();
    } catch (err) {
      this.log.error('SessionService', `Clear queue failed for ${sessionId}: ${err}`);
    }
  }

  // Auto-close idle sessions (not active for idleTimeoutMs)
  // Excludes: current session, pinned sessions
  async closeIdleSessions(currentSessionId: string, idleTimeoutMs?: number): Promise<number> {
    const now = Date.now();
    const timeout = idleTimeoutMs ?? Constants.SESSION_IDLE_TIMEOUT_MS;
    const idleThreshold = now - timeout;
    let closedCount = 0;

    const sessionsToClose = this.sessions.filter(s => 
      !s.isClosed && 
      !s.isPinned && 
      s.id !== currentSessionId && 
      s.updatedAt < idleThreshold
    );

    for (const session of sessionsToClose) {
      session.isClosed = true;
      session.updatedAt = now;
      closedCount++;
      this.log.info('SessionService', `Auto-closed idle session: ${session.id} (idle for ${Math.round((now - session.updatedAt) / 60000)}min)`);
    }

    if (closedCount > 0) {
      await this.saveSessions();
      this.log.info('SessionService', `Auto-closed ${closedCount} idle sessions`);
    }

    return closedCount;
  }

  // Update session activity timestamp (call when user interacts with session)
  async touchSession(sessionId: string): Promise<void> {
    const session = this.sessions.find(s => s.id === sessionId);
    if (session) {
      session.updatedAt = Date.now();
      await this.saveSessions();
    }
  }
}
