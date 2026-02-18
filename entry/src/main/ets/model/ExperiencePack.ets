// ============================================================
//  Experience Pack — skills + memory = experience
//  skills: 做事的方式（步骤、规则）
//  memory: 过程中的细节（事实、上下文）
//  两者结合构成完整的经验，可迁移到新的 AI 助理
// ============================================================

/** 技能：总结做事的方式（与 OpenClaw skill 格式一致）*/
export interface Skill {
  name: string;           // 技能名称，如 "clawdbot-harmony-dev"
  description: string;    // 简短描述
  content: string;        // Markdown 内容（技能指令）
  metadata?: SkillMetadata; // 可选元数据
}

/** 技能元数据 */
export interface SkillMetadata {
  emoji?: string;         // 图标
  confidence?: number;    // 置信度 0-1
  source?: string;        // 来源：'learned' | 'imported' | 'manual'
  updatedAt?: number;     // 最后更新时间
}

/** 记忆分类 */
export type MemoryCategory = 'user' | 'relationship' | 'project' | 'fact' | 'preference';

/** 记忆：记住过程中的细节 */
export interface Memory {
  id: string;
  category: MemoryCategory;
  key: string;            // 如 "项目路径" / "当前版本" / "妻子"
  value: string | object; // 具体值
  updatedAt: number;      // 最后更新时间
}

/** 经验包：skills + memory */
export interface ExperiencePack {
  version: number;        // schema 版本
  updatedAt: number;      // 最后更新时间
  syncedAt: number;       // 最后同步时间 (0 = 未同步)

  skills: Skill[];        // 技能列表
  memory: Memory[];       // 记忆列表
}

/** 生成唯一 ID */
export function generateId(): string {
  return Date.now().toString(36) + Math.random().toString(36).substring(2, 8);
}

/** 创建空的经验包 */
export function createDefaultExperiencePack(): ExperiencePack {
  return {
    version: 2,
    updatedAt: Date.now(),
    syncedAt: 0,
    skills: [],
    memory: [],
  };
}

/** 创建新技能 */
export function createSkill(name: string, description: string, content: string): Skill {
  return {
    name,
    description,
    content,
    metadata: {
      confidence: 0.5,
      source: 'learned',
      updatedAt: Date.now(),
    },
  };
}

/** 创建新记忆 */
export function createMemory(category: MemoryCategory, key: string, value: string | object): Memory {
  return {
    id: generateId(),
    category,
    key,
    value,
    updatedAt: Date.now(),
  };
}
