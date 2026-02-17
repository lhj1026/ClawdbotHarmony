// Persistence service for silent mode conversation records
import { preferences } from '@kit.ArkData';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { SilentConversationRecord, SilentConversationEntry } from '../model/Models';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';

const RECORDS_KEY = 'silent_records';

export class ConversationStore {
  private static instance: ConversationStore;
  private prefs: preferences.Preferences | undefined;
  private log: LogService = LogService.getInstance();
  private initialized: boolean = false;

  private constructor() {}

  static getInstance(): ConversationStore {
    if (!ConversationStore.instance) {
      ConversationStore.instance = new ConversationStore();
    }
    return ConversationStore.instance;
  }

  async init(context: Context): Promise<void> {
    if (this.initialized) return;
    try {
      this.prefs = await preferences.getPreferences(context, Constants.PREFS_SILENT_MODE);
      this.initialized = true;
      this.log.info('ConversationStore', 'Initialized');
    } catch (err) {
      this.log.error('ConversationStore', `Init failed: ${err}`);
    }
  }

  async saveRecord(record: SilentConversationRecord): Promise<void> {
    if (!this.prefs) return;
    try {
      let records = await this.loadAll();
      let idx = records.findIndex((r: SilentConversationRecord) => r.id === record.id);
      if (idx >= 0) {
        records[idx] = record;
      } else {
        records.unshift(record);
      }
      await this.prefs.put(RECORDS_KEY, JSON.stringify(records));
      await this.prefs.flush();
    } catch (err) {
      this.log.error('ConversationStore', `Save failed: ${err}`);
    }
  }

  async listRecords(): Promise<SilentConversationRecord[]> {
    let records = await this.loadAll();
    // Sort newest first
    records.sort((a: SilentConversationRecord, b: SilentConversationRecord) => b.startTime - a.startTime);
    return records;
  }

  async getRecord(id: string): Promise<SilentConversationRecord | undefined> {
    let records = await this.loadAll();
    return records.find((r: SilentConversationRecord) => r.id === id);
  }

  async deleteRecord(id: string): Promise<void> {
    if (!this.prefs) return;
    try {
      let records = await this.loadAll();
      records = records.filter((r: SilentConversationRecord) => r.id !== id);
      await this.prefs.put(RECORDS_KEY, JSON.stringify(records));
      await this.prefs.flush();
    } catch (err) {
      this.log.error('ConversationStore', `Delete failed: ${err}`);
    }
  }

  async saveAsMarkdown(context: Context, record: SilentConversationRecord): Promise<string> {
    try {
      let dir = context.filesDir + '/silent_conversations';
      try {
        fileIo.mkdirSync(dir);
      } catch { /* already exists */ }

      let d = new Date(record.startTime);
      let dateStr = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
      let timeStr = `${String(d.getHours()).padStart(2, '0')}${String(d.getMinutes()).padStart(2, '0')}${String(d.getSeconds()).padStart(2, '0')}`;
      let filename = `silent_${dateStr}_${timeStr}.md`;
      let filepath = `${dir}/${filename}`;

      let lines: string[] = [];
      lines.push(`# Silent Conversation ${dateStr} ${timeStr.substring(0, 2)}:${timeStr.substring(2, 4)}`);
      lines.push('');
      if (record.participants.length > 0) {
        lines.push(`**Participants:** ${record.participants.join(', ')}`);
        lines.push('');
      }
      if (record.summary) {
        lines.push(`## Summary`);
        lines.push(record.summary);
        lines.push('');
      }
      lines.push(`## Transcript`);
      lines.push('');
      for (let entry of record.entries) {
        let t = new Date(entry.timestamp);
        let ts = `${String(t.getHours()).padStart(2, '0')}:${String(t.getMinutes()).padStart(2, '0')}:${String(t.getSeconds()).padStart(2, '0')}`;
        lines.push(`**${entry.speaker}** (${ts})`);
        lines.push(entry.text);
        lines.push('');
      }

      let content = lines.join('\n');
      let encoder = new util.TextEncoder();
      let buf = encoder.encodeInto(content);
      let file = fileIo.openSync(filepath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      fileIo.writeSync(file.fd, buf.buffer);
      fileIo.closeSync(file);

      this.log.info('ConversationStore', `Saved markdown: ${filename}`);
      return filepath;
    } catch (err) {
      this.log.error('ConversationStore', `Markdown save failed: ${err}`);
      return '';
    }
  }

  private async loadAll(): Promise<SilentConversationRecord[]> {
    if (!this.prefs) return [];
    try {
      let json = await this.prefs.get(RECORDS_KEY, '[]') as string;
      return JSON.parse(json) as SilentConversationRecord[];
    } catch {
      return [];
    }
  }
}
