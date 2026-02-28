// About page with system status and OTA update
import { router, promptAction } from '@kit.ArkUI';
import { hidebug } from '@kit.PerformanceAnalysisKit';
import { common, Want, bundleManager } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { request } from '@kit.BasicServicesKit';
import { fileIo } from '@kit.CoreFileKit';
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
  @State updateChecking: boolean = false;
  @State updateDownloading: boolean = false;
  @State updateProgress: number = 0;
  @State latestVersion: string = '';
  @State updateAvailable: boolean = false;
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

  private async checkForUpdates(): Promise<void> {
    this.updateChecking = true;
    this.updateAvailable = false;
    try {
      let httpRequest = http.createHttp();
      let response = await httpRequest.request(
        'https://api.github.com/repos/lhj1026/ClawdbotHarmony/releases/latest',
        { method: http.RequestMethod.GET, header: { 'Accept': 'application/vnd.github.v3+json' } }
      );
      if (response.responseCode === 200 && response.result) {
        let data = JSON.parse(response.result as string) as Record<string, Object>;
        let tagName = data['tag_name'] as string;
        this.latestVersion = tagName.startsWith('v') ? tagName.substring(1) : tagName;
        let bundleInfo = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
        let currentVersion = bundleInfo.versionName;
        if (this.compareVersions(this.latestVersion, currentVersion) > 0) {
          this.updateAvailable = true;
          promptAction.showToast({ message: `发现新版本 ${this.latestVersion}`, duration: 2000 });
        } else {
          promptAction.showToast({ message: '已是最新版本', duration: 1500 });
        }
      }
      httpRequest.destroy();
    } catch (e) {
      console.error(`[AboutPage] Check update failed: ${(e as Error).message ?? ''}`);
      promptAction.showToast({ message: '检查更新失败', duration: 1500 });
    }
    this.updateChecking = false;
  }

  private compareVersions(v1: string, v2: string): number {
    let parts1 = v1.split('.').map((s: string) => parseInt(s) || 0);
    let parts2 = v2.split('.').map((s: string) => parseInt(s) || 0);
    let maxLen = Math.max(parts1.length, parts2.length);
    for (let i = 0; i < maxLen; i++) {
      let p1 = i < parts1.length ? parts1[i] : 0;
      let p2 = i < parts2.length ? parts2[i] : 0;
      if (p1 > p2) return 1;
      if (p1 < p2) return -1;
    }
    return 0;
  }

  private async downloadAndInstallUpdate(): Promise<void> {
    this.updateDownloading = true;
    this.updateProgress = 0;
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let cacheDir = ctx.cacheDir;
      let fileName = `ClawdBot-${this.latestVersion}.hap`;
      let hapPath = `${cacheDir}/${fileName}`;

      let httpRequest = http.createHttp();
      let response = await httpRequest.request(
        'https://api.github.com/repos/lhj1026/ClawdbotHarmony/releases/latest',
        { method: http.RequestMethod.GET, header: { 'Accept': 'application/vnd.github.v3+json' } }
      );
      let downloadUrl = '';
      if (response.responseCode === 200 && response.result) {
        let data = JSON.parse(response.result as string) as Record<string, Object>;
        let assets = data['assets'] as Object[];
        if (assets && assets.length > 0) {
          let asset = assets[0] as Record<string, Object>;
          downloadUrl = asset['browser_download_url'] as string;
        }
      }
      httpRequest.destroy();

      if (downloadUrl.length === 0) {
        promptAction.showToast({ message: '未找到下载链接', duration: 1500 });
        this.updateDownloading = false;
        return;
      }

      try { fileIo.unlinkSync(hapPath); } catch { /* ignore */ }

      promptAction.showToast({ message: '开始下载...', duration: 1500 });
      let downloadConfig: request.DownloadConfig = {
        url: downloadUrl,
        filePath: hapPath,
        enableMetered: true,
        enableRoaming: true,
        title: 'ClawdBot 更新',
        description: `下载版本 ${this.latestVersion}`
      };

      let downloadTask = await request.downloadFile(ctx, downloadConfig);
      downloadTask.on('progress', (receivedSize: number, totalSize: number) => {
        if (totalSize > 0) {
          this.updateProgress = Math.floor(receivedSize * 100 / totalSize);
        }
      });
      downloadTask.on('complete', () => {
        this.updateProgress = 100;
        this.updateDownloading = false;
        promptAction.showToast({ message: '下载完成，正在安装...', duration: 2000 });
        setTimeout(() => { this.installHap(hapPath); }, 500);
      });
      downloadTask.on('fail', (err: number) => {
        this.updateDownloading = false;
        promptAction.showToast({ message: `下载失败 (错误码: ${err})`, duration: 2000 });
      });
    } catch (e) {
      this.updateDownloading = false;
      promptAction.showToast({ message: `下载失败: ${(e as Error).message ?? ''}`, duration: 2000 });
    }
  }

  private installHap(hapPath: string): void {
    // Copy HAP to Download directory so user can find it in file manager
    try {
      let ctx = getContext(this) as common.UIAbilityContext;
      let downloadDir = `${ctx.filesDir}/../cache`;
      console.info(`[AboutPage] HAP downloaded to: ${hapPath}`);

      // Try to open file manager at the cache directory
      let fileManagerWant: Want = {
        bundleName: 'com.huawei.hmos.filemanager',
        abilityName: 'MainAbility',
      };
      ctx.startAbility(fileManagerWant).then(() => {
        console.info('[AboutPage] File manager opened');
        promptAction.showToast({
          message: `v${this.latestVersion} 已下载，请在文件管理器中找到 ClawdBot-${this.latestVersion}.hap 点击安装`,
          duration: 5000
        });
      }).catch((err: Error) => {
        console.warn(`[AboutPage] Cannot open file manager: ${err.message}`);
        AlertDialog.show({
          title: `v${this.latestVersion} 下载完成`,
          message: `HAP 已下载到应用缓存目录。\n\n请用以下方式安装：\n\n1. 连接电脑，执行：\nhdc file recv ${hapPath} ./ClawdBot.hap\nhdc install -r ./ClawdBot.hap\n\n2. 或让 Linda 远程安装`,
          confirm: { value: '确定', action: () => {} }
        });
      });
    } catch (e) {
      AlertDialog.show({
        title: `v${this.latestVersion} 下载完成`,
        message: `HAP 已下载到应用缓存目录。\n\n连接电脑执行：\nhdc file recv ${hapPath} ./ClawdBot.hap\nhdc install -r ./ClawdBot.hap`,
        confirm: { value: '确定', action: () => {} }
      });
    }
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
            Divider().color('#F0F0F0')

            // Check for updates button
            Row() {
              Text(t('settings.checkUpdate'))
                .fontSize(14)
                .fontColor('#1A1A1A')
                .layoutWeight(1)

              if (this.updateChecking) {
                LoadingProgress().width(20).height(20).color('#D2691E')
              } else if (this.updateDownloading) {
                Row({ space: 8 }) {
                  Progress({ value: this.updateProgress, total: 100, type: ProgressType.Linear })
                    .width(80)
                    .height(4)
                  Text(`${this.updateProgress}%`)
                    .fontSize(12)
                    .fontColor('#999999')
                }
              } else if (this.updateAvailable) {
                Text(t('settings.newVersion').replace('{0}', this.latestVersion))
                  .fontSize(12)
                  .fontColor('#D2691E')
                  .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                  .backgroundColor('#FFF3E0')
                  .borderRadius(4)
                  .onClick(() => { this.downloadAndInstallUpdate(); })
              } else {
                Text('>')
                  .fontSize(14)
                  .fontColor('#CCCCCC')
              }
            }
            .width('100%')
            .height(44)
            .alignItems(VerticalAlign.Center)
            .onClick(() => {
              if (!this.updateChecking && !this.updateDownloading) {
                this.checkForUpdates();
              }
            })
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
