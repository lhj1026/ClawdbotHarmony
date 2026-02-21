/**
 * ContextSettingsPage — 情景智能管理页面
 * 功能：地理围栏管理 / 规则引擎状态 / MAB 统计
 */
import { router, promptAction } from '@kit.ArkUI';
import { LogService } from '../common/LogService';
import { ContextAwarenessService } from '../service/context/ContextAwarenessService';
import { ContextEngineService } from '../service/context/ContextEngine';
import { FeedbackService } from '../service/context/FeedbackService';
import { Geofence, GeofenceCategory, FeedbackStats, FeedbackRuleStat } from '../service/context/ContextModels';
import { LocationDiscoveryService, GeofenceSuggestion } from '../service/context/LocationDiscoveryService';
import { LearnedSignalsSummary } from '../service/context/LocationFusionService';
import { GeofenceSuggestionCard } from '../components/GeofenceSuggestionCard';
import { TrayStatus } from '../service/context/DataTray';

@Entry
@Component
struct ContextSettingsPage {
  private log: LogService = LogService.getInstance();

  @State geofenceNames: string[] = [];
  @State geofenceDetails: string[] = [];
  @State geofenceIds: string[] = [];
  @State ruleCount: number = 0;
  @State mabStats: string = '';
  @State engineStatus: string = '';
  @State suggestions: GeofenceSuggestion[] = [];
  @State discoveryStats: string = '';
  @State showAddDialog: boolean = false;
  @State newName: string = '';
  @State newLat: string = '';
  @State newLon: string = '';
  @State newRadius: string = '100';
  @State selectedCat: number = 6;

  // 反馈统计
  @State fbTotal: number = 0;
  @State fbPositive: number = 0;
  @State fbNegative: number = 0;
  @State fbRatioText: string = '--';
  @State fbTopRuleNames: string[] = [];
  @State fbTopRuleScores: string[] = [];

  // 已学习的位置信号
  @State learnedSignals: LearnedSignalsSummary[] = [];
  // 数据托盘
  @State trayKeys: string[] = [];
  @State trayValues: string[] = [];
  @State trayAges: string[] = [];
  @State trayIndicators: string[] = [];   // 🟢/🟡/🔴
  @State trayQualities: string[] = [];
  private trayTimer: number = -1;

  private catIds: string[] = ['home', 'work', 'transit', 'shopping', 'restaurant', 'gym', 'custom'];
  private catLabels: string[] = ['🏠 家', '🏢 公司', '🚇 交通', '🛒 购物', '🍜 餐饮', '💪 健身', '📍 自定义'];

  aboutToAppear(): void {
    this.log.info('CtxSettings', 'Page opened');
    this.refresh();
    this.refreshTrayStatus();
    // Auto-refresh tray every 5 seconds
    this.trayTimer = setInterval(() => {
      this.refreshTrayStatus();
    }, 5000);
  }

  aboutToDisappear(): void {
    if (this.trayTimer !== -1) {
      clearInterval(this.trayTimer);
      this.trayTimer = -1;
    }
  }

  private getCatLabel(cat: string): string {
    let idx = this.catIds.indexOf(cat);
    if (idx >= 0) return this.catLabels[idx];
    return '📍';
  }

  private refresh(): void {
    try {
      let cas = ContextAwarenessService.getInstance();
      let gfs = cas.getAllGeofences();
      let names: string[] = [];
      let details: string[] = [];
      let ids: string[] = [];
      for (let i = 0; i < gfs.length; i++) {
        let gf = gfs[i];
        names.push(this.getCatLabel(gf.category) + ' ' + gf.name);
        details.push(gf.latitude.toFixed(4) + ', ' + gf.longitude.toFixed(4) + '  r=' + gf.radiusMeters.toString() + 'm');
        ids.push(gf.id);
      }
      this.geofenceNames = names;
      this.geofenceDetails = details;
      this.geofenceIds = ids;
      this.engineStatus = cas.getStatus();
      this.learnedSignals = cas.getLearnedSignalsSummaries();
      this.suggestions = cas.getLocationSuggestions();
      this.suggestions = cas.getFilteredSuggestions();
      let stats = cas.getLocationDiscoveryStats();
      this.discoveryStats = `历史点: ${stats.historyCount} | 聚类: ${stats.clusterCount} | 上次发现: ${stats.lastDiscovery}`;
    } catch (err) {
      this.log.warn('CtxSettings', 'refresh cas: ' + (err as Error).message);
      this.engineStatus = '情景智能未初始化';
      this.discoveryStats = '';
      this.suggestions = [];
    }
    try {
      this.ruleCount = ContextEngineService.getInstance().getRuleCount();
    } catch (err) {
      this.ruleCount = 0;
    }
    this.refreshFeedbackStats();
  }

  private refreshFeedbackStats(): void {
    try {
      // Use FeedbackService directly to get latest stats (including A2UI button feedback)
      let stats: FeedbackStats = FeedbackService.getInstance().getStats();
      this.fbTotal = stats.totalCount;
      this.fbPositive = stats.positiveCount;
      this.fbNegative = stats.negativeCount;
      if (stats.positiveCount + stats.negativeCount > 0) {
        this.fbRatioText = Math.round(stats.positiveRatio * 100).toString() + '%';
      } else {
        this.fbRatioText = '--';
      }
      let names: string[] = [];
      let scores: string[] = [];
      for (let i = 0; i < stats.topRules.length; i++) {
        let tr: FeedbackRuleStat = stats.topRules[i];
        names.push(tr.ruleName);
        scores.push(tr.avgReward.toFixed(2) + ' (' + tr.feedbackCount.toString() + ' fb)');
      }
      this.fbTopRuleNames = names;
      this.fbTopRuleScores = scores;
    } catch (err) {
      this.fbTotal = 0;
      this.fbRatioText = '--';
    }
  }

  build() {
    Stack() {
      Column() {
        // Header
        Row() {
          Text('←')
            .fontSize(22)
            .fontColor('#1A1A1A')
            .padding(8)
            .onClick(() => { router.back(); })
          Text('情景智能设置')
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .layoutWeight(1)
        }
        .width('100%')
        .height(48)
        .padding({ left: 8, right: 16 })
        .backgroundColor(Color.White)

        Scroll() {
          Column({ space: 16 }) {
            // ===== 引擎状态 =====
            Column() {
              Text('引擎状态')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1A1A1A')
                .margin({ bottom: 8 })
              Text(this.engineStatus)
                .fontSize(13)
                .fontColor('#666666')
                .width('100%')
              Text('C++ 规则数: ' + this.ruleCount.toString())
                .fontSize(13)
                .fontColor('#666666')
                .margin({ top: 4 })
              Text('管理规则 \u2192')
                .fontSize(14)
                .fontColor('#007AFF')
                .margin({ top: 10 })
                .onClick(() => {
                  router.pushUrl({ url: 'pages/RuleManagementPage' });
                })
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)

            // ===== 数据托盘 =====
            Column() {
              Row() {
                Text('\u{1F4E1} 数据托盘 (' + this.trayKeys.length.toString() + ')')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                  .layoutWeight(1)
                Text('刷新')
                  .fontSize(14)
                  .fontColor('#007AFF')
                  .onClick(() => { this.refreshTrayStatus(); })
              }
              .width('100%')
              .margin({ bottom: 8 })

              Text('每 5 秒自动刷新')
                .fontSize(11)
                .fontColor('#BBBBBB')
                .width('100%')
                .margin({ bottom: 8 })

              if (this.trayKeys.length === 0) {
                Text('托盘为空（传感器未开始写入）')
                  .fontSize(13)
                  .fontColor('#999999')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(16)
              } else {
                // Header row
                Row() {
                  Text('Key')
                    .fontSize(11)
                    .fontColor('#999999')
                    .fontWeight(FontWeight.Medium)
                    .width(90)
                  Text('Value')
                    .fontSize(11)
                    .fontColor('#999999')
                    .fontWeight(FontWeight.Medium)
                    .layoutWeight(1)
                  Text('Age')
                    .fontSize(11)
                    .fontColor('#999999')
                    .fontWeight(FontWeight.Medium)
                    .width(45)
                  Text('Q')
                    .fontSize(11)
                    .fontColor('#999999')
                    .fontWeight(FontWeight.Medium)
                    .width(35)
                  Text('')
                    .width(18)
                }
                .width('100%')
                .padding({ bottom: 4 })

                ForEach(this.trayKeys, (key: string, idx: number) => {
                  Row() {
                    Text(key)
                      .fontSize(12)
                      .fontColor('#1A1A1A')
                      .width(90)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(idx < this.trayValues.length ? this.trayValues[idx] : '')
                      .fontSize(12)
                      .fontColor('#666666')
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(idx < this.trayAges.length ? this.trayAges[idx] : '')
                      .fontSize(11)
                      .fontColor('#999999')
                      .width(45)
                    Text(idx < this.trayQualities.length ? this.trayQualities[idx] : '')
                      .fontSize(11)
                      .fontColor('#999999')
                      .width(35)
                    Text(idx < this.trayIndicators.length ? this.trayIndicators[idx] : '')
                      .fontSize(12)
                      .width(18)
                  }
                  .width('100%')
                  .padding({ top: 3, bottom: 3 })
                }, (key: string, idx: number) => key + '_' + idx.toString())
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)

            // ===== 地理围栏 =====
            Column() {
              Row() {
                Text('地理围栏 (' + this.geofenceNames.length.toString() + ')')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                  .layoutWeight(1)
                Text('＋ 添加')
                  .fontSize(14)
                  .fontColor('#007AFF')
                  .onClick(() => { this.showAddDialog = true; })
              }
              .width('100%')
              .margin({ bottom: 12 })

              if (this.geofenceNames.length === 0) {
                Text('暂无围栏，点击右上角添加')
                  .fontSize(14)
                  .fontColor('#999999')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(20)
              } else {
                ForEach(this.geofenceIds, (gfId: string, index: number) => {
                  Column() {
                    Row() {
                      Column({ space: 2 }) {
                        Text(this.geofenceNames[index])
                          .fontSize(14)
                          .fontColor('#1A1A1A')
                        Text(this.geofenceDetails[index])
                          .fontSize(11)
                          .fontColor('#999999')
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)

                      Text('删除')
                        .fontSize(13)
                        .fontColor('#FF3B30')
                        .padding(4)
                        .onClick(() => { this.deleteGeofence(gfId); })
                    }
                    .width('100%')
                    .padding({ top: 8, bottom: 8 })
                    Divider().color('#F0F0F0')
                  }
                }, (gfId: string) => gfId)
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)

            // ===== 已学习的位置信号 =====
            Column() {
              Row() {
                Text('位置信号学习')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                  .layoutWeight(1)
                Text('清除全部')
                  .fontSize(13)
                  .fontColor('#FF3B30')
                  .onClick(() => { this.clearAllSignals(); })
              }
              .width('100%')
              .margin({ bottom: 8 })

              Text('GPS 高精度时自动学习 WiFi/蓝牙信号，用于室内定位增强')
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
                .margin({ bottom: 8 })

              if (this.learnedSignals.length === 0) {
                Text('暂无已学习信号，进入围栏区域后会自动学习')
                  .fontSize(13)
                  .fontColor('#999999')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(16)
              } else {
                ForEach(this.learnedSignals, (sig: LearnedSignalsSummary) => {
                  Column() {
                    Row() {
                      Column({ space: 2 }) {
                        Text(sig.geofenceName)
                          .fontSize(14)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#1A1A1A')
                        if (sig.wifiSsids.length > 0) {
                          Text('WiFi: ' + sig.wifiSsids.join(', '))
                            .fontSize(12)
                            .fontColor('#007AFF')
                        }
                        if (sig.btDevices.length > 0) {
                          Text('BT: ' + sig.btDevices.join(', '))
                            .fontSize(12)
                            .fontColor('#5856D6')
                        }
                        Text('观测 ' + sig.totalObservations.toString() + ' 次')
                          .fontSize(11)
                          .fontColor('#999999')
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)

                      Text('清除')
                        .fontSize(13)
                        .fontColor('#FF3B30')
                        .padding(4)
                        .onClick(() => { this.clearSignalsForGeofence(sig.geofenceId); })
                    }
                    .width('100%')
                    .padding({ top: 8, bottom: 8 })
                    Divider().color('#F0F0F0')
                  }
                }, (sig: LearnedSignalsSummary) => sig.geofenceId)
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)

            // ===== 反馈统计 =====
            Column() {
              Row() {
                Text('反馈统计')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                  .layoutWeight(1)
                Text('刷新')
                  .fontSize(14)
                  .fontColor('#007AFF')
                  .onClick(() => {
                    this.refreshFeedbackStats();
                    try { promptAction.showToast({ message: '反馈统计已刷新', duration: 1500 }); } catch {}
                  })
              }
              .width('100%')
              .margin({ bottom: 12 })

              // 数字统计行
              Row() {
                Column() {
                  Text(this.fbTotal.toString())
                    .fontSize(22)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#1A1A1A')
                  Text('总反馈')
                    .fontSize(11)
                    .fontColor('#999999')
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)

                Column() {
                  Text(this.fbRatioText)
                    .fontSize(22)
                    .fontWeight(FontWeight.Bold)
                    .fontColor('#4CAF50')
                  Text('好评率')
                    .fontSize(11)
                    .fontColor('#999999')
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)

                Column() {
                  Text(this.fbPositive.toString() + ' / ' + this.fbNegative.toString())
                    .fontSize(16)
                    .fontWeight(FontWeight.Medium)
                    .fontColor('#1A1A1A')
                  Text('\uD83D\uDC4D / \uD83D\uDC4E')
                    .fontSize(11)
                    .fontColor('#999999')
                    .margin({ top: 2 })
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Center)
              }
              .width('100%')
              .padding({ top: 4, bottom: 8 })

              // Top 规则
              if (this.fbTopRuleNames.length > 0) {
                Divider().color('#F0F0F0').margin({ top: 8, bottom: 8 })
                Text('最有效规则 Top ' + this.fbTopRuleNames.length.toString())
                  .fontSize(13)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#666666')
                  .width('100%')
                  .margin({ bottom: 6 })
                ForEach(this.fbTopRuleNames, (name: string, idx: number) => {
                  Row() {
                    Text((idx + 1).toString() + '.')
                      .fontSize(13)
                      .fontColor('#007AFF')
                      .fontWeight(FontWeight.Bold)
                      .width(20)
                    Text(name)
                      .fontSize(13)
                      .fontColor('#1A1A1A')
                      .layoutWeight(1)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(idx < this.fbTopRuleScores.length ? this.fbTopRuleScores[idx] : '')
                      .fontSize(12)
                      .fontColor('#999999')
                  }
                  .width('100%')
                  .padding({ top: 3, bottom: 3 })
                }, (name: string, idx: number) => name + '_' + idx.toString())
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)

            // ===== MAB =====
            Column() {
              Row() {
                Text('MAB 学习统计')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                  .layoutWeight(1)
                Text('刷新')
                  .fontSize(14)
                  .fontColor('#007AFF')
                  .onClick(() => {
                    try { this.mabStats = ContextEngineService.getInstance().getStats(); } catch (e) {}
                  })
              }
              .width('100%')
              .margin({ bottom: 8 })
              Text(this.mabStats.length > 2 ? this.mabStats : '暂无数据')
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)

            // ===== 位置自动发现 =====
            Column() {
              Row() {
                Text('📍 位置自动发现')
                  .fontSize(16)
                  .fontWeight(FontWeight.Bold)
                  .fontColor('#1A1A1A')
                  .layoutWeight(1)
                Text('立即发现')
                  .fontSize(14)
                  .fontColor('#007AFF')
                  .onClick(() => { this.triggerDiscovery(); })
              }
              .width('100%')
              .margin({ bottom: 8 })

              Text(this.discoveryStats.length > 0 ? this.discoveryStats : '未启动')
                .fontSize(12)
                .fontColor('#999999')
                .width('100%')
                .margin({ bottom: 8 })

              if (this.suggestions.length === 0) {
                Text('暂无发现，GPS 历史积累后会自动发现常去地点')
                  .fontSize(13)
                  .fontColor('#999999')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(16)
              } else {
                ForEach(this.suggestions, (s: GeofenceSuggestion) => {
                  GeofenceSuggestionCard({
                    suggestionId: s.id,
                    name: s.name,
                    category: s.category,
                    reason: s.reason,
                    confidence: s.confidence,
                    latitude: s.latitude,
                    longitude: s.longitude,
                    radiusMeters: s.radiusMeters,
                    onAccept: (id: string, name: string, category: string) => {
                      this.handleAcceptSuggestion(id, name, category);
                    },
                    onIgnore: (id: string) => {
                      this.handleIgnoreSuggestion(id);
                    },
                    onDefer: (id: string) => {
                      this.handleDeferSuggestion(id);
                    },
                  })
                    .margin({ bottom: 8 })
                }, (s: GeofenceSuggestion) => s.id)
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)
          }
          .padding({ left: 16, right: 16, top: 12, bottom: 40 })
        }
        .layoutWeight(1)
        .backgroundColor('#F2F2F7')
      }
      .width('100%')
      .height('100%')

      // ===== 添加围栏弹窗 =====
      if (this.showAddDialog) {
        Column() {
          Column({ space: 12 }) {
            Text('添加地理围栏')
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor('#1A1A1A')

            TextInput({ placeholder: '名称（如：家、公司）' })
              .onChange((val: string) => { this.newName = val; })
              .width('100%')
              .height(44)

            Row({ space: 8 }) {
              TextInput({ placeholder: '纬度' })
                .onChange((val: string) => { this.newLat = val; })
                .layoutWeight(1)
                .height(44)
              TextInput({ placeholder: '经度' })
                .onChange((val: string) => { this.newLon = val; })
                .layoutWeight(1)
                .height(44)
            }
            .width('100%')

            TextInput({ placeholder: '半径（米），默认100' })
              .onChange((val: string) => { this.newRadius = val; })
              .width('100%')
              .height(44)

            Text('类别')
              .fontSize(14)
              .fontColor('#666666')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.catLabels, (label: string) => {
                Text(label)
                  .fontSize(13)
                  .fontColor(this.selectedCat === this.catLabels.indexOf(label) ? Color.White : '#1A1A1A')
                  .backgroundColor(this.selectedCat === this.catLabels.indexOf(label) ? '#007AFF' : '#F0F0F0')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(16)
                  .margin(4)
                  .onClick(() => { this.selectedCat = this.catLabels.indexOf(label); })
              }, (label: string) => label)
            }
            .width('100%')

            Row({ space: 12 }) {
              Button('取消')
                .fontSize(14)
                .backgroundColor('#F0F0F0')
                .fontColor('#1A1A1A')
                .layoutWeight(1)
                .onClick(() => { this.showAddDialog = false; })
              Button('添加')
                .fontSize(14)
                .backgroundColor('#007AFF')
                .fontColor(Color.White)
                .layoutWeight(1)
                .onClick(() => { this.doAddGeofence(); })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .width('85%')
          .padding(20)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .shadow({ radius: 20, color: '#40000000' })
          .onClick(() => {})
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
        .onClick(() => { this.showAddDialog = false; })
      }
    }
    .width('100%')
    .height('100%')
  }

  private doAddGeofence(): void {
    this.log.info('CtxSettings', 'Add: ' + this.newName + ' ' + this.newLat + ',' + this.newLon);
    if (this.newName.length === 0 || this.newLat.length === 0 || this.newLon.length === 0) return;
    let lat = parseFloat(this.newLat);
    let lon = parseFloat(this.newLon);
    let radius = this.newRadius.length > 0 ? parseFloat(this.newRadius) : 100;
    if (isNaN(lat) || isNaN(lon) || isNaN(radius)) return;
    try {
      let cas = ContextAwarenessService.getInstance();
      let gf: Geofence = {
        id: 'user_' + Date.now().toString(),
        name: this.newName,
        latitude: lat,
        longitude: lon,
        radiusMeters: radius,
        category: this.catIds[this.selectedCat] as GeofenceCategory,
      };
      cas.addGeofence(gf);
    } catch (err) {
      this.log.error('CtxSettings', 'Add error: ' + (err as Error).message);
    }
    this.showAddDialog = false;
    this.newName = '';
    this.newLat = '';
    this.newLon = '';
    this.newRadius = '100';
    this.selectedCat = 6;
    this.refresh();
  }

  private triggerDiscovery(): void {
    try {
      let cas = ContextAwarenessService.getInstance();
      let discovery = LocationDiscoveryService.getInstance();
      discovery.runDiscovery().then(() => {
        this.suggestions = cas.getFilteredSuggestions();
        let stats = cas.getLocationDiscoveryStats();
        this.discoveryStats = `历史点: ${stats.historyCount} | 聚类: ${stats.clusterCount} | 上次发现: ${stats.lastDiscovery}`;
      });
    } catch (err) {
      this.log.error('CtxSettings', 'Discovery error: ' + (err as Error).message);
    }
  }

  private handleAcceptSuggestion(clusterId: string, name: string, category: string): void {
    try {
      let cas = ContextAwarenessService.getInstance();
      let raw = this.locationDiscovery().getSuggestions();
      let match: GeofenceSuggestion | undefined = undefined;
      for (let i = 0; i < raw.length; i++) {
        if (raw[i].id === clusterId) {
          match = raw[i];
          break;
        }
      }
      if (match) {
        cas.acceptSuggestion(match, name, category);
      }
      this.refresh();
    } catch (err) {
      this.log.error('CtxSettings', 'Accept suggestion error: ' + (err as Error).message);
    }
  }

  private handleIgnoreSuggestion(clusterId: string): void {
    try {
      ContextAwarenessService.getInstance().ignoreSuggestion(clusterId);
      this.refresh();
    } catch (err) {
      this.log.error('CtxSettings', 'Ignore suggestion error: ' + (err as Error).message);
    }
  }

  private handleDeferSuggestion(clusterId: string): void {
    try {
      ContextAwarenessService.getInstance().deferSuggestion(clusterId);
      this.refresh();
    } catch (err) {
      this.log.error('CtxSettings', 'Defer suggestion error: ' + (err as Error).message);
    }
  }

  private locationDiscovery(): LocationDiscoveryService {
    return LocationDiscoveryService.getInstance();
  }

  private refreshTrayStatus(): void {
    try {
      let cas = ContextAwarenessService.getInstance();
      let statuses: TrayStatus[] = cas.getTrayStatus();
      let keys: string[] = [];
      let values: string[] = [];
      let ages: string[] = [];
      let indicators: string[] = [];
      let qualities: string[] = [];
      for (let i = 0; i < statuses.length; i++) {
        let s: TrayStatus = statuses[i];
        keys.push(s.key);
        values.push(s.value.length > 20 ? s.value.substring(0, 20) + '...' : s.value);
        ages.push(this.formatAge(s.ageMs));
        if (s.fresh) {
          indicators.push('\u{1F7E2}');  // green circle
        } else if (s.effectiveQuality > 0) {
          indicators.push('\u{1F7E1}');  // yellow circle
        } else {
          indicators.push('\u{1F534}');  // red circle
        }
        qualities.push((s.effectiveQuality * 100).toFixed(0) + '%');
      }
      this.trayKeys = keys;
      this.trayValues = values;
      this.trayAges = ages;
      this.trayIndicators = indicators;
      this.trayQualities = qualities;
    } catch (err) {
      this.trayKeys = [];
    }
  }

  private formatAge(ms: number): string {
    if (ms < 1000) return ms.toString() + 'ms';
    if (ms < 60000) return (ms / 1000).toFixed(0) + 's';
    if (ms < 3600000) return (ms / 60000).toFixed(1) + 'm';
    return (ms / 3600000).toFixed(1) + 'h';
  }

  private deleteGeofence(id: string): void {
    try {
      ContextAwarenessService.getInstance().removeGeofence(id);
    } catch (err) {
      this.log.error('CtxSettings', 'Del error: ' + (err as Error).message);
    }
    this.refresh();
  }

  private clearSignalsForGeofence(geofenceId: string): void {
    try {
      ContextAwarenessService.getInstance().clearLearnedSignals(geofenceId).then(() => {
        this.refresh();
      });
    } catch (err) {
      this.log.error('CtxSettings', 'Clear signals error: ' + (err as Error).message);
    }
  }

  private clearAllSignals(): void {
    try {
      ContextAwarenessService.getInstance().clearAllLearnedSignals().then(() => {
        this.refresh();
      });
    } catch (err) {
      this.log.error('CtxSettings', 'Clear all signals error: ' + (err as Error).message);
    }
  }
}
