/**
 * DailyTimelinePage — 每日行程时间线独立页面
 *
 * 两种模式:
 *   1. 时间线模式: 竖向时间线, 左=时间, 中=地点, 右=事件
 *   2. 地图模式: Web组件 + Leaflet/OSM 真实地图
 */
import { router } from '@kit.ArkUI';
import { webview } from '@kit.ArkWeb';
import { I18n } from '../common/I18n';
import { DailyTimelineService } from '../service/context/DailyTimelineService';
import { TimelineEntry } from '../service/context/ContextModels';

@Entry
@Component
struct DailyTimelinePage {
  @State isMapMode: boolean = false;
  @State entries: TimelineEntry[] = [];
  @State todayStr: string = '';
  private refreshTimer: number = -1;
  private mapController: webview.WebviewController = new webview.WebviewController();
  private mapReady: boolean = false;

  aboutToAppear(): void {
    this.refreshData();
    let d = new Date();
    this.todayStr = d.getFullYear() + '-' + (d.getMonth() + 1).toString().padStart(2, '0') + '-' + d.getDate().toString().padStart(2, '0');
    this.refreshTimer = setInterval(() => { this.refreshData(); }, 10000);
  }

  aboutToDisappear(): void {
    if (this.refreshTimer !== -1) {
      clearInterval(this.refreshTimer);
      this.refreshTimer = -1;
    }
  }

  private refreshData(): void {
    try {
      this.entries = DailyTimelineService.getInstance().getMergedTimeline();
      // 地图模式下刷新数据时更新地图
      if (this.isMapMode && this.mapReady) {
        this.sendMapData();
      }
    } catch {
      this.entries = [];
    }
  }

  // ─── Time / Duration formatting ───

  private formatTime(ts: number): string {
    let d = new Date(ts);
    return d.getHours().toString().padStart(2, '0') + ':' + d.getMinutes().toString().padStart(2, '0');
  }

  private formatDuration(ms: number): string {
    if (ms < 60000) return '<1min';
    let totalMin = Math.floor(ms / 60000);
    if (totalMin < 60) return totalMin.toString() + 'min';
    let h = Math.floor(totalMin / 60);
    let m = totalMin % 60;
    if (m === 0) return h.toString() + 'h';
    return h.toString() + 'h' + m.toString() + 'min';
  }

  // ─── Motion state helpers ───

  private getMotionLabel(state: string): string {
    if (state === 'stationary') return '\u{1F9D8} ' + I18n.t('ctx.motion.stationary');
    if (state === 'walking') return '\u{1F6B6} ' + I18n.t('ctx.motion.walking');
    if (state === 'running') return '\u{1F3C3} ' + I18n.t('ctx.motion.running');
    if (state === 'driving') return '\u{1F697} ' + I18n.t('ctx.motion.driving');
    if (state === 'transit') return '\u{1F68C} ' + I18n.t('ctx.motion.transit');
    return state;
  }

  private getMotionColor(state: string): string {
    if (state === 'stationary') return '#9E9E9E';
    if (state === 'walking') return '#4CAF50';
    if (state === 'running') return '#FF9800';
    if (state === 'driving') return '#2196F3';
    if (state === 'transit') return '#9C27B0';
    return '#666666';
  }

  // ─── Map data generation ───

  private buildRenderMapJs(): string {
    let points: string[] = [];
    let lines: string[] = [];
    let prevLat = 0;
    let prevLng = 0;

    for (let i = 0; i < this.entries.length; i++) {
      let e = this.entries[i];
      if (e.latitude === 0 && e.longitude === 0) continue;

      let label = e.geofenceLabel.length > 0 ? e.geofenceLabel : (e.geocodeLabel.length > 0 ? e.geocodeLabel : I18n.t('ctx.timeline.transit'));
      let icon = e.geofenceIcon.length > 0 ? e.geofenceIcon : '\u{1F4CD}';
      let time = this.formatTime(e.startTime);
      let color = this.getMotionColor(e.motionState);

      points.push(`{lat:${e.latitude},lng:${e.longitude},label:"${icon} ${label}",time:"${time}",color:"${color}"}`);

      if (prevLat !== 0 && prevLng !== 0) {
        let dash = e.motionState === 'driving' ? 'false' : 'true';
        lines.push(`{from:[${prevLat},${prevLng}],to:[${e.latitude},${e.longitude}],color:"${color}",dash:${dash}}`);
      }
      prevLat = e.latitude;
      prevLng = e.longitude;
    }

    return `renderMap([${points.join(',')}],[${lines.join(',')}])`;
  }

  private sendMapData(): void {
    try {
      this.mapController.runJavaScript(this.buildRenderMapJs());
    } catch {
      // ignore
    }
  }

  build() {
    Column() {
      // ── Header ──
      Row() {
        Text('\u2190')
          .fontSize(22)
          .fontColor('#1A1A1A')
          .padding(8)
          .onClick(() => { router.back(); })
        Text(I18n.t('ctx.timeline.title'))
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
        // Mode toggle
        Row({ space: 4 }) {
          Text(this.isMapMode ? '\u{1F4CB}' : '\u{1F5FA}')
            .fontSize(20)
          Text(this.isMapMode ? I18n.t('ctx.timeline.listMode') : I18n.t('ctx.timeline.mapMode'))
            .fontSize(13)
            .fontColor('#007AFF')
        }
        .padding({ left: 8, right: 8, top: 4, bottom: 4 })
        .borderRadius(16)
        .backgroundColor('#F0F0FF')
        .onClick(() => {
          this.isMapMode = !this.isMapMode;
        })
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 16 })
      .backgroundColor(Color.White)

      // ── Date ──
      Row() {
        Text('\u{1F4C5} ' + this.todayStr)
          .fontSize(14)
          .fontColor('#666666')
        Text('  ' + this.entries.length.toString() + I18n.t('ctx.timeline.count'))
          .fontSize(13)
          .fontColor('#999999')
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 8, bottom: 8 })
      .backgroundColor('#F8F8FC')

      if (this.isMapMode) {
        // ── Map route mode (Leaflet + OpenStreetMap) ──
        Web({ src: 'resource://rawfile/map.html', controller: this.mapController })
          .width('100%')
          .layoutWeight(1)
          .javaScriptAccess(true)
          .domStorageAccess(true)
          .mixedMode(MixedMode.All)
          .onPageEnd(() => {
            this.mapReady = true;
            this.sendMapData();
          })
      } else {
        // ── Timeline list mode ──
        if (this.entries.length === 0) {
          Column() {
            Text('\u{1F4AD}')
              .fontSize(48)
              .margin({ bottom: 12 })
            Text(I18n.t('ctx.timeline.empty'))
              .fontSize(15)
              .fontColor('#999999')
          }
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
          .width('100%')
        } else {
          Scroll() {
            Column({ space: 0 }) {
              ForEach(this.entries, (entry: TimelineEntry, idx: number) => {
                Row() {
                  // ── Left: Time column ──
                  Column() {
                    Text(this.formatTime(entry.startTime))
                      .fontSize(14)
                      .fontWeight(FontWeight.Bold)
                      .fontColor('#1A1A1A')
                    if (entry.endTime > entry.startTime) {
                      Text(this.formatDuration(entry.endTime - entry.startTime))
                        .fontSize(11)
                        .fontColor('#BBBBBB')
                        .margin({ top: 2 })
                    }
                  }
                  .width(64)
                  .alignItems(HorizontalAlign.End)
                  .padding({ right: 10 })

                  // ── Middle: Timeline rail ──
                  Column() {
                    // Top connector
                    if (idx > 0) {
                      Divider()
                        .vertical(true)
                        .height(16)
                        .strokeWidth(2)
                        .color('#E0E0E0')
                    } else {
                      Column().height(16)
                    }

                    // Node
                    Stack() {
                      Circle()
                        .width(28)
                        .height(28)
                        .fill(Color.White)
                        .stroke(this.getMotionColor(entry.motionState))
                        .strokeWidth(3)
                      Text(entry.geofenceIcon.length > 0 ? entry.geofenceIcon : '\u{1F4CD}')
                        .fontSize(14)
                    }

                    // Bottom connector
                    if (idx < this.entries.length - 1) {
                      Column() {
                        Divider()
                          .vertical(true)
                          .height(16)
                          .strokeWidth(2)
                          .color(this.getMotionColor(this.entries[idx + 1].motionState))
                      }
                    } else {
                      Column().height(16)
                    }
                  }
                  .width(40)
                  .alignItems(HorizontalAlign.Center)

                  // ── Right: Place info + events ──
                  Column() {
                    // Place name
                    Text(entry.geofenceLabel.length > 0 ? entry.geofenceLabel : I18n.t('ctx.timeline.transit'))
                      .fontSize(15)
                      .fontWeight(FontWeight.Medium)
                      .fontColor('#1A1A1A')

                    // Motion state
                    Row({ space: 6 }) {
                      Circle()
                        .width(8)
                        .height(8)
                        .fill(this.getMotionColor(entry.motionState))
                      Text(this.getMotionLabel(entry.motionState))
                        .fontSize(12)
                        .fontColor(this.getMotionColor(entry.motionState))
                    }
                    .margin({ top: 4 })

                    // Time range
                    if (entry.endTime > entry.startTime) {
                      Text(this.formatTime(entry.startTime) + ' - ' + this.formatTime(entry.endTime))
                        .fontSize(11)
                        .fontColor('#BBBBBB')
                        .margin({ top: 2 })
                    } else {
                      Text(I18n.t('ctx.timeline.ongoing'))
                        .fontSize(11)
                        .fontColor('#4CAF50')
                        .margin({ top: 2 })
                    }
                  }
                  .layoutWeight(1)
                  .alignItems(HorizontalAlign.Start)
                  .padding({ left: 10, top: 8, bottom: 8 })
                }
                .width('100%')
                .alignItems(VerticalAlign.Center)
                .padding({ left: 8, right: 16 })
              }, (entry: TimelineEntry) => entry.id)
            }
            .width('100%')
            .padding({ bottom: 40 })
          }
          .layoutWeight(1)
        }
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F2F7')
  }
}
