/**
 * In-memory log service for runtime debugging.
 * Stores log entries that can be viewed in the LogPage.
 * Also outputs to console.info/warn/error for HiLog capture.
 */

export class LogEntry {
  timestamp: number = 0;
  level: string = 'INFO';
  tag: string = '';
  message: string = '';

  constructor(level: string, tag: string, message: string) {
    this.timestamp = Date.now();
    this.level = level;
    this.tag = tag;
    this.message = message;
  }

  format(): string {
    let d = new Date(this.timestamp);
    let h = d.getHours().toString().padStart(2, '0');
    let m = d.getMinutes().toString().padStart(2, '0');
    let s = d.getSeconds().toString().padStart(2, '0');
    let ms = d.getMilliseconds().toString().padStart(3, '0');
    return `${h}:${m}:${s}.${ms} [${this.level}] ${this.tag}: ${this.message}`;
  }
}

const MAX_LOG_ENTRIES = 500;

export class LogService {
  private static instance: LogService | undefined = undefined;
  private entries: LogEntry[] = [];
  private listeners: Array<() => void> = [];

  static getInstance(): LogService {
    if (!LogService.instance) {
      LogService.instance = new LogService();
    }
    return LogService.instance;
  }

  info(tag: string, message: string): void {
    this.add('INFO', tag, message);
    console.info(`[${tag}] ${message}`);
  }

  warn(tag: string, message: string): void {
    this.add('WARN', tag, message);
    console.warn(`[${tag}] ${message}`);
  }

  error(tag: string, message: string): void {
    this.add('ERROR', tag, message);
    console.error(`[${tag}] ${message}`);
  }

  debug(tag: string, message: string): void {
    this.add('DEBUG', tag, message);
    console.debug(`[${tag}] ${message}`);
  }

  getAll(): LogEntry[] {
    return this.entries.slice();
  }

  getFiltered(level?: string, tag?: string): LogEntry[] {
    let result = this.entries;
    if (level && level !== 'ALL') {
      result = result.filter((e): boolean => e.level === level);
    }
    if (tag && tag.length > 0) {
      result = result.filter((e): boolean => e.tag.indexOf(tag) >= 0);
    }
    return result;
  }

  clear(): void {
    this.entries = [];
    this.notifyListeners();
  }

  addListener(fn: () => void): void {
    this.listeners.push(fn);
  }

  removeListener(fn: () => void): void {
    let idx = this.listeners.indexOf(fn);
    if (idx >= 0) {
      this.listeners.splice(idx, 1);
    }
  }

  get count(): number {
    return this.entries.length;
  }

  private add(level: string, tag: string, message: string): void {
    let entry = new LogEntry(level, tag, message);
    this.entries.push(entry);
    if (this.entries.length > MAX_LOG_ENTRIES) {
      this.entries = this.entries.slice(this.entries.length - MAX_LOG_ENTRIES);
    }
    this.notifyListeners();
  }

  private notifyListeners(): void {
    for (let listener of this.listeners) {
      try { listener(); } catch { /* ignore */ }
    }
  }
}

/** Convenience shortcut */
export const Log = LogService.getInstance();
