/**
 * SensorRecorder.ets — 传感器信号录制服务
 *
 * 录制所有 tray.put() 事件为 NDJSON 文件，用于调试回放和场景测试。
 * 格式: 每行一个 JSON 对象 (append-only, crash-safe)
 */
import { fileIo } from '@kit.CoreFileKit';
import { LogService } from '../../common/LogService';
import DataTray from './DataTray';
import { RecordingInfo, RecordingHeader, RecordingEvent, RecordingSnap, RecordingFooter } from './ContextModels';

const TAG = 'SensorRecorder';

/** Discriminator for NDJSON line parsing */
interface NdjsonLine {
  type: string;
}

export class SensorRecorder {
  private static instance: SensorRecorder;
  private log: LogService = LogService.getInstance();

  private recording: boolean = false;
  private currentId: string = '';
  private currentLabel: string = '';
  private startTime: number = 0;
  private eventCount: number = 0;
  private filePath: string = '';
  private fd: number = -1;
  private recordingsDir: string = '';

  // Write buffer: flush every 50 events or 5 seconds
  private buffer: string[] = [];
  private static readonly BUFFER_FLUSH_SIZE = 50;
  private static readonly BUFFER_FLUSH_INTERVAL_MS = 5000;
  private flushTimer: number = -1;

  // Snapshot keyframe interval
  private static readonly SNAPSHOT_INTERVAL_MS = 2 * 60 * 1000; // 2 minutes
  private lastSnapshotTime: number = 0;

  private constructor() {}

  static getInstance(): SensorRecorder {
    if (!SensorRecorder.instance) {
      SensorRecorder.instance = new SensorRecorder();
    }
    return SensorRecorder.instance;
  }

  /**
   * Initialize with app context file directory
   */
  init(filesDir: string): void {
    this.recordingsDir = filesDir + '/recordings';
    try {
      if (!fileIo.accessSync(this.recordingsDir)) {
        fileIo.mkdirSync(this.recordingsDir, true);
      }
    } catch (_e) {
      fileIo.mkdirSync(this.recordingsDir, true);
    }
    this.log.info(TAG, `Initialized, dir: ${this.recordingsDir}`);
  }

  isRecording(): boolean {
    return this.recording;
  }

  getRecordingDuration(): number {
    if (!this.recording) return 0;
    return Date.now() - this.startTime;
  }

  getEventCount(): number {
    return this.eventCount;
  }

  getCurrentId(): string {
    return this.currentId;
  }

  /**
   * Start recording sensor events
   */
  startRecording(label: string): RecordingInfo | null {
    if (this.recording) {
      this.log.warn(TAG, 'Already recording');
      return null;
    }

    let now = Date.now();
    this.currentId = `rec_${now}`;
    this.currentLabel = label;
    this.startTime = now;
    this.eventCount = 0;
    this.buffer = [];
    this.lastSnapshotTime = now;

    this.filePath = `${this.recordingsDir}/${this.currentId}.ndjson`;

    try {
      let file = fileIo.openSync(this.filePath, fileIo.OpenMode.CREATE | fileIo.OpenMode.WRITE_ONLY);
      this.fd = file.fd;
    } catch (err) {
      this.log.error(TAG, `Failed to create recording file: ${(err as Error).message}`);
      return null;
    }

    // Write header
    let header: RecordingHeader = {
      type: 'header',
      ver: 1,
      id: this.currentId,
      t0: now,
      label: label
    };
    this.writeLine(JSON.stringify(header));

    // Write initial snapshot
    this.writeSnapshot();

    // Start flush timer
    this.flushTimer = setInterval(() => {
      this.flushBuffer();
    }, SensorRecorder.BUFFER_FLUSH_INTERVAL_MS);

    this.recording = true;
    this.log.info(TAG, `Recording started: ${this.currentId} (${label})`);

    return {
      id: this.currentId,
      label: label,
      startTime: now,
      endTime: 0,
      eventCount: 0,
      durationMs: 0,
      filePath: this.filePath,
      fileSize: 0
    };
  }

  /**
   * Stop recording and finalize the file
   */
  stopRecording(): RecordingInfo | null {
    if (!this.recording) return null;

    let now = Date.now();
    let duration = now - this.startTime;

    // Flush remaining buffer
    this.flushBuffer();

    // Write footer
    let footer: RecordingFooter = {
      type: 'footer',
      t1: now,
      n: this.eventCount,
      dur: duration
    };
    this.writeLine(JSON.stringify(footer));

    // Stop flush timer
    if (this.flushTimer !== -1) {
      clearInterval(this.flushTimer);
      this.flushTimer = -1;
    }

    // Close file
    try {
      fileIo.closeSync(this.fd);
    } catch (err) {
      this.log.warn(TAG, `Close error: ${(err as Error).message}`);
    }

    let fileSize = 0;
    try {
      let stat = fileIo.statSync(this.filePath);
      fileSize = stat.size;
    } catch (_e) { /* ignore */ }

    let info: RecordingInfo = {
      id: this.currentId,
      label: this.currentLabel,
      startTime: this.startTime,
      endTime: now,
      eventCount: this.eventCount,
      durationMs: duration,
      filePath: this.filePath,
      fileSize: fileSize
    };

    this.recording = false;
    this.fd = -1;
    this.log.info(TAG, `Recording stopped: ${this.currentId}, events=${this.eventCount}, dur=${duration}ms`);

    return info;
  }

  /**
   * Record a single tray.put event (called from CAS.recordedPut)
   */
  recordEvent(key: string, value: string, quality: number, source: string): void {
    if (!this.recording) return;

    let now = Date.now();
    let event: RecordingEvent = {
      type: 'event',
      t: now,
      k: key,
      v: value,
      q: quality,
      s: source
    };

    this.buffer.push(JSON.stringify(event));
    this.eventCount++;

    // Flush if buffer full
    if (this.buffer.length >= SensorRecorder.BUFFER_FLUSH_SIZE) {
      this.flushBuffer();
    }

    // Periodic snapshot keyframe
    if (now - this.lastSnapshotTime >= SensorRecorder.SNAPSHOT_INTERVAL_MS) {
      this.writeSnapshot();
      this.lastSnapshotTime = now;
    }
  }

  /**
   * List all recordings
   */
  listRecordings(): RecordingInfo[] {
    let results: RecordingInfo[] = [];
    try {
      let files = fileIo.listFileSync(this.recordingsDir);
      for (let fname of files) {
        if (!fname.endsWith('.ndjson')) continue;
        let path = `${this.recordingsDir}/${fname}`;
        try {
          let info = this.parseRecordingMeta(path);
          if (info) results.push(info);
        } catch (_e) { /* skip corrupt files */ }
      }
    } catch (_e) { /* dir may not exist */ }

    // Sort by start time descending (newest first)
    results.sort((a, b) => b.startTime - a.startTime);
    return results;
  }

  /**
   * Delete a recording
   */
  deleteRecording(id: string): boolean {
    let path = `${this.recordingsDir}/${id}.ndjson`;
    try {
      fileIo.unlinkSync(path);
      this.log.info(TAG, `Deleted recording: ${id}`);
      return true;
    } catch (err) {
      this.log.warn(TAG, `Delete failed: ${(err as Error).message}`);
      return false;
    }
  }

  /**
   * Export a recording as a JS test fixture (array of events)
   */
  exportAsTestFixture(id: string): string {
    let path = `${this.recordingsDir}/${id}.ndjson`;
    try {
      let content = fileIo.readTextSync(path);
      let lines = content.split('\n').filter((l: string) => l.trim().length > 0);
      let events: RecordingEvent[] = [];
      let snapshots: RecordingSnap[] = [];

      for (let line of lines) {
        try {
          let obj = JSON.parse(line) as NdjsonLine;
          if (obj.type === 'event') {
            events.push(JSON.parse(line) as RecordingEvent);
          } else if (obj.type === 'snap') {
            snapshots.push(JSON.parse(line) as RecordingSnap);
          }
        } catch (_e) { /* skip bad lines */ }
      }

      return JSON.stringify({ events, snapshots }, null, 2);
    } catch (err) {
      this.log.error(TAG, `Export failed: ${(err as Error).message}`);
      return '{}';
    }
  }

  /**
   * Read a recording file and return raw NDJSON lines (non-empty)
   */
  readRecordingLines(id: string): string[] {
    let path = `${this.recordingsDir}/${id}.ndjson`;
    try {
      let content = fileIo.readTextSync(path);
      return content.split('\n').filter((l: string) => l.trim().length > 0);
    } catch (err) {
      this.log.error(TAG, `Read failed: ${(err as Error).message}`);
      return [];
    }
  }

  // ==================== Private helpers ====================

  private writeLine(line: string): void {
    if (this.fd < 0) return;
    try {
      let data = line + '\n';
      fileIo.writeSync(this.fd, data);
    } catch (err) {
      this.log.error(TAG, `Write error: ${(err as Error).message}`);
    }
  }

  private flushBuffer(): void {
    if (this.buffer.length === 0 || this.fd < 0) return;
    try {
      let data = this.buffer.join('\n') + '\n';
      fileIo.writeSync(this.fd, data);
      this.buffer = [];
    } catch (err) {
      this.log.error(TAG, `Flush error: ${(err as Error).message}`);
    }
  }

  private writeSnapshot(): void {
    let snapshot = DataTray.getSnapshot();
    // Convert ContextSnapshot (named interface) to plain Record via JSON round-trip
    let snapData: Record<string, string> = JSON.parse(JSON.stringify(snapshot)) as Record<string, string>;
    let snap: RecordingSnap = {
      type: 'snap',
      t: Date.now(),
      d: snapData
    };
    // Snapshots bypass buffer (keyframes must be on disk)
    this.flushBuffer();
    this.writeLine(JSON.stringify(snap));
  }

  /**
   * Parse header and footer from an NDJSON file to build RecordingInfo
   */
  private parseRecordingMeta(path: string): RecordingInfo | null {
    try {
      let content = fileIo.readTextSync(path);
      let lines = content.split('\n');

      let header: RecordingHeader | null = null;
      let footer: RecordingFooter | null = null;
      let eventCount = 0;

      // Read first line for header
      if (lines.length > 0 && lines[0].trim().length > 0) {
        let first = JSON.parse(lines[0]) as NdjsonLine;
        if (first.type === 'header') {
          header = JSON.parse(lines[0]) as RecordingHeader;
        }
      }

      // Read last non-empty line for footer, count events
      for (let i = lines.length - 1; i >= 0; i--) {
        let line = lines[i].trim();
        if (line.length === 0) continue;
        try {
          let obj = JSON.parse(line) as NdjsonLine;
          if (obj.type === 'footer' && !footer) {
            footer = JSON.parse(line) as RecordingFooter;
          }
        } catch (_e) { /* ignore */ }
        break;
      }

      // Count events
      for (let line of lines) {
        if (line.includes('"type":"event"')) eventCount++;
      }

      if (!header) return null;

      let stat = fileIo.statSync(path);

      return {
        id: header.id,
        label: header.label,
        startTime: header.t0,
        endTime: footer ? footer.t1 : 0,
        eventCount: footer ? footer.n : eventCount,
        durationMs: footer ? footer.dur : (Date.now() - header.t0),
        filePath: path,
        fileSize: stat.size
      };
    } catch (_e) {
      return null;
    }
  }
}
