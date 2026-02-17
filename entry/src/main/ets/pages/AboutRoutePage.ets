// About page with system status
import { router } from '@kit.ArkUI';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { I18n, t } from '../common/I18n';
import { NodeRuntime } from '../service/gateway/NodeRuntime';
import { SessionService } from '../service/SessionService';
import { ChatSession } from '../model/Models';
import { APP_VERSION, CHANGELOG, ChangelogEntry, LATEST_VERSION } from '../generated/Changelog';

@Entry
@Component
struct AboutRoutePage {
  @State lang: string = 'zh';
  @State memoryUsage: string = '-';
  @State cpuUsage: string = '-';
  @State nativeHeap: string = '-';
  @State sessions: ChatSession[] = [];
  @State tokenUsage: string = '-';
  @State gatewayStatus: string = '-';
  @State expandedVersions: Set<string> = new Set([LATEST_VERSION]);
  private refreshTimer: number = -1;
  private sessionSvc: SessionService = SessionService.getInstance();

  aboutToAppear(): void {
    this.refreshStatus();
    // Refresh every 10 seconds (power optimization - was 3s)
    this.refreshTimer = setInterval(() => {
      this.refreshStatus();
    }, 10000);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer >= 0) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private refreshStatus(): void {
    // Gateway status
    let runtime = NodeRuntime.getInstance();
    if (runtime.isConnected) {
      this.gatewayStatus = t('chat.online');
    } else {
      this.gatewayStatus = t('chat.offline');
    }

    // Get sessions
    this.sessions = this.sessionSvc.getSessions();

    // Memory usage (PSS - Proportional Set Size)
    try {
      const pssBig = hidebug.getPss(); // KB (bigint)
      const pss = Number(pssBig);
      if (pss > 1024) {
        this.memoryUsage = `${(pss / 1024).toFixed(1)} MB`;
      } else {
        this.memoryUsage = `${pss} KB`;
      }
    } catch (e) {
      this.memoryUsage = '-';
    }

    // Native heap
    try {
      const heapSizeBig = hidebug.getNativeHeapAllocatedSize(); // bytes (bigint)
      const heapSize = Number(heapSizeBig);
      if (heapSize > 1024 * 1024) {
        this.nativeHeap = `${(heapSize / 1024 / 1024).toFixed(1)} MB`;
      } else if (heapSize > 1024) {
        this.nativeHeap = `${(heapSize / 1024).toFixed(0)} KB`;
      } else {
        this.nativeHeap = `${heapSize} B`;
      }
    } catch (e) {
      this.nativeHeap = '-';
    }

    // CPU usage (approximate based on CPU time)
    try {
      const cpuTime = hidebug.getCpuUsage(); // Returns CPU time ratio (0-1)
      this.cpuUsage = `${(cpuTime * 100).toFixed(1)}%`;
    } catch (e) {
      this.cpuUsage = '-';
    }
  }

  private formatDuration(ms: number): string {
    const seconds = Math.floor(ms / 1000);
    const minutes = Math.floor(seconds / 60);
    const hours = Math.floor(minutes / 60);
    const days = Math.floor(hours / 24);

    if (days > 0) {
      return this.lang === 'zh' ? `${days}天${hours % 24}小时` : `${days}d ${hours % 24}h`;
    } else if (hours > 0) {
      return this.lang === 'zh' ? `${hours}小时${minutes % 60}分钟` : `${hours}h ${minutes % 60}m`;
    } else if (minutes > 0) {
      return this.lang === 'zh' ? `${minutes}分钟` : `${minutes}m`;
    } else {
      return this.lang === 'zh' ? `${seconds}秒` : `${seconds}s`;
    }
  }

  private getSessionStatus(session: ChatSession): string {
    const isCurrent = session.id === this.sessionSvc.getCurrentSessionId();
    if (session.isActive) {
      return this.lang === 'zh' ? '🔄 处理中' : '🔄 Processing';
    } else if (isCurrent) {
      return this.lang === 'zh' ? '✅ 当前' : '✅ Current';
    } else if (session.isPinned) {
      return this.lang === 'zh' ? '📌 已置顶' : '📌 Pinned';
    } else {
      return this.lang === 'zh' ? '💤 空闲' : '💤 Idle';
    }
  }

  @Builder
  InfoRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontColor('#666666')
      Blank()
      Text(value)
        .fontSize(14)
        .fontColor('#333333')
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
  }

  @Builder
  SectionTitle(title: string) {
    Text(title)
      .fontSize(12)
      .fontWeight(FontWeight.Medium)
      .fontColor('#999999')
      .letterSpacing(1)
      .padding({ left: 4, top: 20, bottom: 8 })
      .width('100%')
  }

  @Builder
  SessionItem(session: ChatSession) {
    Column() {
      // Title row
      Row() {
        Text(session.title || '新对话')
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.getSessionStatus(session))
          .fontSize(12)
          .fontColor(session.isActive ? '#4CAF50' : '#999999')
      }
      .width('100%')

      // Details row
      Row() {
        Text(`${session.messageCount} ${this.lang === 'zh' ? '条消息' : 'messages'}`)
          .fontSize(12)
          .fontColor('#999999')
        Text(' · ')
          .fontSize(12)
          .fontColor('#CCCCCC')
        Text(this.formatDuration(Date.now() - session.createdAt))
          .fontSize(12)
          .fontColor('#999999')
        if (session.totalTokens > 0) {
          Text(' · ')
            .fontSize(12)
            .fontColor('#CCCCCC')
          Text(`${(session.totalTokens / 1000).toFixed(1)}k tokens`)
            .fontSize(12)
            .fontColor('#999999')
        }
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  @Builder
  ChangelogItem(entry: ChangelogEntry) {
    Column() {
      // Version header (clickable to expand/collapse)
      Row() {
        Text(`v${entry.version}`)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor('#333333')
        Text(entry.date)
          .fontSize(12)
          .fontColor('#999999')
          .margin({ left: 12 })
        Blank()
        Text(this.expandedVersions.has(entry.version) ? '▼' : '▶')
          .fontSize(12)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ top: 12, bottom: 12 })
      .onClick(() => {
        if (this.expandedVersions.has(entry.version)) {
          this.expandedVersions.delete(entry.version);
        } else {
          this.expandedVersions.add(entry.version);
        }
        this.expandedVersions = new Set(this.expandedVersions); // Trigger re-render
      })

      // Expanded content
      if (this.expandedVersions.has(entry.version)) {
        Column() {
          // Features
          if (entry.features.length > 0) {
            Text(this.lang === 'zh' ? '✨ 新功能' : '✨ New Features')
              .fontSize(12)
              .fontColor('#4CAF50')
              .fontWeight(FontWeight.Medium)
              .margin({ top: 4, bottom: 4 })
            ForEach(entry.features, (feature: string) => {
              Text(`• ${feature}`)
                .fontSize(13)
                .fontColor('#666666')
                .margin({ left: 8, top: 2, bottom: 2 })
                .width('100%')
            })
          }
          // Fixes
          if (entry.fixes.length > 0) {
            Text(this.lang === 'zh' ? '🐛 修复' : '🐛 Bug Fixes')
              .fontSize(12)
              .fontColor('#FF9800')
              .fontWeight(FontWeight.Medium)
              .margin({ top: 8, bottom: 4 })
            ForEach(entry.fixes, (fix: string) => {
              Text(`• ${fix}`)
                .fontSize(13)
                .fontColor('#666666')
                .margin({ left: 8, top: 2, bottom: 2 })
                .width('100%')
            })
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .padding({ bottom: 8 })
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      // Header
      Row() {
        Text('←')
          .fontSize(24)
          .fontColor('#333333')
          .onClick(() => {
            router.back();
          })

        Text(t('settings.about'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#333333')
          .margin({ left: 16 })

        Blank()
      }
      .width('100%')
      .height(56)
      .padding({ left: 16, right: 16 })
      .backgroundColor('#FFFFFF')

      Scroll() {
        Column() {
          // ========== About Section ==========
          this.SectionTitle(t('settings.about'))
          Column() {
            this.InfoRow(t('settings.app'), 'ClawdBot')
            Divider().color('#F0F0F0')
            this.InfoRow(t('settings.version'), APP_VERSION)
            Divider().color('#F0F0F0')
            this.InfoRow(t('settings.basedOn'), 'OpenClaw')
            Divider().color('#F0F0F0')
            this.InfoRow(t('settings.platform'), 'HarmonyOS NEXT')
          }
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ========== System Status Section ==========
          this.SectionTitle(t('settings.systemStatus'))
          Column() {
            this.InfoRow(t('settings.gatewayStatus'), this.gatewayStatus)
            Divider().color('#F0F0F0')
            this.InfoRow(this.lang === 'zh' ? 'CPU 使用率' : 'CPU Usage', this.cpuUsage)
            Divider().color('#F0F0F0')
            this.InfoRow(this.lang === 'zh' ? '内存占用 (PSS)' : 'Memory (PSS)', this.memoryUsage)
            Divider().color('#F0F0F0')
            this.InfoRow(this.lang === 'zh' ? 'Native 堆' : 'Native Heap', this.nativeHeap)
          }
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ========== Sessions Section ==========
          this.SectionTitle(this.lang === 'zh' ? `会话 (${this.sessions.length})` : `Sessions (${this.sessions.length})`)
          Column() {
            if (this.sessions.length === 0) {
              Text(this.lang === 'zh' ? '暂无会话' : 'No sessions')
                .fontSize(14)
                .fontColor('#999999')
                .padding({ top: 16, bottom: 16 })
            } else {
              ForEach(this.sessions, (session: ChatSession, index: number) => {
                this.SessionItem(session)
                if (index < this.sessions.length - 1) {
                  Divider().color('#F0F0F0')
                }
              })
            }
          }
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          // ========== Changelog Section (current version only) ==========
          this.SectionTitle(this.lang === 'zh' ? '本次更新' : 'What\'s New')
          Column() {
            if (CHANGELOG.length > 0) {
              this.ChangelogItem(CHANGELOG[0])
            }
          }
          .padding(16)
          .backgroundColor(Color.White)
          .borderRadius(12)

          // Footer
          Text('© 2026 OpenClaw')
            .fontSize(12)
            .fontColor('#CCCCCC')
            .margin({ top: 32, bottom: 32 })
        }
        .width('100%')
        .padding({ left: 16, right: 16 })
      }
      .layoutWeight(1)
      .backgroundColor('#F5F5F5')
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F5F5F5')
  }
}
