/**
 * ActionRouter.ets — 动作路由器（替代原 ActionExecutor）
 *
 * 管理所有 ActionPlugin，根据动作类型路由到对应插件执行。
 * 插件注册后自动生效，新增动作只需添加新插件。
 */
import { UserAction } from '../ContextModels';
import { ActionPlugin, ActionResult, ActionDisplayInfo } from './ActionPlugin';
import { LogService } from '../../../common/LogService';

const TAG = 'ActionRouter';

export class ActionRouter {
  private plugins: ActionPlugin[] = [];
  private log: LogService = LogService.getInstance();

  /** 注册插件 */
  register(plugin: ActionPlugin): void {
    this.plugins.push(plugin);
    this.log.info(TAG, `注册插件: ${plugin.name} (${plugin.supportedTypes.join(', ')})`);
  }

  /** 获取所有已注册插件 */
  getPlugins(): ActionPlugin[] {
    return this.plugins;
  }

  /** 查找能处理该动作的插件 */
  findPlugin(action: UserAction): ActionPlugin | null {
    for (let i = 0; i < this.plugins.length; i++) {
      if (this.plugins[i].canHandle(action)) {
        return this.plugins[i];
      }
    }
    return null;
  }

  /** 执行动作 */
  async execute(action: UserAction): Promise<ActionResult> {
    let plugin = this.findPlugin(action);
    if (!plugin) {
      this.log.warn(TAG, `无插件处理动作: type=${action.type}, target=${action.target ?? ''}`);
      return {
        success: false,
        message: `⚠️ 暂不支持该操作类型: ${action.type}`,
        actionType: action.type
      };
    }

    this.log.info(TAG, `路由动作到 ${plugin.name}: type=${action.type}, target=${action.target ?? ''}`);
    try {
      return await plugin.execute(action);
    } catch (err) {
      this.log.warn(TAG, `插件 ${plugin.name} 执行失败: ${(err as Error).message}`);
      return {
        success: false,
        message: `执行失败: ${(err as Error).message}`,
        actionType: action.type
      };
    }
  }

  /** 获取动作展示信息 */
  getDisplayInfo(action: UserAction): ActionDisplayInfo {
    let plugin = this.findPlugin(action);
    if (plugin && plugin.getDisplayInfo) {
      return plugin.getDisplayInfo(action);
    }
    // 默认展示信息
    return {
      title: action.target ?? action.type,
      emoji: '💡'
    };
  }
}
