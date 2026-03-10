/**
 * RuleManagementPage — 规则管理页面 v2
 * 场景模板 + 高级模式，让添加规则真正能用
 */
import { router } from '@kit.ArkUI';
import { LogService } from '../common/LogService';
import { I18n } from '../common/I18n';
import { ContextEngineService, ContextRule, ContextCondition, ContextAction } from '../service/context/ContextEngine';
import { ContextAwarenessService } from '../service/context/ContextAwarenessService';

const TAG = 'RuleMgmt';

/** Scene template for quick rule creation */
interface SceneTemplate {
  id: string;
  icon: string;
  name: string;
  description: string;
  category: string;  // person, phone, environment
  tier: number;
  conditions: ContextCondition[];
  defaultAction: ContextAction;
  defaultCooldownMs: number;
}

interface CooldownOption {
  label: string;
  value: number;
}

/** Available context keys with friendly labels and value hints */
interface ContextKeyInfo {
  key: string;
  label: string;
  hint: string;        // value hint for user
  presets?: string[];   // preset values to pick from
}

@Entry
@Component
struct RuleManagementPage {
  private log: LogService = LogService.getInstance();
  private engine: ContextEngineService = ContextEngineService.getInstance();

  @State rules: ContextRule[] = [];
  @State activeTab: number = 0;  // 0=rules list, 1=add from template, 2=advanced add

  // Template mode state
  @State selectedTemplate: SceneTemplate | null = null;
  @State templatePayload: string = '';

  // Advanced mode state
  @State newName: string = '';
  @State conditionRows: ConditionRow[] = [];
  @State actionType: number = 0;
  @State actionPayload: string = '';
  @State selectedCooldown: number = 3;

  private cooldownOptions: CooldownOption[] = [
    { label: '10分钟', value: 600000 },
    { label: '30分钟', value: 1800000 },
    { label: '1小时', value: 3600000 },
    { label: '4小时', value: 14400000 },
    { label: '8小时', value: 28800000 },
    { label: '24小时', value: 86400000 },
  ];

  private actionTypeLabels: string[] = ['💡 建议', '🔔 通知', '⚠️ 警告'];
  private actionTypeIds: string[] = ['suggestion', 'notification', 'alert'];



  // All available context keys organized by category
  private contextKeys: ContextKeyInfo[] = [
    // Environment - Time
    { key: 'timeOfDay', label: '⏰ 时段', hint: 'dawn/morning/afternoon/evening/night', presets: ['dawn', 'morning', 'afternoon', 'evening', 'night'] },
    { key: 'hour', label: '🕐 小时', hint: '0-23' },
    { key: 'dayOfWeek', label: '📅 星期', hint: '1-7 (1=周一)' },
    { key: 'isWeekend', label: '🗓️ 是否周末', hint: 'true/false', presets: ['true', 'false'] },
    // Phone
    { key: 'batteryLevel', label: '🔋 电量', hint: '0-100' },
    { key: 'isCharging', label: '🔌 充电中', hint: 'true/false', presets: ['true', 'false'] },
    { key: 'networkType', label: '📶 网络类型', hint: 'wifi/cellular/none', presets: ['wifi', 'cellular', 'none'] },
    // Location (WiFi-based)
    { key: 'wifiSsid', label: '📡 WiFi名称', hint: 'WiFi SSID' },
    { key: 'wifiGeofence', label: '📍 WiFi位置', hint: 'home/work/gym/...', presets: ['home', 'work', 'gym'] },
    { key: 'wifiLostCategory', label: '📍 WiFi离开', hint: 'home/work (WiFi断开时)', presets: ['home', 'work'] },
    // Person
    { key: 'bt_in_vehicle', label: '🚗 车载蓝牙', hint: 'true/false', presets: ['true', 'false'] },
    { key: 'step_count_today', label: '🚶 今日步数', hint: '步数 (数字)' },
    { key: 'activityDuration', label: '⏱️ 活动时长', hint: '秒数 (2400=40分钟)' },
    { key: 'isSleeping', label: '😴 睡眠中', hint: 'true/false', presets: ['true', 'false'] },
    { key: 'motionState', label: '🏃 运动状态', hint: 'stationary/walking/driving', presets: ['stationary', 'walking', 'driving'] },
  ];

  // Scene templates
  private templates: SceneTemplate[] = [
    {
      id: 'tpl_arrive_home', icon: '🏠', name: '到家提醒',
      description: '连上家里WiFi时提醒',
      category: 'environment', tier: 1,
      conditions: [
        { key: 'wifiGeofence', op: 'eq', value: 'home' },
        { key: 'timeOfDay', op: 'in', value: 'afternoon,evening,night' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '到家了 🏠 放松一下吧' },
      defaultCooldownMs: 28800000
    },
    {
      id: 'tpl_arrive_work', icon: '💼', name: '到公司提醒',
      description: '连上公司WiFi时提醒',
      category: 'environment', tier: 1,
      conditions: [
        { key: 'wifiGeofence', op: 'eq', value: 'work' },
        { key: 'isWeekend', op: 'eq', value: 'false' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '到公司了 💼 查看今天待办？' },
      defaultCooldownMs: 28800000
    },
    {
      id: 'tpl_leave_home', icon: '🚶', name: '出门提醒',
      description: '早上WiFi断开时提醒',
      category: 'environment', tier: 1,
      conditions: [
        { key: 'wifiLostCategory', op: 'eq', value: 'home' },
        { key: 'timeOfDay', op: 'in', value: 'dawn,morning' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '出门了！看看天气和日程 ☀️' },
      defaultCooldownMs: 28800000
    },
    {
      id: 'tpl_low_battery', icon: '🔋', name: '低电量提醒',
      description: '电量低于指定值时提醒',
      category: 'phone', tier: 0,
      conditions: [
        { key: 'batteryLevel', op: 'lte', value: '20' },
        { key: 'isCharging', op: 'eq', value: 'false' }
      ],
      defaultAction: { id: '', type: 'notification', payload: '电量不足，建议充电 🔋' },
      defaultCooldownMs: 1800000
    },
    {
      id: 'tpl_sedentary', icon: '🏃', name: '久坐提醒',
      description: '长时间没走动时提醒',
      category: 'person', tier: 2,
      conditions: [
        { key: 'activityDuration', op: 'gte', value: '2400' },
        { key: 'timeOfDay', op: 'in', value: 'morning,afternoon' }
      ],
      defaultAction: { id: '', type: 'alert', payload: '坐了40分钟了，起来活动一下 🏃‍♂️' },
      defaultCooldownMs: 2400000
    },
    {
      id: 'tpl_driving', icon: '🚗', name: '驾驶模式',
      description: '连接车载蓝牙时触发',
      category: 'person', tier: 2,
      conditions: [
        { key: 'bt_in_vehicle', op: 'eq', value: 'true' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '开车中 🚗 注意安全' },
      defaultCooldownMs: 3600000
    },
    {
      id: 'tpl_bedtime', icon: '🌙', name: '睡眠提醒',
      description: '深夜充电时提醒休息',
      category: 'person', tier: 0,
      conditions: [
        { key: 'hour', op: 'gte', value: '23' },
        { key: 'isCharging', op: 'eq', value: 'true' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '夜深了，早点休息吧 🌙' },
      defaultCooldownMs: 28800000
    },
    {
      id: 'tpl_morning_commute', icon: '🌅', name: '早晨通勤',
      description: '工作日早上开车时',
      category: 'environment', tier: 2,
      conditions: [
        { key: 'bt_in_vehicle', op: 'eq', value: 'true' },
        { key: 'timeOfDay', op: 'eq', value: 'morning' },
        { key: 'isWeekend', op: 'eq', value: 'false' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '通勤中 🚗 听点新闻？' },
      defaultCooldownMs: 28800000
    },
    {
      id: 'tpl_home_lunch', icon: '🍚', name: '在家午餐',
      description: '中午在家时推荐营养午餐',
      category: 'person', tier: 1,
      conditions: [
        { key: 'wifiGeofence', op: 'eq', value: 'home' },
        { key: 'hour', op: 'gte', value: '11' },
        { key: 'hour', op: 'lte', value: '13' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '午饭时间了 🍚 今天想吃什么？' },
      defaultCooldownMs: 28800000
    },
    {
      id: 'tpl_home_dinner', icon: '🍽️', name: '在家晚餐',
      description: '傍晚在家时提醒晚餐',
      category: 'person', tier: 1,
      conditions: [
        { key: 'wifiGeofence', op: 'eq', value: 'home' },
        { key: 'hour', op: 'gte', value: '17' },
        { key: 'hour', op: 'lte', value: '19' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '晚餐时间 🍽️ 简单做还是叫外卖？' },
      defaultCooldownMs: 28800000
    },
    {
      id: 'tpl_home_relax', icon: '🎵', name: '晚间放松',
      description: '晚上在家安静时推荐放松',
      category: 'person', tier: 1,
      conditions: [
        { key: 'wifiGeofence', op: 'eq', value: 'home' },
        { key: 'hour', op: 'gte', value: '20' },
        { key: 'hour', op: 'lte', value: '22' },
        { key: 'motionState', op: 'eq', value: 'still' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '放松时间 🎵 听音乐？看个片？' },
      defaultCooldownMs: 28800000
    },
    {
      id: 'tpl_transit_arrive', icon: '🚇', name: '到达交通枢纽',
      description: '到机场/高铁站时查看行程',
      category: 'environment', tier: 1,
      conditions: [
        { key: 'wifiGeofence', op: 'eq', value: 'transit' }
      ],
      defaultAction: { id: '', type: 'notification', payload: '🚇 到达交通枢纽！查看行程信息？' },
      defaultCooldownMs: 14400000
    },
    {
      id: 'tpl_restaurant_arrive', icon: '🍜', name: '到达餐厅',
      description: '到餐厅时的提醒',
      category: 'environment', tier: 1,
      conditions: [
        { key: 'wifiGeofence', op: 'eq', value: 'restaurant' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '🍜 到餐厅了！' },
      defaultCooldownMs: 14400000
    },
    {
      id: 'tpl_gym_arrive', icon: '💪', name: '到达健身房',
      description: '到健身房开始训练',
      category: 'environment', tier: 1,
      conditions: [
        { key: 'wifiGeofence', op: 'eq', value: 'gym' }
      ],
      defaultAction: { id: '', type: 'suggestion', payload: '💪 到健身房了！今天练什么？' },
      defaultCooldownMs: 14400000
    },
    {
      id: 'tpl_work_meeting', icon: '📅', name: '会议即将开始',
      description: '在公司且有会议快开始',
      category: 'environment', tier: 1,
      conditions: [
        { key: 'wifiGeofence', op: 'eq', value: 'work' },
        { key: 'cal_hasUpcoming', op: 'eq', value: 'true' },
        { key: 'cal_nextMinutes', op: 'lte', value: '15' }
      ],
      defaultAction: { id: '', type: 'notification', payload: '📅 会议即将开始！准备好了吗？' },
      defaultCooldownMs: 3600000
    },
  ];

  // Dynamic templates from user's geofences
  @State dynamicTemplates: SceneTemplate[] = [];

  aboutToAppear(): void {
    this.log.info(TAG, 'Page opened');
    this.refreshRules();
    this.buildDynamicTemplates();
  }

  private buildDynamicTemplates(): void {
    try {
      let geofences = ContextAwarenessService.getInstance().getAllGeofences();
      let dynTpls: SceneTemplate[] = [];
      for (let i = 0; i < geofences.length; i++) {
        let gf = geofences[i];
        let catIcon = gf.category === 'home' ? '🏠' : gf.category === 'work' ? '🏢' :
          gf.category === 'gym' ? '💪' : gf.category === 'restaurant' ? '🍜' :
          gf.category === 'shopping' ? '🛒' : gf.category === 'transit' ? '🚇' : '📍';
        dynTpls.push({
          id: 'tpl_gf_' + gf.id,
          icon: catIcon,
          name: '到达' + gf.name,
          description: '连上' + gf.name + '的WiFi时触发',
          category: 'environment',
          tier: 1,
          conditions: [
            { key: 'wifiGeofence', op: 'eq', value: gf.category }
          ],
          defaultAction: { id: '', type: 'suggestion', payload: '到' + gf.name + '了！' + catIcon },
          defaultCooldownMs: 28800000
        });
      }
      this.dynamicTemplates = dynTpls;
    } catch (err) {
      this.dynamicTemplates = [];
    }
  }

  private refreshRules(): void {
    try {
      this.rules = this.engine.getAllRulesForDisplay();
    } catch (err) {
      this.log.error(TAG, 'refresh error: ' + (err as Error).message);
      this.rules = [];
    }
  }

  private getConditionSummary(conditions: ContextCondition[]): string {
    let parts: string[] = [];
    for (let i = 0; i < conditions.length; i++) {
      let c = conditions[i];
      let keyInfo = this.contextKeys.find((k: ContextKeyInfo) => k.key === c.key);
      let label = keyInfo ? keyInfo.label : c.key;
      let opSymbol: string = c.op === 'eq' ? '=' : c.op === 'neq' ? '≠' :
        c.op === 'gte' ? '≥' : c.op === 'lte' ? '≤' :
        c.op === 'gt' ? '>' : c.op === 'lt' ? '<' :
        c.op === 'in' ? '∈' : c.op;
      parts.push(`${label}${opSymbol}${c.value}`);
    }
    return parts.join(' & ');
  }

  private getTierLabel(rule: ContextRule): string {
    let tier = rule.tier ?? -1;
    if (tier === 0) return 'T0';
    if (tier === 1) return 'T1';
    if (tier === 2) return 'T2';
    return '';
  }

  private getTierColor(rule: ContextRule): string {
    let tier = rule.tier ?? -1;
    if (tier === 0) return '#34C759';  // green
    if (tier === 1) return '#007AFF';  // blue
    if (tier === 2) return '#FF9500';  // orange
    return '#999999';
  }

  // ===== Template mode =====
  private isTemplateAdded(tpl: SceneTemplate): boolean {
    for (let i = 0; i < this.rules.length; i++) {
      if (this.rules[i].name === tpl.name) return true;
    }
    return false;
  }

  private selectTemplate(tpl: SceneTemplate): void {
    this.selectedTemplate = tpl;
    this.templatePayload = tpl.defaultAction.payload;
  }

  private async saveFromTemplate(): Promise<void> {
    if (!this.selectedTemplate || this.templatePayload.length === 0) return;
    let tpl = this.selectedTemplate;
    let ts = Date.now().toString();
    let rule: ContextRule = {
      id: 'user_' + ts,
      name: tpl.name,
      tier: tpl.tier,
      category: tpl.category,
      conditions: tpl.conditions.slice(),
      action: {
        id: 'user_action_' + ts,
        type: tpl.defaultAction.type,
        payload: this.templatePayload
      },
      priority: 1.5,
      cooldownMs: tpl.defaultCooldownMs,
      enabled: true
    };
    let ok = await this.engine.addRule(rule);
    if (ok) {
      this.log.info(TAG, `Added rule from template: ${tpl.name}`);
    }
    this.selectedTemplate = null;
    this.templatePayload = '';
    this.refreshRules();
    // Stay on template tab so user sees "✅ 已添加"
  }

  // ===== Advanced mode =====
  private addConditionRow(): void {
    this.conditionRows = [...this.conditionRows, { keyIndex: 0, opIndex: 0, value: '' }];
  }

  private removeConditionRow(idx: number): void {
    let rows: ConditionRow[] = [];
    for (let i = 0; i < this.conditionRows.length; i++) {
      if (i !== idx) rows.push(this.conditionRows[i]);
    }
    this.conditionRows = rows;
  }

  private async doAddAdvanced(): Promise<void> {
    if (this.newName.length === 0 || this.conditionRows.length === 0 || this.actionPayload.length === 0) return;
    let ts = Date.now().toString();
    let conditions: ContextCondition[] = [];
    let opIds = ['eq', 'neq', 'gt', 'lt', 'gte', 'lte', 'in'];
    for (let i = 0; i < this.conditionRows.length; i++) {
      let row = this.conditionRows[i];
      if (row.value.length > 0 && row.keyIndex < this.contextKeys.length) {
        conditions.push({
          key: this.contextKeys[row.keyIndex].key,
          op: opIds[row.opIndex] || 'eq',
          value: row.value
        });
      }
    }
    if (conditions.length === 0) return;

    let rule: ContextRule = {
      id: 'user_' + ts,
      name: this.newName,
      conditions: conditions,
      action: {
        id: 'user_action_' + ts,
        type: this.actionTypeIds[this.actionType] || 'suggestion',
        payload: this.actionPayload
      },
      priority: 1.0,
      cooldownMs: this.cooldownOptions[this.selectedCooldown].value,
      enabled: true
    };
    let ok = await this.engine.addRule(rule);
    if (ok) {
      this.log.info(TAG, 'Added advanced rule: ' + rule.name);
    }
    this.resetAdvanced();
    this.activeTab = 0;
    this.refreshRules();
  }

  private resetAdvanced(): void {
    this.newName = '';
    this.conditionRows = [];
    this.actionType = 0;
    this.actionPayload = '';
    this.selectedCooldown = 3;
  }

  build() {
    Column() {
      // Header
      Row() {
        Text('←')
          .fontSize(22)
          .fontColor('#1A1A1A')
          .padding(8)
          .onClick(() => { router.back(); })
        Text('规则管理')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor('#1A1A1A')
          .layoutWeight(1)
      }
      .width('100%')
      .height(48)
      .padding({ left: 8, right: 8 })
      .backgroundColor(Color.White)

      // Tab bar
      Row({ space: 0 }) {
        this.TabButton('📋 规则', 0)
        this.TabButton('✨ 模板', 1)
        this.TabButton('⚙️ 高级', 2)
      }
      .width('100%')
      .padding({ left: 16, right: 16 })
      .backgroundColor(Color.White)

      // Content
      if (this.activeTab === 0) {
        this.RulesList()
      } else if (this.activeTab === 1) {
        this.TemplateList()
      } else {
        this.AdvancedForm()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#F2F2F7')
  }

  @Builder
  TabButton(label: string, index: number) {
    Text(label)
      .fontSize(13)
      .fontColor(this.activeTab === index ? '#007AFF' : '#666666')
      .fontWeight(this.activeTab === index ? FontWeight.Bold : FontWeight.Normal)
      .padding({ left: 12, right: 12, top: 10, bottom: 10 })
      .borderWidth({ bottom: this.activeTab === index ? 2 : 0 })
      .borderColor('#007AFF')
      .onClick(() => {
        this.activeTab = index;
        if (index === 0) this.refreshRules();
      })
  }

  // ==================== Tab 0: Rules List ====================
  @Builder
  RulesList() {
    Scroll() {
      Column({ space: 10 }) {
        if (this.rules.length === 0) {
          Text('暂无规则')
            .fontSize(14)
            .fontColor('#999999')
            .textAlign(TextAlign.Center)
            .padding(40)
            .width('100%')
        } else {
          ForEach(this.rules, (rule: ContextRule) => {
            Column({ space: 6 }) {
              Row() {
                // Tier badge
                if (this.getTierLabel(rule).length > 0) {
                  Text(this.getTierLabel(rule))
                    .fontSize(10)
                    .fontColor(Color.White)
                    .backgroundColor(this.getTierColor(rule))
                    .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                    .borderRadius(6)
                    .margin({ right: 6 })
                }

                Text(rule.name)
                  .fontSize(15)
                  .fontWeight(FontWeight.Medium)
                  .fontColor('#1A1A1A')
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })

                // Custom/Built-in badge
                Text(this.engine.isUserRule(rule.id) ? '自定义' : '内置')
                  .fontSize(10)
                  .fontColor(this.engine.isUserRule(rule.id) ? '#007AFF' : '#999999')
                  .backgroundColor(this.engine.isUserRule(rule.id) ? '#E6F0FF' : '#F0F0F0')
                  .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                  .borderRadius(8)
                  .margin({ right: 8 })

                Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
                  .selectedColor('#007AFF')
                  .onChange(async (isOn: boolean) => {
                    await this.engine.toggleRule(rule.id, isOn);
                    this.refreshRules();
                  })
              }
              .width('100%')

              Text(this.getConditionSummary(rule.conditions))
                .fontSize(12)
                .fontColor('#666666')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')

              Row() {
                Text(`${rule.action.type === 'alert' ? '⚠️' : rule.action.type === 'notification' ? '🔔' : '💡'} ${rule.action.payload}`)
                  .fontSize(12)
                  .fontColor('#999999')
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .layoutWeight(1)

                if (this.engine.isUserRule(rule.id)) {
                  Text('删除')
                    .fontSize(12)
                    .fontColor('#FF3B30')
                    .padding({ left: 8 })
                    .onClick(async () => {
                      await this.engine.removeRule(rule.id);
                      this.refreshRules();
                    })
                }
              }
              .width('100%')
            }
            .width('100%')
            .padding(14)
            .backgroundColor(Color.White)
            .borderRadius(12)
          }, (rule: ContextRule) => rule.id + '_' + (rule.enabled ? '1' : '0'))
        }
      }
      .padding({ left: 16, right: 16, top: 12, bottom: 40 })
    }
    .layoutWeight(1)
  }

  // ==================== Tab 1: Scene Templates ====================
  @Builder
  TemplateList() {
    if (this.selectedTemplate !== null) {
      // Template detail / customize
      this.TemplateDetail()
    } else {
      Scroll() {
        Column({ space: 10 }) {
          // Group by category
          Text('🧑 人（用户状态）')
            .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1A1A1A').padding({ top: 8, bottom: 4 }).width('100%')
          ForEach(this.templates.filter((t: SceneTemplate) => t.category === 'person'), (tpl: SceneTemplate) => {
            this.TemplateCard(tpl)
          }, (tpl: SceneTemplate) => tpl.id)

          Text('📱 手机（设备状态）')
            .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1A1A1A').padding({ top: 12, bottom: 4 }).width('100%')
          ForEach(this.templates.filter((t: SceneTemplate) => t.category === 'phone'), (tpl: SceneTemplate) => {
            this.TemplateCard(tpl)
          }, (tpl: SceneTemplate) => tpl.id)

          Text('🌍 环境（场景位置）')
            .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1A1A1A').padding({ top: 12, bottom: 4 }).width('100%')
          ForEach(this.templates.filter((t: SceneTemplate) => t.category === 'environment'), (tpl: SceneTemplate) => {
            this.TemplateCard(tpl)
          }, (tpl: SceneTemplate) => tpl.id)

          // Dynamic templates from geofences
          if (this.dynamicTemplates.length > 0) {
            Text('📍 我的地点')
              .fontSize(14).fontWeight(FontWeight.Bold).fontColor('#1A1A1A').padding({ top: 12, bottom: 4 }).width('100%')
            Text('基于已设置的围栏自动生成')
              .fontSize(11).fontColor('#999999').width('100%').margin({ bottom: 4 })
            ForEach(this.dynamicTemplates, (tpl: SceneTemplate) => {
              this.TemplateCard(tpl)
            }, (tpl: SceneTemplate) => tpl.id)
          }
        }
        .padding({ left: 16, right: 16, top: 8, bottom: 40 })
      }
      .layoutWeight(1)
    }
  }

  @Builder
  TemplateCard(tpl: SceneTemplate) {
    Row({ space: 12 }) {
      Text(tpl.icon)
        .fontSize(28)

      Column({ space: 2 }) {
        Row({ space: 6 }) {
          Text(tpl.name)
            .fontSize(15)
            .fontWeight(FontWeight.Medium)
            .fontColor('#1A1A1A')
          Text(`T${tpl.tier}`)
            .fontSize(10)
            .fontColor(Color.White)
            .backgroundColor(tpl.tier === 0 ? '#34C759' : tpl.tier === 1 ? '#007AFF' : '#FF9500')
            .padding({ left: 5, right: 5, top: 1, bottom: 1 })
            .borderRadius(4)
        }
        Text(tpl.description)
          .fontSize(12)
          .fontColor('#666666')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      if (this.isTemplateAdded(tpl)) {
        Text('✅ 已添加')
          .fontSize(13)
          .fontColor('#34C759')
      } else {
        Text('添加 →')
          .fontSize(13)
          .fontColor('#007AFF')
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(Color.White)
    .borderRadius(12)
    .onClick(() => {
      if (!this.isTemplateAdded(tpl)) {
        this.selectTemplate(tpl);
      }
    })
  }

  private getKeyLabel(key: string): string {
    let info = this.contextKeys.find((k: ContextKeyInfo) => k.key === key);
    return info ? info.label : key;
  }

  private getOpSymbol(op: string): string {
    if (op === 'eq') return '=';
    if (op === 'in') return '∈';
    if (op === 'gte') return '≥';
    if (op === 'lte') return '≤';
    if (op === 'neq') return '≠';
    if (op === 'gt') return '>';
    if (op === 'lt') return '<';
    return op;
  }

  @Builder
  TemplateDetail() {
    Scroll() {
      Column({ space: 14 }) {
        // Back
        Row() {
          Text('← 返回模板列表')
            .fontSize(14)
            .fontColor('#007AFF')
            .onClick(() => { this.selectedTemplate = null; })
        }
        .width('100%')

        // Template info
        Row({ space: 12 }) {
          Text(this.selectedTemplate!.icon).fontSize(36)
          Column({ space: 4 }) {
            Text(this.selectedTemplate!.name).fontSize(18).fontWeight(FontWeight.Bold).fontColor('#1A1A1A')
            Text(this.selectedTemplate!.description).fontSize(13).fontColor('#666666')
          }
        }
        .width('100%')

        // Conditions (read-only display)
        Text('触发条件')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1A1A1A').width('100%')

        Column({ space: 6 }) {
          ForEach(this.selectedTemplate!.conditions, (c: ContextCondition, idx: number) => {
            Row({ space: 6 }) {
              Text(this.getKeyLabel(c.key))
                .fontSize(13).fontColor('#333333')
              Text(this.getOpSymbol(c.op))
                .fontSize(13).fontColor('#007AFF')
              Text(c.value)
                .fontSize(13).fontColor('#333333')
                .backgroundColor('#F0F0F0')
                .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                .borderRadius(6)
            }
          }, (c: ContextCondition, idx: number) => 'tc_' + idx.toString())
        }
        .width('100%')
        .padding(12)
        .backgroundColor('#F8F8FC')
        .borderRadius(10)

        // Editable payload
        Text('提醒内容')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1A1A1A').width('100%')

        TextArea({ text: this.templatePayload, placeholder: '输入提醒内容...' })
          .onChange((val: string) => { this.templatePayload = val; })
          .width('100%')
          .height(80)
          .fontSize(14)
          .borderRadius(10)

        // Save
        Button('✅ 添加规则')
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor('#007AFF')
          .fontColor(Color.White)
          .borderRadius(10)
          .onClick(() => { this.saveFromTemplate(); })
      }
      .padding({ left: 16, right: 16, top: 12, bottom: 40 })
    }
    .layoutWeight(1)
  }

  // ==================== Tab 2: Advanced Form ====================
  @Builder
  AdvancedForm() {
    Scroll() {
      Column({ space: 12 }) {
        Text('自定义规则')
          .fontSize(16).fontWeight(FontWeight.Bold).fontColor('#1A1A1A').width('100%')

        // Rule name
        TextInput({ placeholder: '规则名称' })
          .onChange((val: string) => { this.newName = val; })
          .width('100%').height(44).borderRadius(10)

        // Conditions
        Text('触发条件')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1A1A1A').width('100%')

        ForEach(this.conditionRows, (row: ConditionRow, idx: number) => {
          Column({ space: 6 }) {
            Row({ space: 6 }) {
              // Key selector - show label with emoji
              Select(this.contextKeys.map((k: ContextKeyInfo) => {
                let item: SelectOption = { value: k.label };
                return item;
              }))
                .selected(row.keyIndex)
                .value(this.contextKeys[row.keyIndex]?.label || '选择...')
                .font({ size: 12 })
                .onSelect((index: number) => {
                  let cur = this.conditionRows[idx];
                  let newRows = this.conditionRows.slice();
                  newRows[idx] = { keyIndex: index, opIndex: cur.opIndex, value: '' };
                  this.conditionRows = newRows;
                })
                .layoutWeight(1)
                .height(36)

              // Op selector
              Select([
                { value: '=' } as SelectOption,
                { value: '≠' } as SelectOption,
                { value: '>' } as SelectOption,
                { value: '<' } as SelectOption,
                { value: '≥' } as SelectOption,
                { value: '≤' } as SelectOption,
                { value: '包含' } as SelectOption
              ])
                .selected(row.opIndex)
                .value(['=', '≠', '>', '<', '≥', '≤', '包含'][row.opIndex])
                .font({ size: 12 })
                .onSelect((index: number) => {
                  let cur = this.conditionRows[idx];
                  let newRows = this.conditionRows.slice();
                  newRows[idx] = { keyIndex: cur.keyIndex, opIndex: index, value: cur.value };
                  this.conditionRows = newRows;
                })
                .width(70)
                .height(36)

              Text('✖')
                .fontSize(16).fontColor('#FF3B30').padding(4)
                .onClick(() => { this.removeConditionRow(idx); })
            }
            .width('100%')

            // Value: show presets if available, otherwise text input
            if (this.contextKeys[row.keyIndex]?.presets && this.contextKeys[row.keyIndex].presets!.length > 0) {
              Flex({ wrap: FlexWrap.Wrap }) {
                ForEach(this.contextKeys[row.keyIndex].presets!, (preset: string) => {
                  Text(preset)
                    .fontSize(12)
                    .fontColor(row.value === preset ? Color.White : '#333333')
                    .backgroundColor(row.value === preset ? '#007AFF' : '#F0F0F0')
                    .padding({ left: 10, right: 10, top: 4, bottom: 4 })
                    .borderRadius(12)
                    .margin(3)
                    .onClick(() => {
                      let cur = this.conditionRows[idx];
                      let newRows = this.conditionRows.slice();
                      newRows[idx] = { keyIndex: cur.keyIndex, opIndex: cur.opIndex, value: preset };
                      this.conditionRows = newRows;
                    })
                }, (preset: string) => preset)
              }
              .width('100%')
            }

            TextInput({
              placeholder: this.contextKeys[row.keyIndex]?.hint || '值',
              text: row.value
            })
              .onChange((val: string) => {
                let cur = this.conditionRows[idx];
                let newRows = this.conditionRows.slice();
                newRows[idx] = { keyIndex: cur.keyIndex, opIndex: cur.opIndex, value: val };
                this.conditionRows = newRows;
              })
              .width('100%').height(36).fontSize(13).borderRadius(8)
          }
          .width('100%')
          .padding(10)
          .backgroundColor('#F8F8FC')
          .borderRadius(10)
        }, (row: ConditionRow, idx: number) => 'cr_' + idx.toString())

        Text('+ 添加条件')
          .fontSize(13).fontColor('#007AFF')
          .onClick(() => { this.addConditionRow(); })

        // Action type
        Text('动作类型')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1A1A1A').width('100%')

        Row({ space: 8 }) {
          ForEach(this.actionTypeLabels, (label: string, idx: number) => {
            Text(label)
              .fontSize(13)
              .fontColor(this.actionType === idx ? Color.White : '#1A1A1A')
              .backgroundColor(this.actionType === idx ? '#007AFF' : '#F0F0F0')
              .padding({ left: 14, right: 14, top: 8, bottom: 8 })
              .borderRadius(16)
              .onClick(() => { this.actionType = idx; })
          }, (label: string) => label)
        }

        // Action payload
        TextArea({ placeholder: '提醒内容...' })
          .onChange((val: string) => { this.actionPayload = val; })
          .width('100%').height(80).fontSize(14).borderRadius(10)

        // Cooldown
        Text('冷却时间')
          .fontSize(14).fontWeight(FontWeight.Medium).fontColor('#1A1A1A').width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.cooldownOptions, (opt: CooldownOption, idx: number) => {
            Text(opt.label)
              .fontSize(12)
              .fontColor(this.selectedCooldown === idx ? Color.White : '#1A1A1A')
              .backgroundColor(this.selectedCooldown === idx ? '#007AFF' : '#F0F0F0')
              .padding({ left: 12, right: 12, top: 6, bottom: 6 })
              .borderRadius(16)
              .margin(3)
              .onClick(() => { this.selectedCooldown = idx; })
          }, (opt: CooldownOption, idx: number) => 'cd_' + idx.toString())
        }
        .width('100%')

        // Save
        Button('✅ 保存规则')
          .width('100%')
          .height(44)
          .fontSize(15)
          .backgroundColor('#007AFF')
          .fontColor(Color.White)
          .borderRadius(10)
          .margin({ top: 8 })
          .onClick(() => { this.doAddAdvanced(); })
      }
      .padding({ left: 16, right: 16, top: 12, bottom: 40 })
    }
    .layoutWeight(1)
  }
}

/** Condition row state for advanced mode */
interface ConditionRow {
  keyIndex: number;
  opIndex: number;
  value: string;
}
