/**
 * ActionPlugin.ets — 动作插件统一接口
 *
 * 所有推荐动作通过插件实现，统一接口：
 * - canHandle(action): 是否能处理该动作
 * - execute(action): 执行动作，返回结果
 * - getDisplayInfo(action): 获取动作的展示信息（用于 A2UI 卡片）
 */
import { UserAction, ActionType } from '../ContextModels';

/** 动作执行结果 */
export interface ActionResult {
  success: boolean;
  message: string;          // 结果文本（显示给用户）
  actionType: string;       // 动作类型标识
  a2uiCard?: string;        // 可选：结果 A2UI 卡片 JSONL
}

/** 动作展示信息（用于推荐卡片按钮） */
export interface ActionDisplayInfo {
  title: string;            // 按钮标题
  subtitle?: string;        // 副标题/描述
  emoji?: string;           // 图标
}

/** 动作插件接口 */
export interface ActionPlugin {
  /** 插件名称 */
  readonly name: string;

  /** 支持的动作类型 */
  readonly supportedTypes: ActionType[];

  /** 是否能处理该动作 */
  canHandle(action: UserAction): boolean;

  /** 执行动作 */
  execute(action: UserAction): Promise<ActionResult>;

  /** 获取展示信息（可选覆盖，默认由 ActionRouter 生成） */
  getDisplayInfo?(action: UserAction): ActionDisplayInfo;
}
