/**
 * SensorPlayer.ets — 传感器信号回放服务
 *
 * 加载 SensorRecorder 生成的 NDJSON 文件，按倍速回放注入 DataTray。
 * 回放时 source 标记为 "xxx:replay" 以区分真实数据。
 */
import { LogService } from '../../common/LogService';
import DataTray from './DataTray';
import { SensorRecorder } from './SensorRecorder';
import { RecordingEvent, RecordingSnap, RecordingHeader, ReplayProgress } from './ContextModels';

const TAG = 'SensorPlayer';

/** Discriminator for NDJSON line parsing */
interface NdjsonLine {
  type: string;
}

export type ReplayState = 'idle' | 'playing' | 'paused' | 'finished';

export class SensorPlayer {
  private static instance: SensorPlayer;
  private log: LogService = LogService.getInstance();

  private state: ReplayState = 'idle';
  private speed: number = 1;     // 1x, 2x, 5x, 10x, 0=instant
  private events: RecordingEvent[] = [];
  private snapshots: RecordingSnap[] = [];
  private header: RecordingHeader | null = null;

  // Playback state
  private currentIndex: number = 0;
  private playbackTimer: number = -1;
  private playbackStartTime: number = 0;       // Real wall clock when play started
  private playbackStartOffset: number = 0;     // Recording time offset when play started
  private recordingBaseTime: number = 0;       // t0 from recording header
  private totalEvents: number = 0;

  // Listener for progress updates
  private progressListener: ((progress: ReplayProgress) => void) | null = null;

  private constructor() {}

  static getInstance(): SensorPlayer {
    if (!SensorPlayer.instance) {
      SensorPlayer.instance = new SensorPlayer();
    }
    return SensorPlayer.instance;
  }

  /**
   * Load a recording for replay
   */
  loadRecording(sessionId: string): boolean {
    if (this.state === 'playing') {
      this.stop();
    }

    let recorder = SensorRecorder.getInstance();
    let rawLines = recorder.readRecordingLines(sessionId);

    this.events = [];
    this.snapshots = [];
    this.header = null;

    for (let line of rawLines) {
      try {
        let disc = JSON.parse(line) as NdjsonLine;
        if (disc.type === 'header') {
          this.header = JSON.parse(line) as RecordingHeader;
        } else if (disc.type === 'event') {
          this.events.push(JSON.parse(line) as RecordingEvent);
        } else if (disc.type === 'snap') {
          this.snapshots.push(JSON.parse(line) as RecordingSnap);
        }
      } catch (_e) { /* skip malformed lines */ }
    }

    if (!this.header || this.events.length === 0) {
      this.log.warn(TAG, `Failed to load recording ${sessionId}: no header or events`);
      return false;
    }

    // Sort events by timestamp
    this.events.sort((a, b) => a.t - b.t);
    this.totalEvents = this.events.length;
    this.recordingBaseTime = this.header.t0;
    this.currentIndex = 0;
    this.state = 'idle';

    this.log.info(TAG, `Loaded recording ${sessionId}: ${this.totalEvents} events, ` +
      `${this.snapshots.length} snapshots`);
    return true;
  }

  /**
   * Start or resume playback
   * @param speed Playback speed: 1, 2, 5, 10, or 0 for instant
   */
  play(speed: number = 1): void {
    if (this.events.length === 0) {
      this.log.warn(TAG, 'No recording loaded');
      return;
    }

    this.speed = speed;

    if (this.state === 'paused') {
      // Resume from pause
      this.playbackStartTime = Date.now();
      if (this.currentIndex < this.totalEvents) {
        this.playbackStartOffset = this.events[this.currentIndex].t - this.recordingBaseTime;
      }
    } else {
      // Start fresh
      this.currentIndex = 0;
      this.playbackStartTime = Date.now();
      this.playbackStartOffset = 0;

      // Inject initial snapshot if available
      if (this.snapshots.length > 0) {
        this.injectSnapshot(this.snapshots[0]);
      }
    }

    this.state = 'playing';

    if (speed === 0) {
      // Instant mode: inject all events immediately
      this.playAllInstant();
    } else {
      this.scheduleNextEvent();
    }
  }

  pause(): void {
    if (this.state !== 'playing') return;
    this.state = 'paused';
    if (this.playbackTimer !== -1) {
      clearTimeout(this.playbackTimer);
      this.playbackTimer = -1;
    }
    this.notifyProgress();
  }

  resume(): void {
    if (this.state !== 'paused') return;
    this.play(this.speed);
  }

  stop(): void {
    if (this.playbackTimer !== -1) {
      clearTimeout(this.playbackTimer);
      this.playbackTimer = -1;
    }
    this.state = 'idle';
    this.currentIndex = 0;
    this.notifyProgress();
  }

  /**
   * Seek to a specific timestamp in the recording
   */
  seekTo(timestamp: number): void {
    let wasPlaying = this.state === 'playing';

    if (wasPlaying) {
      this.pause();
    }

    // Find the nearest snapshot before the target timestamp
    let bestSnap: RecordingSnap | null = null;
    for (let snap of this.snapshots) {
      if (snap.t <= timestamp) {
        bestSnap = snap;
      } else {
        break;
      }
    }

    // Inject the snapshot state
    if (bestSnap) {
      this.injectSnapshot(bestSnap);
    }

    // Find the event index at or after the target timestamp
    this.currentIndex = 0;
    for (let i = 0; i < this.events.length; i++) {
      if (this.events[i].t >= timestamp) {
        this.currentIndex = i;
        break;
      }
      if (i === this.events.length - 1) {
        this.currentIndex = this.events.length;
      }
    }

    // Replay events between snapshot and target time to build up state
    if (bestSnap) {
      let snapIdx = 0;
      for (let i = 0; i < this.events.length; i++) {
        if (this.events[i].t >= bestSnap.t) {
          snapIdx = i;
          break;
        }
      }
      for (let i = snapIdx; i < this.currentIndex; i++) {
        this.injectEvent(this.events[i]);
      }
    }

    this.playbackStartOffset = timestamp - this.recordingBaseTime;

    if (wasPlaying) {
      this.play(this.speed);
    } else {
      this.notifyProgress();
    }
  }

  getProgress(): ReplayProgress {
    let currentTime = this.recordingBaseTime;
    if (this.currentIndex > 0 && this.currentIndex <= this.totalEvents) {
      currentTime = this.events[Math.min(this.currentIndex, this.totalEvents - 1)].t;
    }

    return {
      state: this.state,
      progress: this.totalEvents > 0 ? this.currentIndex / this.totalEvents : 0,
      eventsPlayed: this.currentIndex,
      totalEvents: this.totalEvents,
      speed: this.speed,
      currentTime: currentTime
    };
  }

  setProgressListener(listener: ((progress: ReplayProgress) => void) | null): void {
    this.progressListener = listener;
  }

  getState(): ReplayState {
    return this.state;
  }

  /** 获取录制的起止时间戳，用于 seek 计算 */
  getRecordingTimeRange(): [number, number] {
    if (this.events.length === 0) return [0, 0];
    return [this.recordingBaseTime, this.events[this.events.length - 1].t];
  }

  // ==================== Private helpers ====================

  private scheduleNextEvent(): void {
    if (this.state !== 'playing' || this.currentIndex >= this.totalEvents) {
      if (this.currentIndex >= this.totalEvents) {
        this.state = 'finished';
        this.log.info(TAG, 'Playback finished');
      }
      this.notifyProgress();
      return;
    }

    let event = this.events[this.currentIndex];
    let eventOffsetMs = event.t - this.recordingBaseTime;
    let targetWallTime = this.playbackStartTime +
      (eventOffsetMs - this.playbackStartOffset) / this.speed;
    let delayMs = Math.max(0, targetWallTime - Date.now());

    this.playbackTimer = setTimeout(() => {
      this.playbackTimer = -1;
      if (this.state !== 'playing') return;

      this.injectEvent(event);
      this.currentIndex++;

      // Notify progress every 10 events or at milestones
      if (this.currentIndex % 10 === 0 || this.currentIndex === this.totalEvents) {
        this.notifyProgress();
      }

      this.scheduleNextEvent();
    }, delayMs);
  }

  private playAllInstant(): void {
    for (let i = this.currentIndex; i < this.totalEvents; i++) {
      this.injectEvent(this.events[i]);
    }
    this.currentIndex = this.totalEvents;
    this.state = 'finished';
    this.log.info(TAG, 'Instant playback finished');
    this.notifyProgress();
  }

  private injectEvent(event: RecordingEvent): void {
    // Mark source as replay
    let replaySource = event.s + ':replay';
    DataTray.put(event.k, event.v, event.q, replaySource);
  }

  private injectSnapshot(snap: RecordingSnap): void {
    let keys = Object.keys(snap.d);
    for (let key of keys) {
      DataTray.put(key, snap.d[key], 1.0, 'snapshot:replay');
    }
  }

  private notifyProgress(): void {
    if (this.progressListener) {
      this.progressListener(this.getProgress());
    }
  }
}
