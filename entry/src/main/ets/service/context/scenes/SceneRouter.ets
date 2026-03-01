/**
 * SceneRouter.ets — 场景路由器
 *
 * 管理所有 ScenePlugin，评估当前快照，返回匹配场景和推荐。
 * 与 C++ RuleEngine 并行运行：RuleEngine 处理简单条件规则，
 * SceneRouter 处理复杂场景逻辑（多条件组合、时间窗口、外部数据）。
 */
import { ContextSnapshot } from '../ContextEngine';
import { ScenePlugin, SceneMatch, SceneAction, SceneActionResult } from './ScenePlugin';
import { LogService } from '../../../common/LogService';

const TAG = 'SceneRouter';

/** 场景评估结果：匹配 + 推荐 */
export interface SceneEvaluation {
  match: SceneMatch;
  recommendations: SceneAction[];
  plugin: ScenePlugin;
}

export class SceneRouter {
  private plugins: ScenePlugin[] = [];
  private log: LogService = LogService.getInstance();
  private cooldowns: Map<string, number> = new Map();
  private defaultCooldownMs: number = 10 * 60 * 1000; // 10 min

  /** 注册场景插件 */
  register(plugin: ScenePlugin): void {
    this.plugins.push(plugin);
    this.log.info(TAG, `注册场景: ${plugin.emoji} ${plugin.name} (${plugin.id})`);
  }

  /** 获取所有已注册插件 */
  getPlugins(): ScenePlugin[] {
    return this.plugins;
  }

  /**
   * 评估所有场景，返回匹配结果（按 priority 排序）
   * 最多返回 maxResults 个
   */
  evaluate(snapshot: ContextSnapshot, maxResults: number = 3): SceneEvaluation[] {
    let results: SceneEvaluation[] = [];
    let now = Date.now();

    for (let i = 0; i < this.plugins.length; i++) {
      let plugin = this.plugins[i];

      // Cooldown 检查
      let lastTrigger = this.cooldowns.get(plugin.id) ?? 0;
      if (now - lastTrigger < this.defaultCooldownMs) continue;

      try {
        let match = plugin.detectScene(snapshot);
        if (match !== null && match.confidence > 0) {
          let recs = plugin.getRecommendations(match, snapshot);
          if (recs.length > 0) {
            results.push({ match, recommendations: recs, plugin });
          }
        }
      } catch (err) {
        this.log.warn(TAG, `场景 ${plugin.id} 检测失败: ${(err as Error).message}`);
      }
    }

    // 按 priority * confidence 排序
    results.sort((a: SceneEvaluation, b: SceneEvaluation): number => {
      let scoreA = a.match.priority * a.match.confidence;
      let scoreB = b.match.priority * b.match.confidence;
      return scoreB - scoreA;
    });

    if (results.length > maxResults) {
      results = results.slice(0, maxResults);
    }

    return results;
  }

  /** 执行动作 */
  async executeAction(sceneId: string, actionId: string, match: SceneMatch): Promise<SceneActionResult> {
    let plugin = this.plugins.find((p: ScenePlugin) => p.id === sceneId);
    if (!plugin) {
      return { success: false, message: `未知场景: ${sceneId}` };
    }

    this.log.info(TAG, `执行: ${plugin.emoji} ${plugin.name} → ${actionId}`);
    try {
      let result = await plugin.executeAction(actionId, match);
      // 设置 cooldown
      this.cooldowns.set(sceneId, Date.now());
      return result;
    } catch (err) {
      return { success: false, message: `执行失败: ${(err as Error).message}` };
    }
  }

  /** 设置场景 cooldown */
  setCooldown(sceneId: string, ms: number): void {
    this.cooldowns.set(sceneId, Date.now() + ms - this.defaultCooldownMs);
  }
}
