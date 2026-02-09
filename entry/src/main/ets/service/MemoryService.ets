import { preferences } from '@kit.ArkData';
import { MemoryItem, MemoryData } from '../model/Models';
import { Constants } from '../common/Constants';

/**
 * Persistent memory service.
 * Stores facts, preferences, and instructions across sessions.
 * Memory is injected into the system prompt for personalisation.
 */
export class MemoryService {
  private static instance: MemoryService | undefined = undefined;

  static getInstance(): MemoryService {
    if (!MemoryService.instance) {
      MemoryService.instance = new MemoryService();
    }
    return MemoryService.instance;
  }

  // ---------- public API ----------

  async loadAll(context: Context): Promise<MemoryItem[]> {
    let store = await preferences.getPreferences(context, Constants.PREFS_MEMORY);
    let raw = await store.get('entries', '[]') as string;
    let arr: MemoryData[] = JSON.parse(raw) as MemoryData[];
    let items: MemoryItem[] = [];
    for (let d of arr) {
      let item = new MemoryItem(d.memType, d.content, d.importance);
      item.id = d.id;
      item.createdAt = d.createdAt;
      items.push(item);
    }
    return items;
  }

  async save(context: Context, items: MemoryItem[]): Promise<void> {
    let store = await preferences.getPreferences(context, Constants.PREFS_MEMORY);
    let arr: MemoryData[] = items.map((m): MemoryData => ({
      id: m.id,
      memType: m.memType,
      content: m.content,
      importance: m.importance,
      createdAt: m.createdAt
    }));
    await store.put('entries', JSON.stringify(arr));
    await store.flush();
  }

  async add(context: Context, memType: string, content: string,
    importance: number = 0.5): Promise<MemoryItem> {
    let items = await this.loadAll(context);
    let item = new MemoryItem(memType, content, importance);
    items.push(item);
    await this.save(context, items);
    return item;
  }

  async remove(context: Context, id: string): Promise<void> {
    let items = await this.loadAll(context);
    let filtered = items.filter((m): boolean => m.id !== id);
    await this.save(context, filtered);
  }

  async clearAll(context: Context): Promise<void> {
    await this.save(context, []);
  }

  /**
   * Build the memory block that gets injected into the system prompt.
   */
  buildPromptBlock(items: MemoryItem[]): string {
    if (items.length === 0) return '';
    let facts = items.filter((m): boolean => m.memType === 'fact');
    let prefs = items.filter((m): boolean => m.memType === 'preference');
    let instr = items.filter((m): boolean => m.memType === 'instruction');
    let parts: string[] = [];
    if (facts.length > 0) {
      parts.push('## Facts\n' + facts.map((f): string => '- ' + f.content).join('\n'));
    }
    if (prefs.length > 0) {
      parts.push('## Preferences\n' + prefs.map((p): string => '- ' + p.content).join('\n'));
    }
    if (instr.length > 0) {
      parts.push('## Instructions\n' + instr.map((i): string => '- ' + i.content).join('\n'));
    }
    return '<memory>\n' + parts.join('\n\n') + '\n</memory>';
  }

  /**
   * Auto-detect memorable info from user text.
   */
  async autoExtract(context: Context, userText: string): Promise<void> {
    let lower = userText.toLowerCase();
    let regexes: RegExp[] = [
      /(?:remember|note)\s+(?:that\s+)?(.{5,})/i,
      /(?:i prefer|i like|i always)\s+(.{5,})/i,
      /(?:always|never|make sure)\s+(.{5,})/i,
      /(?:my name is|i'm called)\s+(\S.{1,40})/i,
    ];
    let types: string[] = ['fact', 'preference', 'instruction', 'fact'];
    for (let i = 0; i < regexes.length; i++) {
      let re: RegExp = regexes[i];
      let type: string = types[i];
      let match = lower.match(re);
      if (match && match[1]) {
        await this.add(context, type, match[1].trim(), 0.8);
      }
    }
  }
}
