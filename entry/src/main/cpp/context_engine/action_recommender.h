/**
 * action_recommender.h — 状态→动作推荐器（MLP + LinUCB）
 *
 * 功能：
 *   1. MLP 分类器（71→64→40）：从物理状态预测动作概率（先验知识）
 *   2. LinUCB（40臂上下文 Bandit）：基于用户反馈的在线个性化学习
 *
 * 使用流程：
 *   ActionRecommender rec;
 *   auto top3 = rec.recommend(physicalState);     // 推荐
 *   rec.reward(physicalState, top3[0].idx, 1.0f); // 用户接受 → 正反馈
 *   rec.reward(physicalState, top3[1].idx, 0.0f); // 用户拒绝 → 负反馈
 *
 * 特征向量（71维 one-hot）：
 *   time[9] + location[36] + motion[4] + phone[8] + light[5] + sound[5] + dayType[4]
 */
#pragma once

#include "state_code.h"
#include <array>
#include <vector>
#include <string>
#include <mutex>
#include <cmath>
#include <algorithm>
#include <fstream>

namespace context_engine {

// ============================================================
// 常量
// ============================================================

// ── 特征向量维度（92维，含预留槽）──────────────────────────────────
// 扩展规则：在预留槽内直接分配，不改变已有偏移，无需重训
//
//   Dim  | Used | Reserved | 说明
//  ------|------|----------|----------------------------------
//  time  |   9  |    3     | 新时段（如 nap=10）用 idx 9-11
//  loc   |  15  |   21     | G-Z 已预留，idx 24-34 可用
//  motion|   4  |    4     | cycling=5, transit=6 用 idx 4-7
//  phone |   8  |    4     | 新姿态用 idx 8-11
//  light |   5  |    3     | 用 idx 5-7
//  sound |   5  |    3     | 用 idx 5-7
//  dayType|  4  |    4     | travel=5, sick=6 用 idx 4-7

constexpr int ACT_FEAT_DIM = 92;   // 状态特征维度（含预留）
constexpr int ACT_HIDDEN   = 80;   // MLP 隐藏层
constexpr int ACT_COUNT    = 64;   // 动作总槽数（40已定义 + 24预留）
constexpr int ACT_DEFINED  = 40;   // 当前已定义动作数

// 特征向量各维度偏移（已固化，永不改变）
constexpr int OFF_TIME    = 0;   // 12 dims (9 used)
constexpr int OFF_LOC     = 12;  // 36 dims (15+1 used, G-Z reserved)
constexpr int OFF_MOTION  = 48;  // 8 dims  (4 used)
constexpr int OFF_PHONE   = 56;  // 12 dims (8 used)
constexpr int OFF_LIGHT   = 68;  // 8 dims  (5 used)
constexpr int OFF_SOUND   = 76;  // 8 dims  (5 used)
constexpr int OFF_DAYTYPE = 84;  // 8 dims  (4 used)

// ============================================================
// 状态特征向量
// ============================================================

struct ActFeature {
    float x[ACT_FEAT_DIM] = {};

    /** 从 PhysicalState 编码（与 StateCode 枚举值完全对应） */
    static ActFeature from(const PhysicalState& s) {
        ActFeature f;

        // Time: '1'-'9' → idx 0-8
        {
            char c = static_cast<char>(s.time);
            int i = (c >= '1' && c <= '9') ? (c - '1') : 0;
            f.x[OFF_TIME + i] = 1.0f;
        }
        // Location: '0'→35, '1'-'9'→0-8, 'A'-'Z'→9-34
        {
            char c = static_cast<char>(s.location);
            int i;
            if      (c == '0')                   i = 35;
            else if (c >= '1' && c <= '9')        i = c - '1';
            else if (c >= 'A' && c <= 'Z')        i = 9 + (c - 'A');
            else                                   i = 35;
            f.x[OFF_LOC + i] = 1.0f;
        }
        // Motion: '0'→3, '1'-'4'→0-3
        {
            char c = static_cast<char>(s.motion);
            int i = (c >= '1' && c <= '4') ? (c - '1') : 3;
            f.x[OFF_MOTION + i] = 1.0f;
        }
        // Phone: '0'→7, '1'-'8'→0-7
        {
            char c = static_cast<char>(s.phone);
            int i = (c >= '1' && c <= '8') ? (c - '1') : 7;
            f.x[OFF_PHONE + i] = 1.0f;
        }
        // Light: '0'-'4'→0-4
        {
            char c = static_cast<char>(s.light);
            int i = (c >= '0' && c <= '4') ? (c - '0') : 0;
            f.x[OFF_LIGHT + i] = 1.0f;
        }
        // Sound: '0'-'4'→0-4
        {
            char c = static_cast<char>(s.sound);
            int i = (c >= '0' && c <= '4') ? (c - '0') : 0;
            f.x[OFF_SOUND + i] = 1.0f;
        }
        // DayType: '0'-'3'→0-3
        {
            char c = static_cast<char>(s.dayType);
            int i = (c >= '0' && c <= '3') ? (c - '0') : 0;
            f.x[OFF_DAYTYPE + i] = 1.0f;
        }
        return f;
    }
};

// ============================================================
// Mini MLP（92 → 80 → 64）
// ============================================================

struct ActionMLP {
    float W1[ACT_HIDDEN][ACT_FEAT_DIM];
    float b1[ACT_HIDDEN];
    float W2[ACT_COUNT][ACT_HIDDEN];
    float b2[ACT_COUNT];

    /** 前向推理，输出 softmax 概率 */
    void forward(const ActFeature& feat, float out[ACT_COUNT]) const {
        float h[ACT_HIDDEN];
        // Layer 1: h = relu(W1 @ x + b1)
        for (int j = 0; j < ACT_HIDDEN; ++j) {
            float z = b1[j];
            for (int k = 0; k < ACT_FEAT_DIM; ++k) z += W1[j][k] * feat.x[k];
            h[j] = z > 0.0f ? z : 0.0f;  // ReLU
        }
        // Layer 2: logits = W2 @ h + b2
        float maxLogit = -1e9f;
        for (int i = 0; i < ACT_COUNT; ++i) {
            float z = b2[i];
            for (int j = 0; j < ACT_HIDDEN; ++j) z += W2[i][j] * h[j];
            out[i] = z;
            if (z > maxLogit) maxLogit = z;
        }
        // Softmax（数值稳定）
        float sum = 0.0f;
        for (int i = 0; i < ACT_COUNT; ++i) {
            out[i] = std::exp(out[i] - maxLogit);
            sum += out[i];
        }
        for (int i = 0; i < ACT_COUNT; ++i) out[i] /= sum;
    }

    /** 从预训练权重数组加载 */
    void loadFromArrays(
        const float w1[], const float b1_[],
        const float w2[], const float b2_[])
    {
        std::copy(w1, w1 + ACT_HIDDEN * ACT_FEAT_DIM, &W1[0][0]);
        std::copy(b1_, b1_ + ACT_HIDDEN, b1);
        std::copy(w2, w2 + ACT_COUNT * ACT_HIDDEN, &W2[0][0]);
        std::copy(b2_, b2_ + ACT_COUNT, b2);
    }
};

// ============================================================
// LinUCB 单臂（Upper Confidence Bound）
// ============================================================

/** 每个动作维护一个独立的 LinUCB 臂 */
struct UCBArm {
    // A = I + Σ x*xᵀ，b = Σ r*x
    // 初始化为单位矩阵（正则化先验）
    float A[ACT_FEAT_DIM][ACT_FEAT_DIM];
    float b[ACT_FEAT_DIM];
    int   n = 0;  // 更新次数

    UCBArm() {
        std::fill(&A[0][0], &A[0][0] + ACT_FEAT_DIM * ACT_FEAT_DIM, 0.0f);
        for (int i = 0; i < ACT_FEAT_DIM; ++i) A[i][i] = 1.0f;  // 单位矩阵
        std::fill(b, b + ACT_FEAT_DIM, 0.0f);
    }

    /**
     * 计算 UCB 分数：θᵀx + α * √(xᵀ A⁻¹ x)
     * 使用迭代法（不维护逆矩阵，直接用 Cholesky 近似）
     *
     * 简化实现：用对角近似 A⁻¹ ≈ diag(1/A[i][i])，节省计算
     */
    float score(const ActFeature& feat, float alpha) const {
        // θ ≈ A⁻¹b（对角近似：θ[i] ≈ b[i] / A[i][i]）
        float xTtheta = 0.0f;
        float xTAinvx = 0.0f;
        for (int i = 0; i < ACT_FEAT_DIM; ++i) {
            if (feat.x[i] == 0.0f) continue;
            float aii_inv = (A[i][i] > 1e-6f) ? 1.0f / A[i][i] : 1.0f;
            xTtheta += feat.x[i] * (b[i] * aii_inv);
            xTAinvx += feat.x[i] * feat.x[i] * aii_inv;
        }
        return xTtheta + alpha * std::sqrt(xTAinvx + 1e-6f);
    }

    /** 用户反馈更新：A += xxᵀ，b += r*x */
    void update(const ActFeature& feat, float reward) {
        for (int i = 0; i < ACT_FEAT_DIM; ++i) {
            if (feat.x[i] == 0.0f) continue;
            for (int j = 0; j < ACT_FEAT_DIM; ++j) {
                if (feat.x[j] == 0.0f) continue;
                A[i][j] += feat.x[i] * feat.x[j];
            }
            b[i] += reward * feat.x[i];
        }
        ++n;
    }
};

// ============================================================
// 动作元数据
// ============================================================

struct ActionMeta {
    const char* code;   // "A1", "B3" ...
    const char* name;   // "亮地铁码" ...
    const char* cat;    // "亮码", "日程" ...
};

inline const ActionMeta& actionMeta(int idx) {
    static const ActionMeta TABLE[ACT_COUNT] = {
        {"A1","亮地铁码","亮码"},   {"A2","亮公交码","亮码"},
        {"A3","亮支付码","亮码"},   {"A4","亮门票","亮码"},
        {"B1","查看今日日程","日程"},{"B2","查看明日日程","日程"},
        {"B3","查看下午日程","日程"},{"B4","设置闹钟","日程"},
        {"B5","设置出行提醒","日程"},{"B6","设置散场提醒","日程"},
        {"B7","检查行程/车票","日程"},{"B8","提醒检票时间","日程"},
        {"B9","下班提醒","日程"},
        {"C1","查看天气","天气"},
        {"D1","播放音乐","媒体"},   {"D2","播放白噪音","媒体"},
        {"D3","播放播客","媒体"},   {"D4","查看新闻","媒体"},
        {"E1","导航回家","导航"},   {"E2","导航到公司","导航"},
        {"E3","导航到餐厅","导航"}, {"E4","导航到店铺","导航"},
        {"E5","导航到枢纽","导航"}, {"E6","导航景点","导航"},
        {"E7","通用导航","导航"},   {"E8","停车位记录","导航"},
        {"F1","查看到站时间","交通"},{"F2","提醒下车站","交通"},
        {"F3","查看船班时刻","交通"},{"F4","查看场次座位","交通"},
        {"G1","久坐提醒","健康"},   {"G2","补水提醒","健康"},
        {"G3","拉伸提醒","健康"},   {"G4","查看步数","健康"},
        {"G5","休息提醒","健康"},
        {"H1","点餐建议","餐饮"},
        {"I1","联系人提醒","社交"},
        {"J1","关闭通知","系统"},   {"J2","静音确认","系统"},
        {"J3","注意财物","系统"},
    };
    return TABLE[idx >= 0 && idx < ACT_COUNT ? idx : 0];
}

/** 从 ActionCode 字符串（如 "B1"）查找索引，未找到返回 -1 */
inline int actionIndex(const std::string& code) {
    for (int i = 0; i < ACT_COUNT; ++i)
        if (code == actionMeta(i).code) return i;
    return -1;
}

// ============================================================
// ActionRecommender（MLP + LinUCB 组合推荐器）
// ============================================================

class ActionRecommender {
public:
    struct Recommendation {
        int   idx;          // 动作索引 0-39
        float score;        // 综合得分 [0,1]
        float mlp_prob;     // MLP 先验概率
        float ucb_score;    // LinUCB 分数
        const char* code;   // "A1"
        const char* name;   // "亮地铁码"
    };

    /**
     * @param mlpWeight  MLP 先验的权重（0~1），1-mlpWeight 给 LinUCB
     * @param ucbAlpha   UCB 探索参数（越大越探索）
     */
    explicit ActionRecommender(float mlpWeight = 0.6f, float ucbAlpha = 0.3f)
        : mlpWeight_(mlpWeight), ucbAlpha_(ucbAlpha)
    {
        loadPretrainedWeights();
    }

    /**
     * 推荐 top-K 动作
     * @param s     当前物理状态
     * @param topK  返回条数（默认3）
     */
    std::vector<Recommendation> recommend(const PhysicalState& s, int topK = 3) const {
        std::lock_guard<std::mutex> lock(mu_);
        const ActFeature feat = ActFeature::from(s);

        // MLP 前向推理
        float mlp[ACT_COUNT];
        mlp_.forward(feat, mlp);

        // LinUCB 分数 + 组合
        std::vector<std::pair<float,int>> scored(ACT_COUNT);
        for (int i = 0; i < ACT_COUNT; ++i) {
            float ucb = arms_[i].score(feat, ucbAlpha_);
            float combined = mlpWeight_ * mlp[i] + (1.0f - mlpWeight_) * std::tanh(ucb);
            scored[i] = { combined, i };
        }

        // 排序，取 Top-K
        std::partial_sort(scored.begin(), scored.begin() + topK, scored.end(),
            [](const auto& a, const auto& b){ return a.first > b.first; });

        // 重新算 UCB（用于返回值）
        std::vector<Recommendation> result;
        for (int k = 0; k < topK && k < ACT_COUNT; ++k) {
            auto [score, idx] = scored[k];
            result.push_back({
                idx, score, mlp[idx], arms_[idx].score(feat, ucbAlpha_),
                actionMeta(idx).code, actionMeta(idx).name
            });
        }
        return result;
    }

    /**
     * 用户反馈（在线学习）
     * @param s       触发时的物理状态
     * @param actIdx  被反馈的动作索引（0-39）
     * @param r       奖励：1.0=接受，0.5=中性，0.0=拒绝
     */
    void reward(const PhysicalState& s, int actIdx, float r) {
        if (actIdx < 0 || actIdx >= ACT_COUNT) return;
        std::lock_guard<std::mutex> lock(mu_);
        const ActFeature feat = ActFeature::from(s);
        arms_[actIdx].update(feat, r);
    }

    /** 重置所有 LinUCB 参数（清除个性化数据） */
    void reset() {
        std::lock_guard<std::mutex> lock(mu_);
        for (auto& arm : arms_) arm = UCBArm{};
    }

    /** 序列化 LinUCB 参数到文件（持久化） */
    bool save(const std::string& path) const {
        std::lock_guard<std::mutex> lock(mu_);
        std::ofstream f(path, std::ios::binary);
        if (!f) return false;
        for (const auto& arm : arms_) {
            f.write(reinterpret_cast<const char*>(&arm.A), sizeof(arm.A));
            f.write(reinterpret_cast<const char*>(&arm.b), sizeof(arm.b));
            f.write(reinterpret_cast<const char*>(&arm.n), sizeof(arm.n));
        }
        return f.good();
    }

    /** 从文件恢复 LinUCB 参数 */
    bool load(const std::string& path) {
        std::lock_guard<std::mutex> lock(mu_);
        std::ifstream f(path, std::ios::binary);
        if (!f) return false;
        for (auto& arm : arms_) {
            f.read(reinterpret_cast<char*>(&arm.A), sizeof(arm.A));
            f.read(reinterpret_cast<char*>(&arm.b), sizeof(arm.b));
            f.read(reinterpret_cast<char*>(&arm.n), sizeof(arm.n));
        }
        return f.good();
    }

    /** 获取各臂的反馈统计 */
    struct ArmStats { int idx; const char* code; int updates; float avgReward; };
    std::vector<ArmStats> stats() const {
        std::lock_guard<std::mutex> lock(mu_);
        std::vector<ArmStats> out;
        for (int i = 0; i < ACT_COUNT; ++i) {
            if (arms_[i].n > 0) {
                float avgR = 0.0f;
                for (int j = 0; j < ACT_FEAT_DIM; ++j) avgR += arms_[i].b[j];
                out.push_back({ i, actionMeta(i).code, arms_[i].n, avgR });
            }
        }
        return out;
    }

private:
    ActionMLP              mlp_;
    std::array<UCBArm, ACT_COUNT> arms_;
    float                  mlpWeight_;
    float                  ucbAlpha_;
    mutable std::mutex     mu_;

    void loadPretrainedWeights() {
#ifdef HAVE_ACTION_WEIGHTS
        // 如果 action_weights.h 已生成，从中加载
        mlp_.loadFromArrays(ACT_W1, ACT_B1, ACT_W2, ACT_B2);
#else
        // 未训练时：均匀初始化（推荐随机，依赖 LinUCB 学习）
        for (int j = 0; j < ACT_HIDDEN; ++j) {
            float scale = 1.0f / ACT_FEAT_DIM;
            for (int k = 0; k < ACT_FEAT_DIM; ++k)
                mlp_.W1[j][k] = scale * (static_cast<float>(rand()) / RAND_MAX - 0.5f);
            mlp_.b1[j] = 0.0f;
        }
        for (int i = 0; i < ACT_COUNT; ++i) {
            float scale = 1.0f / ACT_HIDDEN;
            for (int j = 0; j < ACT_HIDDEN; ++j)
                mlp_.W2[i][j] = scale * (static_cast<float>(rand()) / RAND_MAX - 0.5f);
            mlp_.b2[i] = 0.0f;
        }
#endif
    }
};

} // namespace context_engine
