/**
 * ContextSettingsPage — 情景智能管理页面
 *
 * 功能：地理围栏管理 / 规则引擎状态 / MAB 统计
 */
import { router } from '@kit.ArkUI';
import { ContextAwarenessService } from '../service/context/ContextAwarenessService';
import { ContextEngineService } from '../service/context/ContextEngine';
import { Geofence, GeofenceCategory } from '../service/context/ContextModels';
import { LogService } from '../common/LogService';

const TAG = 'ContextSettings';

@Entry
@Component
struct ContextSettingsPage {
  private log: LogService = LogService.getInstance();

  @State geofences: Geofence[] = [];
  @State ruleCount: number = 0;
  @State mabStats: string = '';
  @State engineStatus: string = '';

  // Add geofence dialog
  @State showAddDialog: boolean = false;
  @State newName: string = '';
  @State newLat: string = '';
  @State newLon: string = '';
  @State newRadius: string = '100';
  @State selectedCategoryIndex: number = 6;

  private categories: string[] = ['home', 'work', 'transit', 'shopping', 'restaurant', 'gym', 'custom'];
  private categoryLabels: string[] = ['🏠 家', '🏢 公司', '🚇 交通', '🛒 购物', '🍜 餐饮', '💪 健身', '📍 自定义'];

  aboutToAppear(): void {
    this.log.info(TAG, 'ContextSettingsPage aboutToAppear');
    this.refresh();
    this.log.info(TAG, 'ContextSettingsPage refresh done, geofences=' + this.geofences.length.toString());
  }

  private refresh(): void {
    try {
      let cas = ContextAwarenessService.getInstance();
      this.geofences = cas.getAllGeofences();
      this.engineStatus = cas.getStatus();
    } catch (err) {
      this.log.warn(TAG, 'Failed to load geofences: ' + (err as Error).message);
    }
    try {
      let engine = ContextEngineService.getInstance();
      this.ruleCount = engine.getRuleCount();
    } catch (err) {
      this.log.warn(TAG, 'Failed to load engine: ' + (err as Error).message);
      this.ruleCount = 0;
    }
  }

  private getCategoryLabel(cat: string): string {
    let idx = this.categories.indexOf(cat);
    if (idx >= 0) {
      return this.categoryLabels[idx];
    }
    return '📍 ' + cat;
  }

  private deleteGeofence(id: string): void {
    ContextAwarenessService.getInstance().removeGeofence(id);
    this.refresh();
  }

  private addGeofence(): void {
    if (this.newName.length === 0 || this.newLat.length === 0 || this.newLon.length === 0) return;

    let lat = parseFloat(this.newLat);
    let lon = parseFloat(this.newLon);
    let radius = parseFloat(this.newRadius);
    if (isNaN(lat) || isNaN(lon) || isNaN(radius)) return;

    let id = 'user_' + Date.now().toString();
    let category = this.categories[this.selectedCategoryIndex];
    let gf: Geofence = {
      id: id,
      name: this.newName,
      latitude: lat,
      longitude: lon,
      radiusMeters: radius,
      category: category as GeofenceCategory,
    };
    ContextAwarenessService.getInstance().addGeofence(gf);
    this.showAddDialog = false;
    this.newName = '';
    this.newLat = '';
    this.newLon = '';
    this.newRadius = '100';
    this.selectedCategoryIndex = 6;
    this.refresh();
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
            // ========== 引擎状态 ==========
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
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)

            // ========== 地理围栏 ==========
            Column() {
              Row() {
                Text('地理围栏')
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

              if (this.geofences.length === 0) {
                Text('暂无围栏，点击右上角添加')
                  .fontSize(14)
                  .fontColor('#999999')
                  .width('100%')
                  .textAlign(TextAlign.Center)
                  .padding(20)
              } else {
                ForEach(this.geofences, (gf: Geofence) => {
                  Column() {
                    Row() {
                      Column({ space: 2 }) {
                        Text(this.getCategoryLabel(gf.category) + '  ' + gf.name)
                          .fontSize(14)
                          .fontColor('#1A1A1A')
                        Text(gf.latitude.toFixed(4) + ', ' + gf.longitude.toFixed(4) + '  r=' + gf.radiusMeters.toString() + 'm')
                          .fontSize(11)
                          .fontColor('#999999')
                      }
                      .layoutWeight(1)
                      .alignItems(HorizontalAlign.Start)

                      Text('删除')
                        .fontSize(13)
                        .fontColor('#FF3B30')
                        .padding(4)
                        .onClick(() => { this.deleteGeofence(gf.id); })
                    }
                    .width('100%')
                    .padding({ top: 8, bottom: 8 })

                    Divider().color('#F0F0F0')
                  }
                }, (gf: Geofence) => gf.id)
              }
            }
            .width('100%')
            .padding(16)
            .backgroundColor(Color.White)
            .borderRadius(12)

            // ========== 规则 ==========
            Column() {
              Text('规则引擎')
                .fontSize(16)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1A1A1A')
                .margin({ bottom: 8 })

              Text('已加载 ' + this.ruleCount.toString() + ' 条规则')
                .fontSize(14)
                .fontColor('#666666')
                .margin({ bottom: 12 })

              Row({ space: 12 }) {
                Button('重载默认规则')
                  .fontSize(13)
                  .backgroundColor('#F0F0F0')
                  .fontColor('#1A1A1A')
                  .onClick(() => {
                    ContextEngineService.getInstance().loadDefaultRules().then(() => { this.refresh(); });
                  })

                Button('查看 MAB 统计')
                  .fontSize(13)
                  .backgroundColor('#F0F0F0')
                  .fontColor('#1A1A1A')
                  .onClick(() => {
                    this.mabStats = ContextEngineService.getInstance().getStats();
                  })
              }
              .width('100%')

              if (this.mabStats.length > 2) {
                Text('MAB 学习数据:')
                  .fontSize(13)
                  .fontColor('#666666')
                  .margin({ top: 12 })
                Text(this.mabStats)
                  .fontSize(11)
                  .fontColor('#999999')
                  .width('100%')
                  .backgroundColor('#F5F5F5')
                  .padding(8)
                  .borderRadius(8)
                  .margin({ top: 4 })
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

      // ========== 添加围栏弹窗 ==========
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

            // Category chips
            Text('类别')
              .fontSize(14)
              .fontColor('#666666')

            Flex({ wrap: FlexWrap.Wrap }) {
              ForEach(this.categoryLabels, (label: string) => {
                Text(label)
                  .fontSize(13)
                  .fontColor(this.selectedCategoryIndex === this.categoryLabels.indexOf(label) ? Color.White : '#1A1A1A')
                  .backgroundColor(this.selectedCategoryIndex === this.categoryLabels.indexOf(label) ? '#007AFF' : '#F0F0F0')
                  .padding({ left: 12, right: 12, top: 6, bottom: 6 })
                  .borderRadius(16)
                  .margin(4)
                  .onClick(() => { this.selectedCategoryIndex = this.categoryLabels.indexOf(label); })
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
                .onClick(() => { this.addGeofence(); })
            }
            .width('100%')
            .margin({ top: 8 })
          }
          .width('85%')
          .padding(20)
          .backgroundColor(Color.White)
          .borderRadius(16)
          .shadow({ radius: 20, color: '#40000000' })
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#80000000')
        .justifyContent(FlexAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
  }
}
