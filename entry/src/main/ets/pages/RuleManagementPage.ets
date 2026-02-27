/**
 * RuleManagementPage — 规则管理页面
 * 功能：查看/开关/删除规则，添加自定义规则
 */
import { router } from '@kit.ArkUI';
import { LogService } from '../common/LogService';
import { I18n } from '../common/I18n';
import { ContextEngineService, ContextRule, ContextCondition, ContextAction } from '../service/context/ContextEngine';

interface CooldownOption {
  label: string;
  value: number;
}

@Entry
@Component
struct RuleManagementPage {
  private log: LogService = LogService.getInstance();
  private engine: ContextEngineService = ContextEngineService.getInstance();

  @State rules: ContextRule[] = [];
  @State showAddDialog: boolean = false;

  // Add form state
  @State newName: string = '';
  @State conditionKeys: string[] = [];
  @State conditionOps: string[] = [];
  @State conditionValues: string[] = [];
  @State actionType: number = 0;  // 0=suggestion, 1=notification
  @State actionPayload: string = '';
  @State selectedCooldown: number = 3;  // index in cooldownOptions

  private contextKeyIds: string[] = ['timeOfDay', 'hour', 'dayOfWeek', 'isWeekend', 'motionState', 'batteryLevel', 'isCharging', 'networkType', 'geofence'];
  @State contextKeyLabels: string[] = [];
  private opIds: string[] = ['eq', 'neq', 'gt', 'lt', 'gte', 'lte', 'in'];
  @State opLabels: string[] = [];
  @State actionTypes: string[] = [];
  @State cooldownOptions: CooldownOption[] = [];

  aboutToAppear(): void {
    this.log.info('RuleMgmt', 'Page opened');
    // Initialize i18n labels
    this.contextKeyLabels = this.contextKeyIds.map((id: string) => I18n.t('rules.key.' + id));
    this.opLabels = ['=', '\u2260', '>', '<', '\u2265', '\u2264', I18n.t('rules.opContains')];
    this.actionTypes = [I18n.t('rules.suggestion'), I18n.t('rules.notification')];
    this.cooldownOptions = [
      { label: I18n.t('rules.cooldown30m'), value: 1800000 },
      { label: I18n.t('rules.cooldown1h'), value: 3600000 },
      { label: I18n.t('rules.cooldown2h'), value: 7200000 },
      { label: I18n.t('rules.cooldown4h'), value: 14400000 },
      { label: I18n.t('rules.cooldown8h'), value: 28800000 },
      { label: I18n.t('rules.cooldown24h'), value: 86400000 },
    ];
    this.refreshRules();
  }

  private refreshRules(): void {
    try {
      this.rules = this.engine.getAllRulesForDisplay();
    } catch (err) {
      this.log.error('RuleMgmt', 'refresh error: ' + (err as Error).message);
      this.rules = [];
    }
  }

  private getConditionSummary(conditions: ContextCondition[]): string {
    let opSymbols: Record<string, string> = {
      'eq': '=', 'neq': '\u2260', 'gt': '>', 'lt': '<', 'gte': '\u2265', 'lte': '\u2264', 'in': '\u2208'
    };
    let parts: string[] = [];
    for (let i = 0; i < conditions.length; i++) {
      let c = conditions[i];
      let kl = I18n.t('rules.key.' + c.key + '.short');
      if (kl.startsWith('rules.key.')) kl = c.key;
      let ol = opSymbols[c.op] || c.op;
      parts.push(kl + ol + c.value);
    }
    return parts.join(' & ');
  }

  private getRuleName(rule: ContextRule): string {
    let key = 'rule.name.' + rule.id;
    let localized = I18n.t(key);
    return localized !== key ? localized : rule.name;
  }

  private async handleToggle(ruleId: string, enabled: boolean): Promise<void> {
    let ok = await this.engine.toggleRule(ruleId, enabled);
    if (ok) {
      this.refreshRules();
    }
  }

  private async handleDelete(ruleId: string): Promise<void> {
    let ok = await this.engine.removeRule(ruleId);
    if (ok) {
      this.refreshRules();
    }
  }

  private resetForm(): void {
    this.newName = '';
    this.conditionKeys = [];
    this.conditionOps = [];
    this.conditionValues = [];
    this.actionType = 0;
    this.actionPayload = '';
    this.selectedCooldown = 3;
  }

  private addConditionRow(): void {
    this.conditionKeys = [...this.conditionKeys, 'timeOfDay'];
    this.conditionOps = [...this.conditionOps, 'eq'];
    this.conditionValues = [...this.conditionValues, ''];
  }

  private removeConditionRow(idx: number): void {
    let keys: string[] = [];
    let ops: string[] = [];
    let vals: string[] = [];
    for (let i = 0; i < this.conditionKeys.length; i++) {
      if (i !== idx) {
        keys.push(this.conditionKeys[i]);
        ops.push(this.conditionOps[i]);
        vals.push(this.conditionValues[i]);
      }
    }
    this.conditionKeys = keys;
    this.conditionOps = ops;
    this.conditionValues = vals;
  }

  private async doAddRule(): Promise<void> {
    if (this.newName.length === 0 || this.conditionKeys.length === 0 || this.actionPayload.length === 0) {
      return;
    }

    let ts = Date.now().toString();
    let conditions: ContextCondition[] = [];
    for (let i = 0; i < this.conditionKeys.length; i++) {
      if (i < this.conditionOps.length && i < this.conditionValues.length && this.conditionValues[i].length > 0) {
        conditions.push({ key: this.conditionKeys[i], op: this.conditionOps[i], value: this.conditionValues[i] });
      }
    }
    if (conditions.length === 0) return;

    let actionTypeStr = this.actionType === 0 ? 'suggestion' : 'notification';
    let action: ContextAction = {
      id: 'user_action_' + ts,
      type: actionTypeStr,
      payload: this.actionPayload
    };

    let rule: ContextRule = {
      id: 'user_' + ts,
      name: this.newName,
      conditions: conditions,
      action: action,
      priority: 1.0,
      cooldownMs: this.cooldownOptions[this.selectedCooldown].value,
      enabled: true
    };

    let ok = await this.engine.addRule(rule);
    if (ok) {
      this.log.info('RuleMgmt', 'Added rule: ' + rule.name);
    }
    this.showAddDialog = false;
    this.resetForm();
    this.refreshRules();
  }

  build() {
    Stack() {
      Column() {
        // Header
        Row() {
          Text('\u2190')
            .fontSize(22)
            .fontColor('#1A1A1A')
            .padding(8)
            .onClick(() => { router.back(); })
          Text(I18n.t('rules.title'))
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor('#1A1A1A')
            .layoutWeight(1)
          Text(I18n.t('rules.addRule'))
            .fontSize(14)
            .fontColor('#007AFF')
            .padding(8)
            .onClick(() => {
              this.resetForm();
              this.addConditionRow();
              this.showAddDialog = true;
            })
        }
        .width('100%')
        .height(48)
        .padding({ left: 8, right: 8 })
        .backgroundColor(Color.White)

        // Rule list
        Scroll() {
          Column({ space: 12 }) {
            if (this.rules.length === 0) {
              Text(I18n.t('rules.empty'))
                .fontSize(14)
                .fontColor('#999999')
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding(40)
            } else {
              ForEach(this.rules, (rule: ContextRule) => {
                Column() {
                  Row() {
                    Column({ space: 4 }) {
                      Row({ space: 6 }) {
                        Text(this.getRuleName(rule))
                          .fontSize(15)
                          .fontWeight(FontWeight.Medium)
                          .fontColor('#1A1A1A')
                          .layoutWeight(1)
                          .maxLines(1)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                        Text(this.engine.isUserRule(rule.id) ? I18n.t('rules.custom') : I18n.t('rules.builtin'))
                          .fontSize(11)
                          .fontColor(this.engine.isUserRule(rule.id) ? '#007AFF' : '#999999')
                          .backgroundColor(this.engine.isUserRule(rule.id) ? '#E6F0FF' : '#F0F0F0')
                          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
                          .borderRadius(8)
                      }
                      .width('100%')

                      Text(this.getConditionSummary(rule.conditions))
                        .fontSize(12)
                        .fontColor('#666666')
                        .maxLines(2)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })

                      Text((rule.action.type === 'notification' ? I18n.t('rules.notification') : I18n.t('rules.suggestion')) + ': ' + rule.action.payload)
                        .fontSize(12)
                        .fontColor('#999999')
                        .maxLines(1)
                        .textOverflow({ overflow: TextOverflow.Ellipsis })
                    }
                    .layoutWeight(1)
                    .alignItems(HorizontalAlign.Start)

                    Column({ space: 8 }) {
                      Toggle({ type: ToggleType.Switch, isOn: rule.enabled })
                        .selectedColor('#007AFF')
                        .onChange((isOn: boolean) => {
                          this.handleToggle(rule.id, isOn);
                        })

                      if (this.engine.isUserRule(rule.id)) {
                        Text(I18n.t('rules.delete'))
                          .fontSize(12)
                          .fontColor('#FF3B30')
                          .onClick(() => { this.handleDelete(rule.id); })
                      }
                    }
                    .alignItems(HorizontalAlign.Center)
                    .justifyContent(FlexAlign.Center)
                  }
                  .width('100%')
                }
                .width('100%')
                .padding(14)
                .backgroundColor(Color.White)
                .borderRadius(12)
              }, (rule: ContextRule) => rule.id)
            }
          }
          .padding({ left: 16, right: 16, top: 12, bottom: 40 })
        }
        .layoutWeight(1)
        .backgroundColor('#F2F2F7')
      }
      .width('100%')
      .height('100%')

      // ===== Add rule dialog =====
      if (this.showAddDialog) {
        Column() {
          Scroll() {
            Column({ space: 12 }) {
              Text(I18n.t('rules.addCustom'))
                .fontSize(18)
                .fontWeight(FontWeight.Bold)
                .fontColor('#1A1A1A')

              // Rule name
              TextInput({ placeholder: I18n.t('rules.namePlaceholder') })
                .onChange((val: string) => { this.newName = val; })
                .width('100%')
                .height(44)

              // Conditions section
              Text(I18n.t('rules.conditions'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
                .width('100%')

              ForEach(this.conditionKeys, (key: string, idx: number) => {
                Row({ space: 6 }) {
                  // Key selector
                  Select(this.contextKeyLabels.map((label: string) => {
                    let item: SelectOption = { value: label };
                    return item;
                  }))
                    .selected(this.contextKeyIds.indexOf(key))
                    .value(this.contextKeyLabels[this.contextKeyIds.indexOf(key)] || I18n.t('rules.key.timeOfDay'))
                    .font({ size: 13 })
                    .onSelect((index: number) => {
                      let newKeys = this.conditionKeys.slice();
                      newKeys[idx] = this.contextKeyIds[index];
                      this.conditionKeys = newKeys;
                    })
                    .width(90)
                    .height(36)

                  // Op selector
                  Select(this.opLabels.map((label: string) => {
                    let item: SelectOption = { value: label };
                    return item;
                  }))
                    .selected(idx < this.conditionOps.length ? this.opIds.indexOf(this.conditionOps[idx]) : 0)
                    .value(idx < this.conditionOps.length ? (this.opLabels[this.opIds.indexOf(this.conditionOps[idx])] || '=') : '=')
                    .font({ size: 13 })
                    .onSelect((index: number) => {
                      let newOps = this.conditionOps.slice();
                      newOps[idx] = this.opIds[index];
                      this.conditionOps = newOps;
                    })
                    .width(70)
                    .height(36)

                  // Value input
                  TextInput({ placeholder: I18n.t('rules.value'), text: idx < this.conditionValues.length ? this.conditionValues[idx] : '' })
                    .onChange((val: string) => {
                      let newVals = this.conditionValues.slice();
                      newVals[idx] = val;
                      this.conditionValues = newVals;
                    })
                    .layoutWeight(1)
                    .height(36)
                    .fontSize(13)

                  // Remove button
                  Text('\u2716')
                    .fontSize(16)
                    .fontColor('#FF3B30')
                    .padding(4)
                    .onClick(() => { this.removeConditionRow(idx); })
                }
                .width('100%')
              }, (key: string, idx: number) => 'cond_' + idx.toString())

              Text(I18n.t('rules.addCondition'))
                .fontSize(13)
                .fontColor('#007AFF')
                .onClick(() => { this.addConditionRow(); })

              // Action type
              Text(I18n.t('rules.actionType'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
                .width('100%')

              Row({ space: 8 }) {
                ForEach(this.actionTypes, (label: string, idx: number) => {
                  Text(label)
                    .fontSize(13)
                    .fontColor(this.actionType === idx ? Color.White : '#1A1A1A')
                    .backgroundColor(this.actionType === idx ? '#007AFF' : '#F0F0F0')
                    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
                    .borderRadius(16)
                    .onClick(() => { this.actionType = idx; })
                }, (label: string) => label)
              }

              // Action payload
              TextInput({ placeholder: I18n.t('rules.payloadPlaceholder') })
                .onChange((val: string) => { this.actionPayload = val; })
                .width('100%')
                .height(44)

              // Cooldown
              Text(I18n.t('rules.cooldown'))
                .fontSize(14)
                .fontWeight(FontWeight.Medium)
                .fontColor('#1A1A1A')
                .width('100%')

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

              // Buttons
              Row({ space: 12 }) {
                Button(I18n.t('rules.cancel'))
                  .fontSize(14)
                  .backgroundColor('#F0F0F0')
                  .fontColor('#1A1A1A')
                  .layoutWeight(1)
                  .onClick(() => { this.showAddDialog = false; })
                Button(I18n.t('rules.save'))
                  .fontSize(14)
                  .backgroundColor('#007AFF')
                  .fontColor(Color.White)
                  .layoutWeight(1)
                  .onClick(() => { this.doAddRule(); })
              }
              .width('100%')
              .margin({ top: 8 })
            }
            .width('100%')
            .padding(20)
          }
          .width('85%')
          .constraintSize({ maxHeight: '80%' })
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
}
