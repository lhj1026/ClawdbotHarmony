/**
 * scenario_distiller.h — 场景链蒸馏器（运行时匹配 + 在线学习）
 *
 * 三层推荐架构：
 *   Tier 1: ScenarioDistiller — 确定性子序列匹配，已知场景快速路径
 *   Tier 2: ActionMLPv2       — 预训练MLP泛化推理
 *   Tier 3: LLM fallback      — 新场景由 LLM 标注后学习
 *
 * 匹配算法：
 *   1. 从实际 StateChain 提取"关键状态"（发生显著变化的节点）
 *   2. 对每个场景原型，计算关键状态的子序列相似度
 *   3. 容忍中间状态：只要关键转换按序出现即可匹配
 *   4. 相似度 = Σ(best_match_score) / keyStateCount
 *
 * 在线学习：
 *   - LLM 标注新模式后，存入 learnedPrototypes
 *   - hitCount 跟踪命中次数，可用于热度排序
 *   - 持久化到文件，App 重启后恢复
 */
#pragma once

#include "state_code.h"
#include "state_attributes.h"
#include <array>
#include <vector>
#include <string>
#include <cmath>
#include <algorithm>
#include <fstream>

namespace context_engine {

// ============================================================
// 场景原型：存储关键状态模式 + 目标动作分布
// ============================================================

struct ScenarioPrototype {
    const char* id;          // "S01"
    const char* name;        // "工作日早起"
    int         keyCount;    // 关键状态数 (1-6)
    StateVector keyVecs[SA_CHAIN_MAX]; // 关键状态的属性向量
    float       actionDist[ACT_COUNT]; // 目标动作概率分布

    /** 与输入链做子序列相似度匹配
     *
     * 算法：贪心子序列匹配
     *   对原型的每个关键状态 k[i]，在链中找最佳匹配位置
     *   要求匹配位置严格递增（保序）
     *   每个匹配的得分 = StateVector 余弦相似度
     *   总分 = mean(scores)
     *
     * @param chain       实际状态链
     * @param threshold   单步最低相似度阈值（低于此值不算匹配）
     * @return 0.0 = 不匹配, >0 = 匹配置信度
     */
    float matchScore(const StateChain& chain, float threshold = 0.45f) const {
        if (keyCount == 0 || chain.count == 0) return 0.0f;

        float totalScore = 0.0f;
        int chainPos = 0;  // 从链头开始扫描

        for (int ki = 0; ki < keyCount; ++ki) {
            float bestSim = 0.0f;
            int bestPos = -1;

            // 在 chain[chainPos..end] 中找最佳匹配
            for (int ci = chainPos; ci < chain.count; ++ci) {
                float sim = cosineSimilarity(keyVecs[ki], chain.at(ci).vec);
                if (sim > bestSim) {
                    bestSim = sim;
                    bestPos = ci;
                }
            }

            if (bestSim < threshold || bestPos < 0) {
                return 0.0f;  // 关键状态未匹配 → 整个场景不匹配
            }

            totalScore += bestSim;
            chainPos = bestPos + 1;  // 下一个关键状态必须在此之后
        }

        return totalScore / keyCount;
    }

private:
    static float cosineSimilarity(const StateVector& a, const StateVector& b) {
        float dot = 0.0f, na = 0.0f, nb = 0.0f;
        for (int i = 0; i < SA_SINGLE_DIM; ++i) {
            dot += a.v[i] * b.v[i];
            na  += a.v[i] * a.v[i];
            nb  += b.v[i] * b.v[i];
        }
        float denom = std::sqrt(na * nb);
        return denom > 1e-6f ? dot / denom : 0.0f;
    }
};

// ============================================================
// 在线学习的场景模式
// ============================================================

struct LearnedPrototype {
    char id[16] = {};         // "L001" 自动编号
    int  keyCount = 0;
    StateVector keyVecs[SA_CHAIN_MAX];
    float actionDist[ACT_COUNT] = {};
    int   hitCount = 0;       // 命中次数（热度）
    float avgReward = 0.0f;   // 平均奖励（质量）

    float matchScore(const StateChain& chain, float threshold = 0.45f) const {
        if (keyCount == 0 || chain.count == 0) return 0.0f;
        float totalScore = 0.0f;
        int chainPos = 0;
        for (int ki = 0; ki < keyCount; ++ki) {
            float bestSim = 0.0f;
            int bestPos = -1;
            for (int ci = chainPos; ci < chain.count; ++ci) {
                float sim = 0.0f, na = 0.0f, nb = 0.0f;
                for (int d = 0; d < SA_SINGLE_DIM; ++d) {
                    sim += keyVecs[ki].v[d] * chain.at(ci).vec.v[d];
                    na  += keyVecs[ki].v[d] * keyVecs[ki].v[d];
                    nb  += chain.at(ci).vec.v[d] * chain.at(ci).vec.v[d];
                }
                float denom = std::sqrt(na * nb);
                float s = denom > 1e-6f ? sim / denom : 0.0f;
                if (s > bestSim) { bestSim = s; bestPos = ci; }
            }
            if (bestSim < threshold || bestPos < 0) return 0.0f;
            totalScore += bestSim;
            chainPos = bestPos + 1;
        }
        return totalScore / keyCount;
    }
};

// ============================================================
// ScenarioDistiller 主类
// ============================================================

class ScenarioDistiller {
public:
    static constexpr int MAX_BUILTIN  = 128;  // 内置原型最大数
    static constexpr int MAX_LEARNED  = 64;   // 在线学习原型最大数
    static constexpr float MATCH_THRESHOLD = 0.55f; // 匹配阈值

    struct MatchResult {
        int   protoIdx;      // 原型索引 (-1=无匹配, 0+内置, 100+学习)
        float confidence;    // 匹配置信度
        bool  isLearned;     // 是否来自在线学习
        const float* actionDist; // 指向动作分布
    };

    ScenarioDistiller() {
        loadBuiltinPrototypes();
    }

    /**
     * 匹配状态链，返回最佳匹配的场景
     */
    MatchResult match(const StateChain& chain) const {
        MatchResult best = { -1, 0.0f, false, nullptr };

        // 1. 先匹配内置原型
        for (int i = 0; i < builtinCount_; ++i) {
            float score = builtins_[i].matchScore(chain, 0.45f);
            if (score > best.confidence && score >= MATCH_THRESHOLD) {
                best = { i, score, false, builtins_[i].actionDist };
            }
        }

        // 2. 再匹配学习原型（可能优先级更高）
        for (int i = 0; i < learnedCount_; ++i) {
            float score = learned_[i].matchScore(chain, 0.45f);
            // 学习原型需要比内置高 0.05 才覆盖（内置优先）
            if (score > best.confidence + 0.05f && score >= MATCH_THRESHOLD) {
                best = { 100 + i, score, true, learned_[i].actionDist };
            }
        }

        return best;
    }

    /**
     * 从状态链中提取关键状态（去除重复 / 变化不大的中间状态）
     * 用于创建新的学习原型
     */
    static int extractKeyStates(const StateChain& chain,
                                 StateVector outVecs[SA_CHAIN_MAX]) {
        if (chain.count == 0) return 0;

        int keyCount = 0;
        outVecs[keyCount++] = chain.at(0).vec;  // 第一个状态总是关键的

        for (int i = 1; i < chain.count && keyCount < SA_CHAIN_MAX; ++i) {
            // 与上一个关键状态比较，变化大才算新的关键状态
            float sim = 0.0f, na = 0.0f, nb = 0.0f;
            const auto& prev = outVecs[keyCount - 1];
            const auto& curr = chain.at(i).vec;
            for (int d = 0; d < SA_SINGLE_DIM; ++d) {
                sim += prev.v[d] * curr.v[d];
                na  += prev.v[d] * prev.v[d];
                nb  += curr.v[d] * curr.v[d];
            }
            float denom = std::sqrt(na * nb);
            float cosSim = denom > 1e-6f ? sim / denom : 0.0f;

            if (cosSim < 0.85f) {  // 足够不同，算关键转换
                outVecs[keyCount++] = curr;
            }
        }
        return keyCount;
    }

    /**
     * 在线学习新场景模式
     * @param chain       触发时的状态链
     * @param actionDist  LLM 标注的动作分布 (ACT_COUNT 维)
     */
    void learnPattern(const StateChain& chain, const float actionDist[ACT_COUNT]) {
        // 提取关键状态
        StateVector keyVecs[SA_CHAIN_MAX];
        int keyCount = extractKeyStates(chain, keyVecs);
        if (keyCount == 0) return;

        // 检查是否与已有学习模式重复
        for (int i = 0; i < learnedCount_; ++i) {
            // 用当前链测试已有模式
            float sim = learned_[i].matchScore(chain, 0.45f);
            if (sim > 0.8f) {
                // 高度相似 → 更新已有模式的动作分布（滑动平均）
                float alpha = 0.3f;  // 学习率
                for (int a = 0; a < ACT_COUNT; ++a) {
                    learned_[i].actionDist[a] =
                        (1.0f - alpha) * learned_[i].actionDist[a] +
                        alpha * actionDist[a];
                }
                learned_[i].hitCount++;
                return;
            }
        }

        // 新模式：如果空间不够，替换最少命中的
        int slot = learnedCount_;
        if (learnedCount_ >= MAX_LEARNED) {
            // 找命中最少的
            int minHits = learned_[0].hitCount;
            slot = 0;
            for (int i = 1; i < MAX_LEARNED; ++i) {
                if (learned_[i].hitCount < minHits) {
                    minHits = learned_[i].hitCount;
                    slot = i;
                }
            }
        } else {
            learnedCount_++;
        }

        auto& lp = learned_[slot];
        snprintf(lp.id, sizeof(lp.id), "L%03d", nextLearnedId_++);
        lp.keyCount = keyCount;
        for (int i = 0; i < keyCount; ++i) lp.keyVecs[i] = keyVecs[i];
        std::copy(actionDist, actionDist + ACT_COUNT, lp.actionDist);
        lp.hitCount = 1;
        lp.avgReward = 0.0f;
    }

    /**
     * 更新学习模式的奖励（用于质量跟踪）
     */
    void updateReward(int learnedIdx, float reward) {
        if (learnedIdx < 0 || learnedIdx >= learnedCount_) return;
        auto& lp = learned_[learnedIdx];
        float n = static_cast<float>(lp.hitCount);
        lp.avgReward = (lp.avgReward * (n - 1) + reward) / n;
    }

    // ── 持久化（学习模式） ──────────────────────────────

    bool saveLearned(const std::string& path) const {
        std::ofstream f(path, std::ios::binary);
        if (!f) return false;
        uint32_t magic = 0x53444C50;  // "SDLP"
        uint32_t ver = 1;
        f.write(reinterpret_cast<const char*>(&magic), 4);
        f.write(reinterpret_cast<const char*>(&ver), 4);
        f.write(reinterpret_cast<const char*>(&learnedCount_), 4);
        f.write(reinterpret_cast<const char*>(&nextLearnedId_), 4);
        for (int i = 0; i < learnedCount_; ++i) {
            f.write(reinterpret_cast<const char*>(&learned_[i]), sizeof(LearnedPrototype));
        }
        return f.good();
    }

    bool loadLearned(const std::string& path) {
        std::ifstream f(path, std::ios::binary);
        if (!f) return false;
        uint32_t magic, ver;
        f.read(reinterpret_cast<char*>(&magic), 4);
        f.read(reinterpret_cast<char*>(&ver), 4);
        if (magic != 0x53444C50 || ver != 1) return false;
        f.read(reinterpret_cast<char*>(&learnedCount_), 4);
        f.read(reinterpret_cast<char*>(&nextLearnedId_), 4);
        for (int i = 0; i < learnedCount_; ++i) {
            f.read(reinterpret_cast<char*>(&learned_[i]), sizeof(LearnedPrototype));
        }
        return f.good();
    }

    // ── 诊断 ────────────────────────────────────────────

    int builtinCount() const { return builtinCount_; }
    int learnedCount() const { return learnedCount_; }

    struct DiagEntry {
        const char* id;
        int hitCount;
        float avgReward;
    };
    std::vector<DiagEntry> learnedDiag() const {
        std::vector<DiagEntry> out;
        for (int i = 0; i < learnedCount_; ++i) {
            out.push_back({ learned_[i].id, learned_[i].hitCount,
                            learned_[i].avgReward });
        }
        return out;
    }

private:
    ScenarioPrototype builtins_[MAX_BUILTIN];
    int builtinCount_ = 0;

    LearnedPrototype learned_[MAX_LEARNED];
    int learnedCount_ = 0;
    int nextLearnedId_ = 1;

    // ── 添加内置原型辅助 ────────────────────────────────

    void addBuiltin(const char* id, const char* name,
                    std::initializer_list<PhysicalState> keyStates,
                    std::initializer_list<std::pair<int, float>> actions) {
        if (builtinCount_ >= MAX_BUILTIN) return;
        auto& p = builtins_[builtinCount_++];
        p.id = id;
        p.name = name;
        p.keyCount = 0;
        std::fill(p.actionDist, p.actionDist + ACT_COUNT, 0.0f);

        for (const auto& s : keyStates) {
            if (p.keyCount < SA_CHAIN_MAX) {
                p.keyVecs[p.keyCount++] = StateVector::encode(s);
            }
        }

        // 设置动作分布（归一化）
        float sum = 0.0f;
        for (const auto& [idx, weight] : actions) {
            if (idx >= 0 && idx < ACT_COUNT) {
                p.actionDist[idx] = weight;
                sum += weight;
            }
        }
        if (sum > 0.0f) {
            for (int i = 0; i < ACT_COUNT; ++i) p.actionDist[i] /= sum;
        }
    }

    /** 辅助：从字符串名称创建 PhysicalState */
    static PhysicalState S(const char* t, const char* l, const char* m,
                           const char* p, const char* li = "",
                           const char* s = "", const char* d = "") {
        return StateCode::fromNames(t, l, m, p, li, s, d);
    }

    // ── 内置场景原型加载 ──────────────────────────────────
    //
    // ActionCatalog 索引:
    //   0-3:   A1-A4  亮码 (地铁/公交/支付/门票)
    //   4-12:  B1-B9  日程 (今日/明日/下午/闹钟/出行/散场/行程/检票/下班)
    //   13:    C1     天气
    //   14-17: D1-D4  媒体 (音乐/白噪音/播客/新闻)
    //   18-25: E1-E8  导航 (回家/公司/餐厅/店铺/枢纽/景点/通用/停车)
    //   26-29: F1-F4  交通 (到站/下车/船班/座位)
    //   30-34: G1-G5  健康 (久坐/补水/拉伸/步数/休息)
    //   35:    H1     餐饮
    //   36:    I1     社交
    //   37-39: J1-J3  系统 (关通知/静音/注意财物)

    void loadBuiltinPrototypes() {
        // ======== 早晨场景 ========

        // S01: 工作日早起 (家-黑暗-充电 → 家-步行-使用 → 家-坐着-使用)
        addBuiltin("S01", "workday_morning", {
            S("dawn",    "home", "stationary", "charging", "dark",   "quiet",  "workday"),
            S("morning", "home", "walking",    "in_use",   "dim",    "quiet",  "workday"),
            S("morning", "home", "stationary", "in_use",   "normal", "quiet",  "workday"),
        }, {{13,0.4f},{4,0.3f},{8,0.2f},{17,0.1f}});
        // → C1天气(0.4) + B1日程(0.3) + B5出行提醒(0.2) + D4新闻(0.1)

        // S02: 周末赖床 (家-黑暗-充电-周末 → 家-使用-周末)
        addBuiltin("S02", "weekend_sleep_in", {
            S("morning", "home", "stationary", "charging", "dark",  "quiet", "weekend"),
            S("morning", "home", "stationary", "in_use",   "dim",   "quiet", "weekend"),
        }, {{37,0.4f},{5,0.3f},{17,0.3f}});
        // → J1关通知(0.4) + B2明日日程(0.3) + D4新闻(0.3)

        // S03: 早起晨跑 (家-充电 → 家-步行-口袋 → 户外-跑步 → 家-使用)
        addBuiltin("S03", "morning_jog", {
            S("dawn",    "home",    "stationary", "charging",  "dark",   "quiet", ""),
            S("dawn",    "home",    "walking",    "in_pocket", "dim",    "quiet", ""),
            S("morning", "outdoor", "running",    "in_pocket", "bright", "normal",""),
            S("morning", "home",    "stationary", "in_use",    "normal", "quiet", ""),
        }, {{14,0.35f},{33,0.3f},{32,0.2f},{13,0.15f}});
        // → D1音乐(0.35) + G4步数(0.3) + G3拉伸(0.2) + C1天气(0.15)

        // S04: 早起瑜伽/冥想
        addBuiltin("S04", "morning_yoga", {
            S("dawn", "home", "stationary", "face_down", "dim", "quiet", ""),
        }, {{37,0.4f},{15,0.3f},{14,0.3f}});
        // → J1关通知(0.4) + D2白噪音(0.3) + D1音乐(0.3)

        // S05: 准备早餐
        addBuiltin("S05", "breakfast_prep", {
            S("morning", "home", "walking", "on_desk", "normal", "quiet", ""),
        }, {{17,0.5f},{13,0.3f},{35,0.2f}});
        // → D4新闻(0.5) + C1天气(0.3) + H1餐饮(0.2)

        // S06: 送孩子上学 (家→驾车→到达→驾车回)
        addBuiltin("S06", "school_drop", {
            S("morning", "home",    "walking",    "in_use",    "normal", "quiet",  "workday"),
            S("morning", "commute", "driving",    "in_pocket", "bright", "normal", "workday"),
        }, {{24,0.5f},{8,0.3f},{14,0.2f}});
        // → E7通用导航(0.5) + B5出行提醒(0.3) + D1音乐(0.2)

        // ======== 通勤场景 ========

        // S07: 早晨驾车通勤 (家→通勤/驾车→公司)
        addBuiltin("S07", "drive_to_work", {
            S("morning", "home",    "stationary", "in_use",    "normal", "quiet",  "workday"),
            S("morning", "commute", "driving",    "in_pocket", "bright", "normal", "workday"),
            S("forenoon","work",    "stationary", "on_desk",   "normal", "quiet",  "workday"),
        }, {{19,0.4f},{14,0.3f},{13,0.15f},{4,0.15f}});
        // → E2导航公司(0.4) + D1音乐(0.3) + C1天气(0.15) + B1日程(0.15)

        // S08: 早晨公交/地铁通勤 (家→地铁→公司)
        addBuiltin("S08", "transit_to_work", {
            S("morning", "home",   "walking",    "in_use",    "normal", "quiet",  "workday"),
            S("morning", "subway", "stationary", "in_use",    "dim",    "noisy",  "workday"),
            S("forenoon","work",   "stationary", "on_desk",   "normal", "quiet",  "workday"),
        }, {{0,0.35f},{14,0.25f},{17,0.2f},{4,0.2f}});
        // → A1亮地铁码(0.35) + D1音乐(0.25) + D4新闻(0.2) + B1日程(0.2)

        // S09: 早晨骑车通勤
        addBuiltin("S09", "cycle_to_work", {
            S("morning", "home",    "walking",    "in_use",    "normal", "quiet",  "workday"),
            S("morning", "commute", "driving",    "in_pocket", "bright", "normal", "workday"),
            S("forenoon","work",    "stationary", "on_desk",   "normal", "quiet",  "workday"),
        }, {{33,0.3f},{14,0.3f},{19,0.2f},{13,0.2f}});
        // → G4步数(0.3) + D1音乐(0.3) + E2导航(0.2) + C1天气(0.2)

        // S10: 晚间驾车回家
        addBuiltin("S10", "drive_home_evening", {
            S("evening", "work",    "stationary", "in_use",    "normal", "quiet",  "workday"),
            S("evening", "commute", "driving",    "in_pocket", "dim",    "normal", "workday"),
            S("evening", "home",    "stationary", "in_use",    "normal", "quiet",  "workday"),
        }, {{18,0.4f},{14,0.35f},{12,0.15f},{4,0.1f}});
        // → E1导航回家(0.4) + D1音乐(0.35) + B9下班(0.15) + B1日程(0.1)

        // S11: 晚间公交回家
        addBuiltin("S11", "transit_home_evening", {
            S("evening", "work",   "stationary", "in_use",    "normal", "quiet",  "workday"),
            S("evening", "subway", "stationary", "in_use",    "dim",    "noisy",  "workday"),
            S("evening", "home",   "stationary", "in_use",    "normal", "quiet",  "workday"),
        }, {{0,0.3f},{14,0.25f},{16,0.2f},{27,0.15f},{18,0.1f}});
        // → A1亮地铁码(0.3) + D1音乐(0.25) + D3播客(0.2) + F2下车提醒(0.15) + E1导航(0.1)

        // S12: 加班晚归
        addBuiltin("S12", "overtime_late", {
            S("night",   "work",    "stationary", "in_use",    "normal", "quiet",  "workday"),
            S("night",   "commute", "driving",    "in_pocket", "dark",   "quiet",  "workday"),
            S("night",   "home",    "stationary", "in_use",    "dim",    "quiet",  "workday"),
        }, {{18,0.4f},{12,0.3f},{37,0.2f},{14,0.1f}});
        // → E1导航回家(0.4) + B9下班(0.3) + J1关通知(0.2) + D1音乐(0.1)

        // ======== 工作场景 ========

        // S13: 到达公司开始工作
        addBuiltin("S13", "work_start", {
            S("forenoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
        }, {{4,0.5f},{37,0.3f},{13,0.2f}});
        // → B1今日日程(0.5) + J1关通知(0.3) + C1天气(0.2)

        // S14: 上午专注工作
        addBuiltin("S14", "focus_work", {
            S("forenoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
        }, {{37,0.5f},{30,0.3f},{31,0.2f}});
        // → J1关通知(0.5) + G1久坐提醒(0.3) + G2补水(0.2)

        // S15: 开会
        addBuiltin("S15", "meeting", {
            S("forenoon", "work", "stationary", "face_down", "normal", "noisy", "workday"),
        }, {{38,0.5f},{37,0.5f}});
        // → J2静音(0.5) + J1关通知(0.5)

        // S16: 午餐外出 (公司→餐厅→公司)
        addBuiltin("S16", "lunch_out", {
            S("lunch", "work",       "walking",    "in_pocket", "normal", "quiet",  "workday"),
            S("lunch", "restaurant", "stationary", "on_desk",   "normal", "noisy",  "workday"),
            S("lunch", "work",       "stationary", "on_desk",   "normal", "quiet",  "workday"),
        }, {{2,0.3f},{35,0.25f},{20,0.25f},{38,0.2f}});
        // → A3支付码(0.3) + H1餐饮(0.25) + E3导航餐厅(0.25) + J2静音(0.2)

        // S17: 办公室午餐
        addBuiltin("S17", "office_lunch", {
            S("lunch", "work", "stationary", "in_use", "normal", "quiet", "workday"),
        }, {{17,0.4f},{34,0.3f},{31,0.3f}});
        // → D4新闻(0.4) + G5休息(0.3) + G2补水(0.3)

        // S18: 下午茶/休息
        addBuiltin("S18", "afternoon_break", {
            S("afternoon", "work", "walking",    "in_pocket", "normal", "quiet", "workday"),
            S("afternoon", "work", "stationary", "in_use",    "normal", "quiet", "workday"),
        }, {{30,0.3f},{32,0.3f},{17,0.2f},{31,0.2f}});
        // → G1久坐提醒(0.3) + G3拉伸(0.3) + D4新闻(0.2) + G2补水(0.2)

        // S19: 准备下班
        addBuiltin("S19", "prepare_leave", {
            S("evening", "work", "stationary", "in_use", "normal", "quiet", "workday"),
        }, {{12,0.4f},{18,0.3f},{13,0.3f}});
        // → B9下班(0.4) + E1导航回家(0.3) + C1天气(0.3)

        // S20: 加班
        addBuiltin("S20", "overtime", {
            S("evening", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
        }, {{37,0.3f},{30,0.25f},{31,0.25f},{34,0.2f}});
        // → J1关通知(0.3) + G1久坐(0.25) + G2补水(0.25) + G5休息(0.2)

        // ======== 居家场景 ========

        // S21: 到家放松
        addBuiltin("S21", "home_relax", {
            S("evening", "home", "stationary", "in_use", "normal", "quiet", "workday"),
        }, {{14,0.4f},{17,0.3f},{13,0.3f}});
        // → D1音乐(0.4) + D4新闻(0.3) + C1天气(0.3)

        // S22: 在家做饭
        addBuiltin("S22", "cooking", {
            S("evening", "home", "walking", "on_desk", "normal", "normal", ""),
        }, {{35,0.4f},{14,0.3f},{17,0.3f}});
        // → H1餐饮(0.4) + D1音乐(0.3) + D4新闻(0.3)

        // S23: 在家用餐
        addBuiltin("S23", "home_dinner", {
            S("evening", "home", "stationary", "face_down", "normal", "quiet", ""),
        }, {{37,0.3f},{17,0.35f},{14,0.35f}});
        // → J1关通知(0.3) + D4新闻(0.35) + D1音乐(0.35)

        // S24: 看电视
        addBuiltin("S24", "watching_tv", {
            S("night", "home", "stationary", "on_desk", "dim", "normal", ""),
        }, {{37,0.5f},{34,0.5f}});
        // → J1关通知(0.5) + G5休息(0.5)

        // S25: 阅读
        addBuiltin("S25", "reading", {
            S("night", "home", "stationary", "face_up", "dim", "quiet", ""),
        }, {{37,0.5f},{15,0.3f},{34,0.2f}});
        // → J1关通知(0.5) + D2白噪音(0.3) + G5休息(0.2)

        // S26: 玩游戏
        addBuiltin("S26", "gaming", {
            S("night", "home", "stationary", "in_use", "dim", "quiet", ""),
        }, {{37,0.5f},{34,0.3f},{31,0.2f}});
        // → J1关通知(0.5) + G5休息(0.3) + G2补水(0.2)

        // S27: 在家午餐
        addBuiltin("S27", "home_lunch", {
            S("lunch", "home", "stationary", "in_use", "normal", "quiet", ""),
        }, {{17,0.4f},{35,0.3f},{34,0.3f}});
        // → D4新闻(0.4) + H1餐饮(0.3) + G5休息(0.3)

        // S28: 午休/午睡
        addBuiltin("S28", "nap", {
            S("lunch", "home", "stationary", "face_down", "dim", "quiet", ""),
        }, {{37,0.5f},{7,0.3f},{15,0.2f}});
        // → J1关通知(0.5) + B4设闹钟(0.3) + D2白噪音(0.2)

        // S29: 做家务
        addBuiltin("S29", "housework", {
            S("afternoon", "home", "walking", "in_pocket", "normal", "normal", "weekend"),
        }, {{14,0.5f},{16,0.3f},{33,0.2f}});
        // → D1音乐(0.5) + D3播客(0.3) + G4步数(0.2)

        // S30: 带小孩
        addBuiltin("S30", "babysitting", {
            S("afternoon", "home", "walking", "in_pocket", "normal", "noisy", "weekend"),
        }, {{37,0.5f},{34,0.3f},{31,0.2f}});
        // → J1关通知(0.5) + G5休息(0.3) + G2补水(0.2)

        // S31: 居家办公
        addBuiltin("S31", "wfh", {
            S("forenoon", "home", "stationary", "in_use", "normal", "quiet", "workday"),
        }, {{37,0.3f},{4,0.3f},{30,0.2f},{31,0.2f}});
        // → J1关通知(0.3) + B1日程(0.3) + G1久坐(0.2) + G2补水(0.2)

        // S32: 周末宅家
        addBuiltin("S32", "weekend_home", {
            S("forenoon", "home", "stationary", "in_use", "normal", "quiet", "weekend"),
        }, {{17,0.3f},{14,0.3f},{13,0.2f},{34,0.2f}});
        // → D4新闻(0.3) + D1音乐(0.3) + C1天气(0.2) + G5休息(0.2)

        // ======== 睡眠场景 ========

        // S33: 晚间入睡 (夜晚-使用 → 深夜-充电)
        addBuiltin("S33", "bedtime", {
            S("night",      "home", "stationary", "in_use",   "dim",  "quiet", ""),
            S("late_night", "home", "stationary", "charging", "dark", "quiet", ""),
        }, {{37,0.4f},{7,0.3f},{15,0.3f}});
        // → J1关通知(0.4) + B4设闹钟(0.3) + D2白噪音(0.3)

        // S34: 午睡
        addBuiltin("S34", "afternoon_nap", {
            S("lunch", "home", "stationary", "face_down", "dim", "quiet", ""),
        }, {{37,0.4f},{7,0.3f},{15,0.3f}});

        // S35: 早醒未起
        addBuiltin("S35", "early_wake", {
            S("dawn", "home", "stationary", "face_up", "dark", "quiet", ""),
        }, {{37,0.6f},{15,0.4f}});
        // → J1关通知(0.6) + D2白噪音(0.4)

        // S36: 夜间失眠
        addBuiltin("S36", "insomnia", {
            S("sleeping", "home", "stationary", "in_use", "dark", "quiet", ""),
        }, {{15,0.5f},{37,0.3f},{34,0.2f}});
        // → D2白噪音(0.5) + J1关通知(0.3) + G5休息(0.2)

        // S37: 夜间起夜
        addBuiltin("S37", "bathroom_night", {
            S("sleeping", "home", "walking", "face_up", "dark", "quiet", ""),
            S("sleeping", "home", "stationary", "charging", "dark", "quiet", ""),
        }, {{37,0.7f},{15,0.3f}});

        // ======== 运动场景 ========

        // S38: 到达健身房
        addBuiltin("S38", "gym_arrive", {
            S("evening", "gym", "stationary", "in_pocket", "bright", "noisy", ""),
        }, {{14,0.4f},{37,0.3f},{33,0.3f}});
        // → D1音乐(0.4) + J1关通知(0.3) + G4步数(0.3)

        // S39: 健身中
        addBuiltin("S39", "gym_workout", {
            S("evening", "gym", "walking", "in_pocket", "bright", "noisy", ""),
        }, {{14,0.4f},{37,0.3f},{30,0.3f}});

        // S40: 健身结束
        addBuiltin("S40", "gym_finish", {
            S("evening", "gym", "stationary", "in_use", "bright", "noisy", ""),
        }, {{33,0.5f},{32,0.3f},{31,0.2f}});
        // → G4步数(0.5) + G3拉伸(0.3) + G2补水(0.2)

        // S41: 户外跑步
        addBuiltin("S41", "outdoor_run", {
            S("morning", "outdoor", "running", "in_pocket", "bright", "normal", ""),
        }, {{14,0.3f},{33,0.3f},{32,0.2f},{31,0.2f}});
        // → D1音乐(0.3) + G4步数(0.3) + G3拉伸(0.2) + G2补水(0.2)

        // S42: 户外散步
        addBuiltin("S42", "outdoor_walk", {
            S("afternoon", "outdoor", "walking", "in_pocket", "bright", "normal", ""),
        }, {{16,0.3f},{33,0.3f},{14,0.2f},{13,0.2f}});
        // → D3播客(0.3) + G4步数(0.3) + D1音乐(0.2) + C1天气(0.2)

        // S43: 骑车出行
        addBuiltin("S43", "cycling", {
            S("afternoon", "commute", "driving", "in_pocket", "bright", "normal", ""),
        }, {{33,0.3f},{14,0.3f},{24,0.2f},{13,0.2f}});
        // → G4步数(0.3) + D1音乐(0.3) + E7导航(0.2) + C1天气(0.2)

        // ======== 餐饮场景 ========

        // S44: 外出午餐
        addBuiltin("S44", "lunch_restaurant", {
            S("lunch", "restaurant", "stationary", "on_desk", "normal", "noisy", "workday"),
        }, {{2,0.4f},{38,0.3f},{35,0.3f}});
        // → A3支付码(0.4) + J2静音(0.3) + H1餐饮(0.3)

        // S45: 外出晚餐
        addBuiltin("S45", "dinner_restaurant", {
            S("evening", "restaurant", "stationary", "on_desk", "normal", "noisy", ""),
        }, {{2,0.4f},{38,0.3f},{35,0.3f}});

        // S46: 朋友聚餐
        addBuiltin("S46", "friends_dinner", {
            S("evening", "restaurant", "stationary", "face_down", "normal", "noisy", ""),
        }, {{38,0.4f},{37,0.3f},{2,0.3f}});
        // → J2静音(0.4) + J1关通知(0.3) + A3支付码(0.3)

        // S47: 咖啡店
        addBuiltin("S47", "cafe", {
            S("afternoon", "cafe", "stationary", "in_use", "normal", "quiet", ""),
        }, {{14,0.3f},{15,0.3f},{31,0.2f},{30,0.2f}});
        // → D1音乐(0.3) + D2白噪音(0.3) + G2补水(0.2) + G1久坐(0.2)

        // S48: 叫外卖
        addBuiltin("S48", "food_delivery", {
            S("lunch", "work", "stationary", "in_use", "normal", "quiet", "workday"),
        }, {{35,0.6f},{4,0.2f},{31,0.2f}});
        // → H1餐饮(0.6) + B1日程(0.2) + G2补水(0.2)

        // ======== 购物场景 ========

        // S49: 超市购物
        addBuiltin("S49", "grocery", {
            S("afternoon", "shopping", "walking", "in_use", "bright", "normal", ""),
        }, {{2,0.5f},{39,0.3f},{33,0.2f}});
        // → A3支付码(0.5) + J3注意财物(0.3) + G4步数(0.2)

        // S50: 商场逛街
        addBuiltin("S50", "mall", {
            S("afternoon", "shopping", "walking", "in_use", "bright", "noisy", ""),
        }, {{2,0.4f},{39,0.3f},{33,0.3f}});
        // → A3支付码(0.4) + J3注意财物(0.3) + G4步数(0.3)

        // S51: 便利店
        addBuiltin("S51", "convenience", {
            S("evening", "shopping", "walking", "in_use", "bright", "quiet", ""),
        }, {{2,0.7f},{39,0.3f}});
        // → A3支付码(0.7) + J3注意财物(0.3)

        // ======== 出行场景 ========

        // S52: 出发去机场 (家→驾车→机场)
        addBuiltin("S52", "to_airport", {
            S("morning", "home",    "walking",    "in_use",    "normal", "quiet",  ""),
            S("morning", "commute", "driving",    "in_pocket", "bright", "normal", ""),
            S("morning", "airport", "walking",    "in_use",    "bright", "noisy",  ""),
        }, {{10,0.3f},{22,0.3f},{24,0.2f},{14,0.2f}});
        // → B7检查行程(0.3) + E5导航枢纽(0.3) + E7导航(0.2) + D1音乐(0.2)

        // S53: 机场候机
        addBuiltin("S53", "airport_wait", {
            S("morning", "airport", "stationary", "in_use", "bright", "noisy", ""),
        }, {{10,0.4f},{17,0.3f},{14,0.2f},{37,0.1f}});
        // → B7检查行程(0.4) + D4新闻(0.3) + D1音乐(0.2) + J1关通知(0.1)

        // S54: 即将登机
        addBuiltin("S54", "boarding_soon", {
            S("morning", "airport", "walking", "in_use", "bright", "noisy", ""),
        }, {{3,0.4f},{11,0.3f},{10,0.3f}});
        // → A4亮门票(0.4) + B8检票提醒(0.3) + B7检查行程(0.3)

        // S55: 紧急登机
        addBuiltin("S55", "urgent_boarding", {
            S("morning", "airport", "running", "in_use", "bright", "noisy", ""),
        }, {{3,0.5f},{11,0.3f},{24,0.2f}});
        // → A4亮门票(0.5) + B8检票(0.3) + E7导航(0.2)

        // S56: 飞行中
        addBuiltin("S56", "inflight", {
            S("morning", "airport", "stationary", "in_use", "dim", "noisy", ""),
        }, {{37,0.5f},{17,0.3f},{14,0.2f}});
        // → J1关通知(0.5) + D4新闻(0.3) + D1音乐(0.2)

        // S57: 落地到达
        addBuiltin("S57", "landed", {
            S("afternoon", "airport", "walking", "in_use", "bright", "noisy", ""),
        }, {{24,0.3f},{10,0.3f},{13,0.2f},{36,0.2f}});
        // → E7导航(0.3) + B7行程(0.3) + C1天气(0.2) + I1社交(0.2)

        // S58: 高铁出行 (火车站→乘车→到达)
        addBuiltin("S58", "train_travel", {
            S("morning", "train_station", "walking",    "in_use",    "bright", "noisy",  ""),
            S("morning", "train_station", "stationary", "in_use",    "dim",    "normal", ""),
            S("afternoon","train_station", "walking",    "in_use",    "bright", "noisy",  ""),
        }, {{0,0.3f},{10,0.3f},{14,0.2f},{27,0.2f}});
        // → A1亮码(0.3) + B7行程(0.3) + D1音乐(0.2) + F2下车提醒(0.2)

        // S59: 打车/网约车
        addBuiltin("S59", "ridehail", {
            S("evening", "outdoor",  "stationary", "in_use",    "dim",    "normal", ""),
            S("evening", "commute",  "driving",    "in_pocket", "dim",    "quiet",  ""),
        }, {{24,0.4f},{14,0.3f},{18,0.3f}});
        // → E7导航(0.4) + D1音乐(0.3) + E1回家(0.3)

        // ======== 社交场景 ========

        // S60: 朋友来访
        addBuiltin("S60", "friends_visit", {
            S("evening", "home", "stationary", "face_down", "normal", "noisy", ""),
        }, {{37,0.3f},{14,0.4f},{36,0.3f}});
        // → J1关通知(0.3) + D1音乐(0.4) + I1社交(0.3)

        // S61: 外出社交
        addBuiltin("S61", "social_out", {
            S("evening", "restaurant", "stationary", "face_down", "normal", "noisy", "weekend"),
        }, {{38,0.4f},{37,0.3f},{36,0.3f}});
        // → J2静音(0.4) + J1关通知(0.3) + I1社交(0.3)

        // S62: 参加活动/讲座
        addBuiltin("S62", "event_attend", {
            S("afternoon", "cinema", "stationary", "face_down", "dim", "normal", ""),
        }, {{38,0.4f},{37,0.4f},{36,0.2f}});
        // → J2静音(0.4) + J1关通知(0.4) + I1社交(0.2)

        // ======== 健康场景 ========

        // S63: 久坐提醒
        addBuiltin("S63", "sedentary", {
            S("forenoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
        }, {{30,0.5f},{32,0.3f},{31,0.2f}});
        // → G1久坐(0.5) + G3拉伸(0.3) + G2补水(0.2)

        // S64: 喝水提醒
        addBuiltin("S64", "hydration", {
            S("afternoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
        }, {{31,0.5f},{30,0.3f},{34,0.2f}});
        // → G2补水(0.5) + G1久坐(0.3) + G5休息(0.2)

        // S65: 护眼提醒
        addBuiltin("S65", "eye_care", {
            S("night", "home", "stationary", "in_use", "dim", "quiet", ""),
        }, {{34,0.5f},{30,0.3f},{15,0.2f}});
        // → G5休息(0.5) + G1久坐(0.3) + D2白噪音(0.2)

        // S66: 站立/活动提醒
        addBuiltin("S66", "standup", {
            S("afternoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
        }, {{30,0.4f},{32,0.3f},{33,0.3f}});
        // → G1久坐(0.4) + G3拉伸(0.3) + G4步数(0.3)

        // S67: 深夜早睡提醒
        addBuiltin("S67", "late_sleep_warn", {
            S("late_night", "home", "stationary", "in_use", "dim", "quiet", ""),
        }, {{34,0.4f},{37,0.3f},{15,0.3f}});
        // → G5休息(0.4) + J1关通知(0.3) + D2白噪音(0.3)

        // ======== 设备场景 ========

        // S68: 低电量（通过数字条件匹配，这里用物理状态近似）
        addBuiltin("S68", "low_battery", {
            S("afternoon", "outdoor", "walking", "in_use", "bright", "normal", ""),
        }, {{37,0.5f},{24,0.3f},{39,0.2f}});
        // → J1关通知(0.5) + E7导航(0.3) + J3注意财物(0.2)

        // S69: 极低电量
        addBuiltin("S69", "critical_battery", {
            S("evening", "outdoor", "walking", "in_use", "dim", "normal", ""),
        }, {{37,0.6f},{18,0.2f},{24,0.2f}});
        // → J1关通知(0.6) + E1导航回家(0.2) + E7导航(0.2)

        // S70: 充电完成
        addBuiltin("S70", "charge_done", {
            S("night", "home", "stationary", "charging", "dim", "quiet", ""),
        }, {{37,0.5f},{4,0.3f},{13,0.2f}});
        // → J1关通知(0.5) + B1日程(0.3) + C1天气(0.2)

        // S71: 车载蓝牙连接
        addBuiltin("S71", "car_bluetooth", {
            S("morning", "commute", "driving", "in_pocket", "normal", "quiet", ""),
        }, {{14,0.3f},{24,0.3f},{19,0.2f},{4,0.2f}});
        // → D1音乐(0.3) + E7导航(0.3) + E2导航公司(0.2) + B1日程(0.2)

        // S72: 会议即将开始
        addBuiltin("S72", "meeting_soon", {
            S("forenoon", "work", "stationary", "in_use", "normal", "quiet", "workday"),
        }, {{4,0.3f},{38,0.3f},{37,0.2f},{30,0.2f}});
        // → B1日程(0.3) + J2静音(0.3) + J1关通知(0.2) + G1久坐(0.2)
    }
};

} // namespace context_engine
