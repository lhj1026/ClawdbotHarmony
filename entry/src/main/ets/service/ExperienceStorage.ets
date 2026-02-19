/**
 * ExperienceStorage — 经验包存储服务
 * 一条经验 = skills + memory
 */
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { Constants } from '../common/Constants';
import { LogService } from '../common/LogService';
import {
  ExperiencePack,
  Experience,
  Skill,
  Memory,
  ShareLevel,
  createDefaultExperiencePack,
  generateId,
} from '../model/ExperiencePack';

const TAG = 'ExperienceStorage';
const STORE_KEY = 'experience_pack_v3';

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
      this.log.info(TAG, `Loaded: ${parsed.experiences.length} experiences`);
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

  // ==================== Experience 操作 ====================

  async addExperience(context: common.UIAbilityContext, exp: Experience): Promise<void> {
    let pack = await this.ensureLoaded(context);
    let idx = pack.experiences.findIndex((e: Experience) => e.id === exp.id);
    if (idx >= 0) {
      pack.experiences[idx] = exp;
    } else {
      pack.experiences.push(exp);
    }
    await this.save(context, pack);
  }

  async updateExperience(context: common.UIAbilityContext, id: string, updates: Partial<Experience>): Promise<void> {
    let pack = await this.ensureLoaded(context);
    let idx = pack.experiences.findIndex((e: Experience) => e.id === id);
    if (idx >= 0) {
      let exp = pack.experiences[idx];
      if (updates.name !== undefined) exp.name = updates.name;
      if (updates.description !== undefined) exp.description = updates.description;
      if (updates.skills !== undefined) exp.skills = updates.skills;
      if (updates.memory !== undefined) exp.memory = updates.memory;
      exp.updatedAt = Date.now();
      await this.save(context, pack);
    }
  }

  async removeExperience(context: common.UIAbilityContext, id: string): Promise<void> {
    let pack = await this.ensureLoaded(context);
    pack.experiences = pack.experiences.filter((e: Experience) => e.id !== id);
    await this.save(context, pack);
  }

  getExperienceById(id: string): Experience | undefined {
    if (!this._pack) return undefined;
    return this._pack.experiences.find((e: Experience) => e.id === id);
  }

  getExperienceByName(name: string): Experience | undefined {
    if (!this._pack) return undefined;
    return this._pack.experiences.find((e: Experience) => e.name === name);
  }

  // ==================== Skill 操作 (在 Experience 内) ====================

  async addSkillToExperience(context: common.UIAbilityContext, expId: string, skill: Skill): Promise<void> {
    let pack = await this.ensureLoaded(context);
    let exp = pack.experiences.find((e: Experience) => e.id === expId);
    if (exp) {
      skill.lastModified = Date.now();
      skill.deletedAt = 0;
      let idx = exp.skills.findIndex((s: Skill) => s.name === skill.name);
      if (idx >= 0) {
        exp.skills[idx] = skill;
      } else {
        exp.skills.push(skill);
      }
      exp.updatedAt = Date.now();
      await this.save(context, pack);
    }
  }

  async removeSkillFromExperience(context: common.UIAbilityContext, expId: string, skillName: string): Promise<void> {
    let pack = await this.ensureLoaded(context);
    let exp = pack.experiences.find((e: Experience) => e.id === expId);
    if (exp) {
      let skill = exp.skills.find((s: Skill) => s.name === skillName);
      if (skill) {
        // Tombstone: mark as deleted instead of removing (for sync propagation)
        skill.deletedAt = Date.now();
        skill.lastModified = Date.now();
      }
      exp.updatedAt = Date.now();
      await this.save(context, pack);
    }
  }

  // ==================== Memory 操作 (在 Experience 内) ====================

  async addMemoryToExperience(context: common.UIAbilityContext, expId: string, mem: Memory): Promise<void> {
    let pack = await this.ensureLoaded(context);
    let exp = pack.experiences.find((e: Experience) => e.id === expId);
    if (exp) {
      mem.lastModified = Date.now();
      mem.deletedAt = 0;
      let idx = exp.memory.findIndex((m: Memory) => m.key === mem.key);
      if (idx >= 0) {
        exp.memory[idx] = mem;
      } else {
        exp.memory.push(mem);
      }
      exp.updatedAt = Date.now();
      await this.save(context, pack);
    }
  }

  async removeMemoryFromExperience(context: common.UIAbilityContext, expId: string, key: string): Promise<void> {
    let pack = await this.ensureLoaded(context);
    let exp = pack.experiences.find((e: Experience) => e.id === expId);
    if (exp) {
      let mem = exp.memory.find((m: Memory) => m.key === key);
      if (mem) {
        // Tombstone: mark as deleted instead of removing (for sync propagation)
        mem.deletedAt = Date.now();
        mem.lastModified = Date.now();
      }
      exp.updatedAt = Date.now();
      await this.save(context, pack);
    }
  }

  // ==================== 同步状态 ====================

  async markSynced(context: common.UIAbilityContext): Promise<void> {
    let pack = await this.ensureLoaded(context);
    pack.syncedAt = Date.now();
    await this.save(context, pack);
  }

  // ==================== 导入导出 ====================

  /** 导出完整经验包 (本地备份用) */
  exportToJson(): string {
    if (!this._pack) return '{}';
    return JSON.stringify(this._pack, null, 2);
  }

  /** 导出可分享的经验包 (按权限过滤) */
  exportForSharing(): string {
    if (!this._pack) return '{}';

    let filtered: ExperiencePack = {
      version: this._pack.version,
      updatedAt: this._pack.updatedAt,
      syncedAt: 0,
      experiences: [],
    };

    for (let i = 0; i < this._pack.experiences.length; i++) {
      let exp = this._pack.experiences[i];
      let filteredExp: Experience = {
        id: exp.id,
        name: exp.name,
        description: exp.description,
        skills: [],
        memory: [],
        createdAt: exp.createdAt,
        updatedAt: exp.updatedAt,
      };

      // 过滤 skills (skip deleted)
      for (let j = 0; j < exp.skills.length; j++) {
        let skill = exp.skills[j];
        if (skill.deletedAt && skill.deletedAt > 0) continue;
        if (skill.shareLevel === 'public') {
          // 完整分享
          filteredExp.skills.push(skill);
        } else if (skill.shareLevel === 'summary') {
          // 只分享名称和描述
          filteredExp.skills.push({
            name: skill.name,
            description: skill.description,
            instructions: '[摘要模式 - 详细内容已隐藏]',
            shareLevel: 'summary',
          });
        }
        // private 的不分享
      }

      // 过滤 memory (skip deleted)
      for (let k = 0; k < exp.memory.length; k++) {
        let mem = exp.memory[k];
        if (mem.deletedAt && mem.deletedAt > 0) continue;
        if (mem.shareLevel === 'public') {
          filteredExp.memory.push(mem);
        } else if (mem.shareLevel === 'summary') {
          filteredExp.memory.push({
            key: mem.key,
            value: '[摘要模式 - 值已隐藏]',
            shareLevel: 'summary',
          });
        }
        // private 的不分享
      }

      // 只有有内容的经验才加入
      if (filteredExp.skills.length > 0 || filteredExp.memory.length > 0) {
        filtered.experiences.push(filteredExp);
      }
    }

    return JSON.stringify(filtered, null, 2);
  }

  async importFromJson(context: common.UIAbilityContext, json: string): Promise<boolean> {
    try {
      let parsed: ExperiencePack = JSON.parse(json) as ExperiencePack;
      if (!Array.isArray(parsed.experiences)) {
        this.log.warn(TAG, 'Import failed: invalid structure');
        return false;
      }
      parsed.version = 3;
      parsed.updatedAt = Date.now();
      parsed.syncedAt = 0;
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

  /**
   * Smart merge (v2): timestamp-based per-item sync.
   * - Match experiences by id or name
   * - Match skills by name, memory by key
   * - Each item has lastModified: newer wins
   * - Deleted items propagate via deletedAt tombstone
   * Returns merge stats: { added, updated, deleted, skipped }
   */
  async mergeUpdate(context: common.UIAbilityContext, partial: Record<string, Object>): Promise<Record<string, number>> {
    let pack = await this.ensureLoaded(context);
    let stats: Record<string, number> = { 'added': 0, 'updated': 0, 'deleted': 0, 'skipped': 0 };

    if (partial['experiences'] && Array.isArray(partial['experiences'])) {
      let remoteExps = partial['experiences'] as Experience[];

      // Build lookup by id AND by name
      let localById = new Map<string, Experience>();
      let localByName = new Map<string, Experience>();
      for (let e of pack.experiences) {
        localById.set(e.id, e);
        localByName.set(e.name.toLowerCase(), e);
      }

      for (let i = 0; i < remoteExps.length; i++) {
        let remote = remoteExps[i];
        if (!remote.id) remote.id = generateId();
        if (!remote.createdAt) remote.createdAt = Date.now();
        if (!remote.updatedAt) remote.updatedAt = Date.now();

        // Find matching local experience
        let local = localById.get(remote.id);
        if (!local && remote.name) {
          local = localByName.get(remote.name.toLowerCase());
        }

        if (local) {
          let changed = false;

          // --- Merge skills by name (timestamp-based) ---
          let localSkillMap = new Map<string, Skill>();
          for (let s of local.skills) {
            localSkillMap.set(s.name.toLowerCase(), s);
          }
          for (let rs of remote.skills) {
            let remoteModified = rs.lastModified ?? remote.updatedAt ?? 0;
            let ls = localSkillMap.get(rs.name.toLowerCase());

            if (!ls) {
              // New skill from remote
              if (!rs.deletedAt || rs.deletedAt === 0) {
                if (!rs.lastModified) rs.lastModified = remoteModified;
                local.skills.push(rs);
                changed = true;
                stats['added'] = (stats['added'] ?? 0) + 1;
              }
            } else {
              let localModified = ls.lastModified ?? local.updatedAt ?? 0;

              // Remote is deleted — propagate deletion if remote is newer
              if (rs.deletedAt && rs.deletedAt > 0 && remoteModified > localModified) {
                ls.deletedAt = rs.deletedAt;
                ls.lastModified = remoteModified;
                changed = true;
                stats['deleted'] = (stats['deleted'] ?? 0) + 1;
              }
              // Remote is newer and not deleted — update
              else if (remoteModified > localModified && (!rs.deletedAt || rs.deletedAt === 0)) {
                ls.instructions = rs.instructions;
                ls.description = rs.description;
                ls.lastModified = remoteModified;
                // Keep local shareLevel
                changed = true;
                stats['updated'] = (stats['updated'] ?? 0) + 1;
              } else {
                stats['skipped'] = (stats['skipped'] ?? 0) + 1;
              }
            }
          }

          // --- Merge memory by key (timestamp-based) ---
          let localMemMap = new Map<string, Memory>();
          for (let m of local.memory) {
            localMemMap.set(m.key.toLowerCase(), m);
          }
          for (let rm of remote.memory) {
            let remoteModified = rm.lastModified ?? remote.updatedAt ?? 0;
            let lm = localMemMap.get(rm.key.toLowerCase());

            if (!lm) {
              // New memory from remote
              if (!rm.deletedAt || rm.deletedAt === 0) {
                if (!rm.lastModified) rm.lastModified = remoteModified;
                local.memory.push(rm);
                changed = true;
                stats['added'] = (stats['added'] ?? 0) + 1;
              }
            } else {
              let localModified = lm.lastModified ?? local.updatedAt ?? 0;

              // Remote is deleted — propagate
              if (rm.deletedAt && rm.deletedAt > 0 && remoteModified > localModified) {
                lm.deletedAt = rm.deletedAt;
                lm.lastModified = remoteModified;
                changed = true;
                stats['deleted'] = (stats['deleted'] ?? 0) + 1;
              }
              // Remote is newer — update
              else if (remoteModified > localModified && (!rm.deletedAt || rm.deletedAt === 0)) {
                lm.value = rm.value;
                lm.lastModified = remoteModified;
                // Keep local shareLevel
                changed = true;
                stats['updated'] = (stats['updated'] ?? 0) + 1;
              } else {
                stats['skipped'] = (stats['skipped'] ?? 0) + 1;
              }
            }
          }

          if (changed) {
            local.updatedAt = Date.now();
          }
        } else {
          // New experience from remote
          let dominated = false;
          for (let existing of pack.experiences) {
            if (existing.name.toLowerCase() === remote.name.toLowerCase()) {
              dominated = true;
              break;
            }
          }
          if (!dominated) {
            pack.experiences.push(remote);
            localById.set(remote.id, remote);
            localByName.set(remote.name.toLowerCase(), remote);
            stats['added'] = (stats['added'] ?? 0) + 1;
          } else {
            stats['skipped'] = (stats['skipped'] ?? 0) + 1;
          }
        }
      }
    }

    // Clean up: remove items with deletedAt older than 30 days
    let thirtyDaysAgo = Date.now() - 30 * 24 * 60 * 60 * 1000;
    for (let exp of pack.experiences) {
      exp.skills = exp.skills.filter((s: Skill) => !s.deletedAt || s.deletedAt === 0 || s.deletedAt > thirtyDaysAgo);
      exp.memory = exp.memory.filter((m: Memory) => !m.deletedAt || m.deletedAt === 0 || m.deletedAt > thirtyDaysAgo);
    }

    await this.save(context, pack);
    let added = stats['added'] ?? 0;
    let updated = stats['updated'] ?? 0;
    let deleted = stats['deleted'] ?? 0;
    let skipped = stats['skipped'] ?? 0;
    this.log.info(TAG, `Smart merge v2: +${added} added, ~${updated} updated, -${deleted} deleted, =${skipped} skipped`);
    return stats;
  }

  // ==================== 统计 ====================

  getExperiencesCount(): number {
    return this._pack?.experiences.length ?? 0;
  }

  getTotalSkillsCount(): number {
    if (!this._pack) return 0;
    let count = 0;
    for (let i = 0; i < this._pack.experiences.length; i++) {
      count += this._pack.experiences[i].skills.filter((s: Skill) => !s.deletedAt || s.deletedAt === 0).length;
    }
    return count;
  }

  getTotalMemoryCount(): number {
    if (!this._pack) return 0;
    let count = 0;
    for (let i = 0; i < this._pack.experiences.length; i++) {
      count += this._pack.experiences[i].memory.filter((m: Memory) => !m.deletedAt || m.deletedAt === 0).length;
    }
    return count;
  }

  getLastSyncTime(): string {
    if (!this._pack || this._pack.syncedAt === 0) {
      return '从未';
    }
    return new Date(this._pack.syncedAt).toLocaleString();
  }
}
