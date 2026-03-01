/**
 * ScenePlugin.ets — 场景插件统一接口
 *
 * 三层一体：场景检测 + 推荐生成 + 动作执行
 * 每个场景（机场、家、公司等）是一个独立插件。
 *
 * Architecture:
 *   SceneRouter.evaluate(snapshot)
 *     → for each plugin: plugin.detectScene(snapshot)
 *     → collect SceneMatch[] (sorted by priority)
 *     → top match: plugin.getRecommendations(match)
 *     → user selects action
 *     → plugin.executeAction(action)
 */
import { ContextSnapshot } from '../ContextEngine';

/** 场景匹配结果 */
export interface SceneMatch {
  sceneId: string;          // 场景插件 ID
  sceneName: string;        // 场景名称（显示用）
  priority: number;         // 优先级（越高越优先）
  confidence: number;       // 0-1 匹配置信度
  stateDescription: string; // 状态描述文字（A2UI 状态区）
  emoji: string;            // 场景图标
  metadata?: Record<string, string>; // 额外数据（航班号、地点名等）
}

/** 推荐动作 */
export interface SceneAction {
  id: string;               // 动作 ID
  label: string;            // 按钮文字（显示用）
  emoji: string;            // 按钮图标
  description?: string;     // 动作描述
  urgent?: boolean;         // 是否紧急（红色高亮）
}

/** 动作执行结果 */
export interface SceneActionResult {
  success: boolean;
  message: string;          // 结果文字
  a2uiCard?: string;        // 可选：结果 A2UI 卡片
}

/** 场景插件接口 */
export interface ScenePlugin {
  /** 插件唯一 ID */
  readonly id: string;

  /** 场景名称 */
  readonly name: string;

  /** 场景图标 */
  readonly emoji: string;

  /**
   * 检测当前是否匹配该场景
   * 返回 null 表示不匹配
   */
  detectScene(snapshot: ContextSnapshot): SceneMatch | null;

  /**
   * 生成推荐动作列表（最多 3 个）
   * match 是 detectScene 返回的匹配结果
   */
  getRecommendations(match: SceneMatch, snapshot: ContextSnapshot): SceneAction[];

  /**
   * 执行用户选择的动作
   */
  executeAction(actionId: string, match: SceneMatch): Promise<SceneActionResult>;
}
