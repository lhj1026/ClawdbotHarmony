import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { ChatMessage, ConversationFile } from '../model/Models';
import { LogService } from '../common/LogService';

/**
 * Conversation logger service.
 * Saves chat conversations as markdown files for persistent history.
 * Directory: ctx.filesDir + '/conversations/'
 * Filename: chat_YYYY-MM-DD_HHmmss.md
 */
export class ConversationLogger {
  private static instance: ConversationLogger | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private readonly TAG = 'ConversationLogger';

  static getInstance(): ConversationLogger {
    if (!ConversationLogger.instance) {
      ConversationLogger.instance = new ConversationLogger();
    }
    return ConversationLogger.instance;
  }

  /**
   * Save the current conversation as a markdown file.
   * Returns the file path of the saved conversation.
   */
  async saveConversation(context: Context, messages: ChatMessage[]): Promise<string> {
    if (messages.length === 0) return '';

    let convDir = context.filesDir + '/conversations';
    try { fileIo.mkdirSync(convDir); } catch { /* may already exist */ }

    let now = new Date();
    let dateStr = `${now.getFullYear()}-${(now.getMonth()+1).toString().padStart(2,'0')}-${now.getDate().toString().padStart(2,'0')}`;
    let timeStr = `${now.getHours().toString().padStart(2,'0')}${now.getMinutes().toString().padStart(2,'0')}${now.getSeconds().toString().padStart(2,'0')}`;
    let filename = `chat_${dateStr}_${timeStr}.md`;
    let filePath = convDir + '/' + filename;

    let headerDate = `${dateStr} ${now.getHours().toString().padStart(2,'0')}:${now.getMinutes().toString().padStart(2,'0')}`;
    let lines: string[] = [];
    lines.push(`# Conversation ${headerDate}`);
    lines.push('');

    for (let msg of messages) {
      lines.push('---');
      lines.push('');

      let msgTime = new Date(msg.timestamp);
      let msgTimeStr = `${msgTime.getHours().toString().padStart(2,'0')}:${msgTime.getMinutes().toString().padStart(2,'0')}`;

      if (msg.role === 'user') {
        lines.push(`**User** (${msgTimeStr})`);
        lines.push(msg.content);
      } else if (msg.role === 'assistant') {
        if (msg.isToolCall) {
          lines.push(`**ClawdBot** (${msgTimeStr})`);
          lines.push('');
          lines.push(`> Tool: ${msg.toolName}`);
          if (msg.toolInput.length > 0) {
            lines.push(`> Input: ${msg.toolInput.substring(0, 200)}`);
          }
        } else {
          lines.push(`**ClawdBot** (${msgTimeStr})`);
          lines.push(msg.content);
        }
      } else if (msg.role === 'tool') {
        // Tool result - show as blockquote
        let output = msg.toolOutput.length > 0 ? msg.toolOutput : msg.content;
        if (output.length > 500) {
          output = output.substring(0, 500) + '...[truncated]';
        }
        lines.push(`> Result (${msg.toolName}):`);
        lines.push(`> ${output.replace(/\n/g, '\n> ')}`);
      }
      lines.push('');
    }

    let content = lines.join('\n');
    let encoder = new util.TextEncoder();
    let encoded = encoder.encodeInto(content);
    let file = fileIo.openSync(filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY | fileIo.OpenMode.TRUNC);
    fileIo.writeSync(file.fd, encoded.buffer);
    fileIo.closeSync(file);

    this.log.info(this.TAG, `Conversation saved: ${filename} (${messages.length} messages, ${content.length} bytes)`);
    return filePath;
  }

  /**
   * List all saved conversation files, sorted by newest first.
   */
  async listConversations(context: Context): Promise<ConversationFile[]> {
    let convDir = context.filesDir + '/conversations';
    let files: ConversationFile[] = [];
    try {
      let entries = fileIo.listFileSync(convDir);
      for (let entry of entries) {
        if (!entry.endsWith('.md')) continue;
        let fullPath = convDir + '/' + entry;
        try {
          let stat = fileIo.statSync(fullPath);
          // Parse message count from filename or estimate from size
          let msgCount = Math.max(1, Math.floor(stat.size / 200));
          let cf: ConversationFile = {
            filename: entry,
            timestamp: stat.mtime,
            messageCount: msgCount
          };
          files.push(cf);
        } catch { /* skip unreadable */ }
      }
      // Sort newest first
      files.sort((a: ConversationFile, b: ConversationFile): number => b.timestamp - a.timestamp);
    } catch {
      // Directory may not exist yet
    }
    return files;
  }

  /**
   * Read the content of a saved conversation file.
   */
  async readConversation(context: Context, filename: string): Promise<string> {
    let filePath = context.filesDir + '/conversations/' + filename;
    try {
      let stat = fileIo.statSync(filePath);
      let file = fileIo.openSync(filePath, fileIo.OpenMode.READ_ONLY);
      let buf = new ArrayBuffer(stat.size);
      fileIo.readSync(file.fd, buf);
      fileIo.closeSync(file);
      let decoder = util.TextDecoder.create('utf-8');
      return decoder.decodeWithStream(new Uint8Array(buf));
    } catch (e) {
      this.log.warn(this.TAG, `Failed to read conversation: ${(e as Error).message ?? String(e)}`);
      return '';
    }
  }
}
