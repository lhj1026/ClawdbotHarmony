/**
 * ExperienceStorage — 经验包存储服务
 * skills (技能) + memory (记忆) = experience (经验)
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';
import {
  ExperiencePack,
  Skill,
  SkillMetadata,
  Memory,
  MemoryCategory,
  createDefaultExperiencePack,
  generateId,
} from '../model/ExperiencePack';

const TAG = 'ExperienceStorage';
const STORE_KEY = 'experience_pack_v2';

export class ExperienceStorage {
  private static instance: ExperienceStorage | undefined = undefined;
  private log: LogService = LogService.getInstance();
  private _pack: ExperiencePack | undefined = undefined;

  static getInstance(): ExperienceStorage {
    if (!ExperienceStorage.instance) {
      ExperienceStorage.instance = new ExperienceStorage();
    }
    return ExperienceStorage.instance;
  }

  get pack(): ExperiencePack | undefined {
    return this._pack;
  }

  // ==================== 核心存储 ====================

  async load(context: common.UIAbilityContext): Promise<ExperiencePack | null> {
    try {
      let store = await preferences.getPreferences(context, Constants.PREFS_EXPERIENCE);
      let json = (await store.get(STORE_KEY, '')) as string;
      if (json.length === 0) {
        this.log.info(TAG, 'No experience pack found');
        return null;
      }
      let parsed: ExperiencePack = JSON.parse(json) as ExperiencePack;
      this._pack = parsed;
      this.log.info(TAG, `Loaded: ${parsed.skills.length} skills, ${parsed.memory.length} memories`);
      return parsed;
    } catch (err) {
      this.log.error(TAG, `Load failed: ${(err as Error).message ?? ''}`);
      return null;
    }
  }

  async save(context: common.UIAbilityContext, pack: ExperiencePack): Promise<void> {
    try {
      pack.updatedAt = Date.now();
      let store = await preferences.getPreferences(context, Constants.PREFS_EXPERIENCE);
      await store.put(STORE_KEY, JSON.stringify(pack));
      await store.flush();
      this._pack = pack;
      this.log.info(TAG, 'Experience pack saved');
    } catch (err) {
      this.log.error(TAG, `Save failed: ${(err as Error).message ?? ''}`);
    }
  }

  async ensureLoaded(context: common.UIAbilityContext): Promise<ExperiencePack> {
    if (this._pack) return this._pack;
    let loaded = await this.load(context);
    if (loaded) return loaded;
    let fresh = createDefaultExperiencePack();
    await this.save(context, fresh);
    return fresh;
  }

  // ==================== Skill 操作 ====================

  async addSkill(context: common.UIAbilityContext, skill: Skill): Promise<void> {
    let pack = await this.ensureLoaded(context);
    let idx = pack.skills.findIndex((s: Skill) => s.name === skill.name);
    if (idx >= 0) {
      // 更新已有技能
      pack.skills[idx] = skill;
    } else {
      pack.skills.push(skill);
    }
    await this.save(context, pack);
  }

  async updateSkill(context: common.UIAbilityContext, name: string, updates: Partial<Skill>): Promise<void> {
    let pack = await this.ensureLoaded(context);
    let idx = pack.skills.findIndex((s: Skill) => s.name === name);
    if (idx >= 0) {
      let skill = pack.skills[idx];
      if (updates.description !== undefined) skill.description = updates.description;
      if (updates.content !== undefined) skill.content = updates.content;
      if (updates.metadata !== undefined) {
        if (!skill.metadata) {
          skill.metadata = {};
        }
        // 手动合并 metadata 字段
        if (updates.metadata.emoji !== undefined) skill.metadata.emoji = updates.metadata.emoji;
        if (updates.metadata.confidence !== undefined) skill.metadata.confidence = updates.metadata.confidence;
        if (updates.metadata.source !== undefined) skill.metadata.source = updates.metadata.source;
      }
      if (skill.metadata) {
        skill.metadata.updatedAt = Date.now();
      }
      await this.save(context, pack);
    }
  }

  async removeSkill(context: common.UIAbilityContext, name: string): Promise<void> {
    let pack = await this.ensureLoaded(context);
    pack.skills = pack.skills.filter((s: Skill) => s.name !== name);
    await this.save(context, pack);
  }

  getSkillByName(name: string): Skill | undefined {
    if (!this._pack) return undefined;
    return this._pack.skills.find((s: Skill) => s.name === name);
  }

  // ==================== Memory 操作 ====================

  async addMemory(context: common.UIAbilityContext, memory: Memory): Promise<void> {
    let pack = await this.ensureLoaded(context);
    // 按 category + key 去重
    let idx = pack.memory.findIndex((m: Memory) => m.category === memory.category && m.key === memory.key);
    if (idx >= 0) {
      pack.memory[idx] = memory;
    } else {
      pack.memory.push(memory);
    }
    await this.save(context, pack);
  }

  async updateMemory(context: common.UIAbilityContext, id: string, value: string | object): Promise<void> {
    let pack = await this.ensureLoaded(context);
    let idx = pack.memory.findIndex((m: Memory) => m.id === id);
    if (idx >= 0) {
      pack.memory[idx].value = value;
      pack.memory[idx].updatedAt = Date.now();
      await this.save(context, pack);
    }
  }

  async removeMemory(context: common.UIAbilityContext, id: string): Promise<void> {
    let pack = await this.ensureLoaded(context);
    pack.memory = pack.memory.filter((m: Memory) => m.id !== id);
    await this.save(context, pack);
  }

  getMemoryByKey(category: MemoryCategory, key: string): Memory | undefined {
    if (!this._pack) return undefined;
    return this._pack.memory.find((m: Memory) => m.category === category && m.key === key);
  }

  getMemoriesByCategory(category: MemoryCategory): Memory[] {
    if (!this._pack) return [];
    return this._pack.memory.filter((m: Memory) => m.category === category);
  }

  // ==================== 同步状态 ====================

  async markSynced(context: common.UIAbilityContext): Promise<void> {
    let pack = await this.ensureLoaded(context);
    pack.syncedAt = Date.now();
    await this.save(context, pack);
  }

  // ==================== 导入导出 ====================

  exportToJson(): string {
    if (!this._pack) return '{}';
    return JSON.stringify(this._pack, null, 2);
  }

  async importFromJson(context: common.UIAbilityContext, json: string): Promise<boolean> {
    try {
      let parsed: ExperiencePack = JSON.parse(json) as ExperiencePack;
      // 基本验证
      if (!Array.isArray(parsed.skills) || !Array.isArray(parsed.memory)) {
        this.log.warn(TAG, 'Import failed: invalid structure');
        return false;
      }
      parsed.version = 2;
      parsed.updatedAt = Date.now();
      parsed.syncedAt = 0; // 强制重新同步
      await this.save(context, parsed);
      this.log.info(TAG, 'Experience pack imported');
      return true;
    } catch (err) {
      this.log.error(TAG, `Import failed: ${(err as Error).message ?? ''}`);
      return false;
    }
  }

  // ==================== 清除 ====================

  async clear(context: common.UIAbilityContext): Promise<void> {
    try {
      let store = await preferences.getPreferences(context, Constants.PREFS_EXPERIENCE);
      await store.delete(STORE_KEY);
      await store.flush();
      this._pack = undefined;
      this.log.info(TAG, 'Experience pack cleared');
    } catch (err) {
      this.log.error(TAG, `Clear failed: ${(err as Error).message ?? ''}`);
    }
  }

  // ==================== 服务端合并更新 ====================

  async mergeUpdate(context: common.UIAbilityContext, partial: Record<string, Object>): Promise<void> {
    let pack = await this.ensureLoaded(context);

    // 合并 skills (按 name 去重)
    if (partial['skills'] && Array.isArray(partial['skills'])) {
      let newSkills = partial['skills'] as Skill[];
      for (let i = 0; i < newSkills.length; i++) {
        let skill = newSkills[i];
        // 确保 metadata 存在
        if (!skill.metadata) {
          skill.metadata = { updatedAt: Date.now(), source: 'imported' };
        }
        if (!skill.metadata.updatedAt) {
          skill.metadata.updatedAt = Date.now();
        }
        let idx = pack.skills.findIndex((s: Skill) => s.name === skill.name);
        if (idx >= 0) {
          // 只在新的更新时间更晚时覆盖
          let existingTime = pack.skills[idx].metadata?.updatedAt ?? 0;
          let newTime = skill.metadata.updatedAt ?? 0;
          if (newTime > existingTime) {
            pack.skills[idx] = skill;
          }
        } else {
          pack.skills.push(skill);
        }
      }
    }

    // 合并 memory (按 category + key 去重)
    if (partial['memory'] && Array.isArray(partial['memory'])) {
      let newMemories = partial['memory'] as Memory[];
      for (let i = 0; i < newMemories.length; i++) {
        let mem = newMemories[i];
        if (!mem.id) mem.id = generateId();
        if (!mem.updatedAt) mem.updatedAt = Date.now();
        let idx = pack.memory.findIndex((m: Memory) => m.category === mem.category && m.key === mem.key);
        if (idx >= 0) {
          if (mem.updatedAt > pack.memory[idx].updatedAt) {
            pack.memory[idx] = mem;
          }
        } else {
          pack.memory.push(mem);
        }
      }
    }

    await this.save(context, pack);
    this.log.info(TAG, 'Merged server update');
  }

  // ==================== 统计信息 ====================

  getSkillsCount(): number {
    return this._pack?.skills.length ?? 0;
  }

  getMemoryCount(): number {
    return this._pack?.memory.length ?? 0;
  }

  getLastSyncTime(): string {
    if (!this._pack || this._pack.syncedAt === 0) {
      return '从未';
    }
    return new Date(this._pack.syncedAt).toLocaleString();
  }
}
