// ============================================================
//  Experience Pack — 经验包
//  一条经验 = 几个 skills + 几条 memory
//  分享时 skills 和 memory 分别管理权限
// ============================================================

/** 分享权限级别 */
export type ShareLevel = 'public' | 'summary' | 'private';
// 🟢 public  - 完整分享
// 🟡 summary - 只分享名称/描述，不分享具体内容
// 🔴 private - 不分享

/** 技能（与 Anthropic skills 格式一致）*/
export interface Skill {
  name: string;           // 技能名称（唯一标识）
  description: string;    // 简短描述
  instructions: string;   // 执行指令 (markdown)
  shareLevel: ShareLevel; // 分享权限，默认 'public'
  lastModified?: number;  // 最后修改时间戳（同步用）
  deletedAt?: number;     // 删除时间戳（tombstone，0 = 未删除）
}

/** 记忆 */
export interface Memory {
  key: string;            // 如 "项目路径" / "当前版本"（唯一标识）
  value: string;          // 具体值
  shareLevel: ShareLevel; // 分享权限，默认 'private'
  lastModified?: number;  // 最后修改时间戳（同步用）
  deletedAt?: number;     // 删除时间戳（tombstone，0 = 未删除）
}

/** 一条经验 = skills + memory */
export interface Experience {
  id: string;
  name: string;           // 经验名称，如 "ClawdBotHarmony 开发"
  description: string;    // 简述
  skills: Skill[];        // 相关技能
  memory: Memory[];       // 相关记忆
  createdAt: number;
  updatedAt: number;
}

/** 经验包 */
export interface ExperiencePack {
  version: number;        // schema 版本
  updatedAt: number;      // 最后更新时间
  syncedAt: number;       // 最后同步时间 (0 = 未同步)
  experiences: Experience[];
}

/** 生成唯一 ID */
export function generateId(): string {
  return Date.now().toString(36) + Math.random().toString(36).substring(2, 8);
}

/** 创建空的经验包 */
export function createDefaultExperiencePack(): ExperiencePack {
  return {
    version: 3,
    updatedAt: Date.now(),
    syncedAt: 0,
    experiences: [],
  };
}

/** 创建新经验 */
export function createExperience(name: string, description: string): Experience {
  return {
    id: generateId(),
    name,
    description,
    skills: [],
    memory: [],
    createdAt: Date.now(),
    updatedAt: Date.now(),
  };
}

/** 创建新技能 (默认公开分享) */
export function createSkill(name: string, description: string, instructions: string): Skill {
  return {
    name,
    description,
    instructions,
    shareLevel: 'public',
    lastModified: Date.now(),
    deletedAt: 0,
  };
}

/** 创建新记忆 (默认私密) */
export function createMemory(key: string, value: string): Memory {
  return {
    key,
    value,
    shareLevel: 'private',
    lastModified: Date.now(),
    deletedAt: 0,
  };
}

/** 获取未删除的技能 */
export function getActiveSkills(exp: Experience): Skill[] {
  return exp.skills.filter((s: Skill) => !s.deletedAt || s.deletedAt === 0);
}

/** 获取未删除的记忆 */
export function getActiveMemories(exp: Experience): Memory[] {
  return exp.memory.filter((m: Memory) => !m.deletedAt || m.deletedAt === 0);
}

/** 获取分享级别图标 */
export function getShareLevelIcon(level: ShareLevel): string {
  switch (level) {
    case 'public': return '🟢';
    case 'summary': return '🟡';
    case 'private': return '🔴';
    default: return '⚪';
  }
}

/** 获取分享级别文字 */
export function getShareLevelText(level: ShareLevel): string {
  switch (level) {
    case 'public': return '公开';
    case 'summary': return '摘要';
    case 'private': return '私密';
    default: return '未知';
  }
}
