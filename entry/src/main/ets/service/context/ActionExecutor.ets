/**
 * ActionExecutor.ets — 推荐动作执行器（基于插件路由）
 *
 * 保留原有接口 execute(action)，内部委托给 ActionRouter。
 * 向后兼容：NodeRuntime 等调用方无需修改。
 */
import { CalendarPlugin } from './plugins/CalendarPlugin';
import { UserAction } from './ContextModels';
import { ActionRouter } from './actions/ActionRouter';
import { ActionResult } from './actions/ActionPlugin';
import { NotificationPlugin } from './actions/NotificationPlugin';
import { ModeChangePlugin } from './actions/ModeChangePlugin';
import { CalendarInfoPlugin } from './actions/CalendarInfoPlugin';
import { TravelInfoPlugin } from './actions/TravelInfoPlugin';
import { AppLaunchPlugin } from './actions/AppLaunchPlugin';
import { QRCodePlugin } from './actions/QRCodePlugin';
import { SmartActionPlugin } from './actions/SmartActionPlugin';
import { LogService } from '../../common/LogService';
import { common } from '@kit.AbilityKit';

const TAG = 'ActionExecutor';

export { ActionResult } from './actions/ActionPlugin';

export class ActionExecutor {
  private router: ActionRouter;
  private log: LogService = LogService.getInstance();
  private appLaunchPlugin: AppLaunchPlugin;
  private smartActionPlugin: SmartActionPlugin;

  constructor(calendarPlugin?: CalendarPlugin) {
    this.router = new ActionRouter();

    // 注册内置插件（顺序决定优先级：先注册的优先匹配）
    // SmartActionPlugin 最先注册：有 function 标签的动作优先路由到这里
    this.smartActionPlugin = new SmartActionPlugin();
    this.smartActionPlugin.setCalendarPlugin(calendarPlugin);
    this.router.register(this.smartActionPlugin);
    if (calendarPlugin) {
      this.router.register(new CalendarInfoPlugin(calendarPlugin));
    }
    this.router.register(new TravelInfoPlugin());
    this.router.register(new NotificationPlugin());
    this.router.register(new ModeChangePlugin());
    this.appLaunchPlugin = new AppLaunchPlugin();
    this.router.register(this.appLaunchPlugin);
    this.router.register(new QRCodePlugin());

    this.log.info(TAG, `初始化完成，${this.router.getPlugins().length} 个插件已注册`);
  }

  /** 设置 UIAbilityContext（用于 AppLaunchPlugin） */
  setContext(context: common.UIAbilityContext): void {
    this.appLaunchPlugin.setContext(context);
  }



  /** 获取路由器（用于外部注册自定义插件） */
  getRouter(): ActionRouter {
    return this.router;
  }

  /** 执行动作（向后兼容接口） */
  async execute(action: UserAction): Promise<ActionResult> {
    return await this.router.execute(action);
  }
}
