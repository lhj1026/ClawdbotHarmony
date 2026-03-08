/**
 * action_recommender.h — 状态→动作推荐器
 *
 * V1 (legacy): MLP(185→128→64) + LinUCB, one-hot encoding, state pair
 * V2 (new):    MLP(60→64→64) + LinUCB, attribute encoding, state chain
 *
 * V2 improvements:
 *   - 19-dim semantic attribute encoding per state (vs 92-dim one-hot)
 *     including 8-dim location (5 category + 3 instance attributes)
 *   - State chain input with pooling (up to 6 steps, vs 2 states)
 *   - Extension-friendly: new locations/motions just add attribute rows
 *   - 60-dim input = [current(19) + mean(19) + delta(19) + time(3)]
 */
#pragma once

#include "state_code.h"
#include "state_attributes.h"
#include "pretrained_weights_v2.h"
#include "scenario_distiller.h"
#include <array>
#include <vector>
#include <string>
#include <mutex>
#include <cmath>
#include <algorithm>
#include <fstream>
#include <chrono>

namespace context_engine {

// ============================================================
// 常量
// ============================================================

// ── 特征向量维度（状态对编码，185维）──────────────────────────────
//
//   [当前状态 92维] | [上一状态 92维] | [在当前状态时长 1维]
//
//   单状态 92维布局（偏移从 0 或 92 开始）：
//   Dim     | Used | Reserved | 偏移(在单状态内)
//  ---------|------|----------|-----------------
//  time     |   9  |    3     | 0
//  location |  15  |   21     | 12   (G-Z 预留)
//  motion   |   4  |    4     | 48
//  phone    |   8  |    4     | 56
//  light    |   5  |    3     | 68
//  sound    |   5  |    3     | 76
//  dayType  |   4  |    4     | 84
//  total    |  50  |   42     | = 92
//
//   time_norm (1维，偏移184):
//     0.0 = 刚到(<5min)  0.33 = 稳定(5-30min)  0.67 = 久留(30-120min)  1.0 = 超长(>2h)

constexpr int ACT_SINGLE_DIM = 92;            // 单状态编码维度
constexpr int ACT_FEAT_DIM   = 185;           // 92(curr) + 92(prev) + 1(time)
constexpr int ACT_HIDDEN     = 128;           // MLP 隐藏层
constexpr int ACT_DEFINED    = 40;            // 当前已定义动作数

// 单状态内各维度偏移（永不改变）
constexpr int OFF_TIME    = 0;   // 12 dims (9 used)
constexpr int OFF_LOC     = 12;  // 36 dims
constexpr int OFF_MOTION  = 48;  // 8 dims  (4 used)
constexpr int OFF_PHONE   = 56;  // 12 dims (8 used)
constexpr int OFF_LIGHT   = 68;  // 8 dims  (5 used)
constexpr int OFF_SOUND   = 76;  // 8 dims  (5 used)
constexpr int OFF_DAYTYPE = 84;  // 8 dims  (4 used)

// ============================================================
// 状态历史记录（环形缓冲区）
// ============================================================

/** 简单时钟（秒），可替换为系统时间 */
inline double nowSeconds() {
    auto tp = std::chrono::system_clock::now().time_since_epoch();
    return std::chrono::duration<double>(tp).count();
}

struct StateHistory {
    static const int MAX = 8;

    struct Entry {
        PhysicalState state;
        double timestamp = 0.0;
    };

    Entry entries[MAX];
    int   head  = 0;
    int   count = 0;

    /** 记录一个新状态 */
    void push(const PhysicalState& s) {
        entries[head] = { s, nowSeconds() };
        head  = (head + 1) % MAX;
        if (count < MAX) ++count;
    }

    /** 上一个状态（若无返回 nullptr） */
    const PhysicalState* prev() const {
        if (count < 2) return nullptr;
        int idx = (head - 2 + MAX) % MAX;
        return &entries[idx].state;
    }

    /** 当前状态在此状态的持续时长（归一化 0~1）
     *  0.0=<5min  0.33=5-30min  0.67=30-120min  1.0=>2h */
    float timeNorm() const {
        if (count == 0) return 0.0f;
        int currIdx = (head - 1 + MAX) % MAX;
        double elapsed = nowSeconds() - entries[currIdx].timestamp;
        if (elapsed < 300)   return 0.0f;
        if (elapsed < 1800)  return 0.33f;
        if (elapsed < 7200)  return 0.67f;
        return 1.0f;
    }
};

// ============================================================
// 状态特征向量
// ============================================================

struct ActFeature {
    float x[ACT_FEAT_DIM] = {};

    /** 单状态编码（不含历史，prev 全零，time=0）*/
    static ActFeature from(const PhysicalState& s) {
        ActFeature f;
        encodeSingle(s, f.x, 0);
        // f.x[184] = 0.0f  (刚到，默认)
        return f;
    }

    /** 状态对编码（curr + prev + time_norm）
     *  @param curr     当前状态
     *  @param prev     上一状态
     *  @param timeNorm 在当前状态的时长归一化 (0.0~1.0)
     */
    static ActFeature fromPair(const PhysicalState& curr,
                               const PhysicalState& prev,
                               float timeNorm) {
        ActFeature f;
        encodeSingle(curr, f.x, 0);                 // 偏移 0-91
        encodeSingle(prev, f.x, ACT_SINGLE_DIM);    // 偏移 92-183
        f.x[ACT_SINGLE_DIM * 2] = timeNorm;         // 偏移 184
        return f;
    }

private:
    /** 将单个 PhysicalState 编码到 x[offset..offset+92) */
    static void encodeSingle(const PhysicalState& s, float* x, int offset) {
        // Time: '1'-'9' → 0-8
        {
            char c = static_cast<char>(s.time);
            int i = (c >= '1' && c <= '9') ? (c - '1') : 0;
            x[offset + OFF_TIME + i] = 1.0f;
        }
        // Location: '0'→35, '1'-'9'→0-8, 'A'-'Z'→9-34
        {
            char c = static_cast<char>(s.location);
            int i = (c == '0') ? 35 :
                    (c >= '1' && c <= '9') ? (c - '1') :
                    (c >= 'A' && c <= 'Z') ? 9 + (c - 'A') : 35;
            x[offset + OFF_LOC + i] = 1.0f;
        }
        // Motion: '0'→3, '1'-'4'→0-3
        {
            char c = static_cast<char>(s.motion);
            int i = (c >= '1' && c <= '4') ? (c - '1') : 3;
            x[offset + OFF_MOTION + i] = 1.0f;
        }
        // Phone: '0'→7, '1'-'8'→0-7
        {
            char c = static_cast<char>(s.phone);
            int i = (c >= '1' && c <= '8') ? (c - '1') : 7;
            x[offset + OFF_PHONE + i] = 1.0f;
        }
        // Light: '0'-'4'→0-4
        {
            char c = static_cast<char>(s.light);
            int i = (c >= '0' && c <= '4') ? (c - '0') : 0;
            x[offset + OFF_LIGHT + i] = 1.0f;
        }
        // Sound: '0'-'4'→0-4
        {
            char c = static_cast<char>(s.sound);
            int i = (c >= '0' && c <= '4') ? (c - '0') : 0;
            x[offset + OFF_SOUND + i] = 1.0f;
        }
        // DayType: '0'-'3'→0-3
        {
            char c = static_cast<char>(s.dayType);
            int i = (c >= '0' && c <= '3') ? (c - '0') : 0;
            x[offset + OFF_DAYTYPE + i] = 1.0f;
        }
    }
};

// ============================================================
// Mini MLP（185 → 128 → 64）
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
    std::vector<Recommendation> recommend(const PhysicalState& s, int topK = 3) {
        std::lock_guard<std::mutex> lock(mu_);
        // 更新状态历史
        history_.push(s);
        // 构建状态对特征（有历史则用 fromPair，否则用单状态）
        ActFeature feat;
        const PhysicalState* prev = history_.prev();
        if (prev) {
            feat = ActFeature::fromPair(s, *prev, history_.timeNorm());
        } else {
            feat = ActFeature::from(s);
        }

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
        // 反馈时也用状态对特征（与推荐时保持一致）
        ActFeature feat;
        const PhysicalState* prev = history_.prev();
        if (prev) {
            feat = ActFeature::fromPair(s, *prev, history_.timeNorm());
        } else {
            feat = ActFeature::from(s);
        }
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
    StateHistory           history_;       // 状态历史（状态对特征的数据源）
    float                  mlpWeight_;
    float                  ucbAlpha_;
    mutable std::mutex     mu_;            // mutable 保留：const 方法(save/stats)也需要加锁

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

// ============================================================
// V2: Attribute-Encoded Chain Recommender (60 → 64 → 64)
// ============================================================

/** Mini MLP for V2: 60 → 64 → 64 */
struct ActionMLPv2 {
    static constexpr int IN  = SA_CHAIN_DIM;  // 51
    static constexpr int HID = 64;
    static constexpr int OUT = ACT_COUNT;     // 64

    float W1[HID][IN];
    float b1[HID];
    float W2[OUT][HID];
    float b2[OUT];

    void forward(const ChainFeature& feat, float out[OUT]) const {
        float h[HID];
        for (int j = 0; j < HID; ++j) {
            float z = b1[j];
            for (int k = 0; k < IN; ++k) z += W1[j][k] * feat.x[k];
            h[j] = z > 0.0f ? z : 0.0f;  // ReLU
        }
        float maxLogit = -1e9f;
        for (int i = 0; i < OUT; ++i) {
            float z = b2[i];
            for (int j = 0; j < HID; ++j) z += W2[i][j] * h[j];
            out[i] = z;
            if (z > maxLogit) maxLogit = z;
        }
        float sum = 0.0f;
        for (int i = 0; i < OUT; ++i) {
            out[i] = std::exp(out[i] - maxLogit);
            sum += out[i];
        }
        for (int i = 0; i < OUT; ++i) out[i] /= sum;
    }

    void initRandom() {
        auto rnd = [](){ return static_cast<float>(rand()) / RAND_MAX - 0.5f; };
        float scaleIn = 1.0f / IN;
        for (int j = 0; j < HID; ++j) {
            for (int k = 0; k < IN; ++k) W1[j][k] = scaleIn * rnd();
            b1[j] = 0.0f;
        }
        float scaleHid = 1.0f / HID;
        for (int i = 0; i < OUT; ++i) {
            for (int j = 0; j < HID; ++j) W2[i][j] = scaleHid * rnd();
            b2[i] = 0.0f;
        }
    }
};

/** LinUCB arm for V2: 60-dim context */
struct UCBArmV2 {
    // Diagonal approximation only (full 60x60 matrix is small enough but
    // diagonal gives good results and is 10x faster for update/score)
    float diag_A[SA_CHAIN_DIM];   // diagonal of A
    float b[SA_CHAIN_DIM];
    int   n = 0;

    UCBArmV2() {
        for (int i = 0; i < SA_CHAIN_DIM; ++i) { diag_A[i] = 1.0f; b[i] = 0.0f; }
    }

    float score(const ChainFeature& feat, float alpha) const {
        float xTtheta = 0.0f;
        float xTAinvx = 0.0f;
        for (int i = 0; i < SA_CHAIN_DIM; ++i) {
            float aii_inv = 1.0f / (diag_A[i] + 1e-6f);
            xTtheta += feat.x[i] * b[i] * aii_inv;
            xTAinvx += feat.x[i] * feat.x[i] * aii_inv;
        }
        return xTtheta + alpha * std::sqrt(xTAinvx + 1e-6f);
    }

    void update(const ChainFeature& feat, float reward) {
        for (int i = 0; i < SA_CHAIN_DIM; ++i) {
            diag_A[i] += feat.x[i] * feat.x[i];
            b[i] += reward * feat.x[i];
        }
        ++n;
    }
};

/** Online SGD trainer for MLP V2 (distillation from LLM labels) */
struct MLPTrainerV2 {
    float learningRate = 0.01f;

    /**
     * Train one step: given chain feature and target action distribution.
     * @param mlp      the MLP to update in-place
     * @param feat     60-dim input
     * @param target   target probability distribution over ACT_COUNT actions
     *                 (e.g., from LLM: [0,0,...,0.8,0.15,0.05,...])
     */
    void trainStep(ActionMLPv2& mlp, const ChainFeature& feat, const float target[ACT_COUNT]) {
        constexpr int IN = ActionMLPv2::IN;
        constexpr int HID = ActionMLPv2::HID;
        constexpr int OUT = ActionMLPv2::OUT;

        // Forward pass (store intermediates)
        float h[HID], h_pre[HID];
        for (int j = 0; j < HID; ++j) {
            float z = mlp.b1[j];
            for (int k = 0; k < IN; ++k) z += mlp.W1[j][k] * feat.x[k];
            h_pre[j] = z;
            h[j] = z > 0.0f ? z : 0.0f;
        }

        float logits[OUT], pred[OUT];
        float maxL = -1e9f;
        for (int i = 0; i < OUT; ++i) {
            float z = mlp.b2[i];
            for (int j = 0; j < HID; ++j) z += mlp.W2[i][j] * h[j];
            logits[i] = z;
            if (z > maxL) maxL = z;
        }
        float sum = 0.0f;
        for (int i = 0; i < OUT; ++i) {
            pred[i] = std::exp(logits[i] - maxL);
            sum += pred[i];
        }
        for (int i = 0; i < OUT; ++i) pred[i] /= sum;

        // Backward: dL/dlogits = pred - target (cross-entropy gradient)
        float dLogits[OUT];
        for (int i = 0; i < OUT; ++i) dLogits[i] = pred[i] - target[i];

        // Update W2, b2
        float dH[HID] = {};
        for (int i = 0; i < OUT; ++i) {
            for (int j = 0; j < HID; ++j) {
                dH[j] += mlp.W2[i][j] * dLogits[i];
                mlp.W2[i][j] -= learningRate * dLogits[i] * h[j];
            }
            mlp.b2[i] -= learningRate * dLogits[i];
        }

        // ReLU backward
        for (int j = 0; j < HID; ++j) {
            if (h_pre[j] <= 0.0f) dH[j] = 0.0f;
        }

        // Update W1, b1
        for (int j = 0; j < HID; ++j) {
            for (int k = 0; k < IN; ++k) {
                mlp.W1[j][k] -= learningRate * dH[j] * feat.x[k];
            }
            mlp.b1[j] -= learningRate * dH[j];
        }
    }
};

// ============================================================
// ActionRecommenderV2: Main V2 interface
// ============================================================

class ActionRecommenderV2 {
public:
    struct Recommendation {
        int   idx;
        float score;
        float mlp_prob;
        float ucb_score;
        const char* code;
        const char* name;
    };

    explicit ActionRecommenderV2(float mlpWeight = 0.6f, float ucbAlpha = 0.3f)
        : mlpWeight_(mlpWeight), ucbAlpha_(ucbAlpha)
    {
        loadDistilledWeights();
    }

    /**
     * Push new state and get recommendations.
     * State chain is maintained internally.
     * @param instAttr  Instance attributes from geofence (familiarity, ownership, routineLevel)
     */
    /**
     * 三层推荐架构:
     *   Tier 1: ScenarioDistiller 链匹配 (confidence > 0.55 → 加权混合)
     *   Tier 2: MLP(distilled) 泛化推理
     *   Tier 3: LinUCB 在线个性化
     *
     * 融合公式:
     *   score[i] = scenarioW * scenario[i]
     *            + mlpW * mlp[i]
     *            + ucbW * tanh(ucb[i])
     *
     * 当场景匹配时 scenarioW=0.4, mlpW=0.35, ucbW=0.25
     * 当无匹配时   scenarioW=0,   mlpW=0.6,  ucbW=0.4
     */
    std::vector<Recommendation> recommend(const PhysicalState& s, int topK = 3,
                                           const LocInstanceAttr& instAttr = {}) {
        std::lock_guard<std::mutex> lock(mu_);
        chain_.push(s, instAttr);
        lastFeat_ = ChainFeature::build(chain_);

        // Tier 2: MLP prediction
        float mlp[ACT_COUNT];
        mlp_.forward(lastFeat_, mlp);

        // Tier 1: Scenario chain matching
        auto match = distiller_.match(chain_);
        lastMatchConf_ = match.confidence;

        // Compute fusion weights
        float sW, mW, uW;
        if (match.confidence >= ScenarioDistiller::MATCH_THRESHOLD && match.actionDist) {
            // Scenario matched — blend all three
            sW = 0.4f * match.confidence;  // scale by confidence
            mW = mlpWeight_ * (1.0f - sW);
            uW = (1.0f - mlpWeight_) * (1.0f - sW);
        } else {
            // No match — original MLP + UCB
            sW = 0.0f;
            mW = mlpWeight_;
            uW = 1.0f - mlpWeight_;
        }

        std::vector<std::pair<float,int>> scored(ACT_COUNT);
        for (int i = 0; i < ACT_COUNT; ++i) {
            float ucb = arms_[i].score(lastFeat_, ucbAlpha_);
            float scenarioScore = (sW > 0.0f && match.actionDist) ? match.actionDist[i] : 0.0f;
            float combined = sW * scenarioScore + mW * mlp[i] + uW * std::tanh(ucb);
            scored[i] = { combined, i };
        }

        std::partial_sort(scored.begin(), scored.begin() + topK, scored.end(),
            [](const auto& a, const auto& b){ return a.first > b.first; });

        std::vector<Recommendation> result;
        for (int k = 0; k < topK && k < ACT_COUNT; ++k) {
            auto [score, idx] = scored[k];
            result.push_back({
                idx, score, mlp[idx], arms_[idx].score(lastFeat_, ucbAlpha_),
                actionMeta(idx).code, actionMeta(idx).name
            });
        }
        return result;
    }

    /** User feedback (online learning via LinUCB) */
    void reward(const PhysicalState& s, int actIdx, float r) {
        if (actIdx < 0 || actIdx >= ACT_COUNT) return;
        std::lock_guard<std::mutex> lock(mu_);
        // Use stored feature from last recommend() call
        arms_[actIdx].update(lastFeat_, r);
    }

    /** LLM distillation: train MLP with LLM-generated target distribution
     *  Also learns the pattern in ScenarioDistiller for future fast-path matching */
    void trainFromLLM(const float target[ACT_COUNT]) {
        std::lock_guard<std::mutex> lock(mu_);
        trainer_.trainStep(mlp_, lastFeat_, target);
        // Learn new pattern in distiller (handles dedup internally)
        distiller_.learnPattern(chain_, target);
    }

    /** Train with explicit chain feature (for batch/offline training) */
    void trainFromLLMWithFeature(const ChainFeature& feat, const float target[ACT_COUNT]) {
        std::lock_guard<std::mutex> lock(mu_);
        trainer_.trainStep(mlp_, feat, target);
    }

    /** Get combined confidence (for LLM gating)
     *  Returns max of: scenario match confidence, MLP top probability
     *  High value = confident, no need for LLM */
    float topConfidence() const {
        std::lock_guard<std::mutex> lock(mu_);
        float mlp[ACT_COUNT];
        mlp_.forward(lastFeat_, mlp);
        float maxP = 0.0f;
        for (int i = 0; i < ACT_COUNT; ++i) {
            if (mlp[i] > maxP) maxP = mlp[i];
        }
        // Scenario match confidence boosts overall confidence
        return std::max(maxP, lastMatchConf_);
    }

    /** Reset LinUCB to initial state (keeps distilled MLP weights) */
    void reset() {
        std::lock_guard<std::mutex> lock(mu_);
        for (auto& arm : arms_) arm = UCBArmV2{};
        loadDistilledWeights();  // reload distilled, not random
        chain_ = StateChain{};
        lastMatchConf_ = 0.0f;
    }

    /** Get state chain as formatted string (for LLM prompt) */
    std::string getChainDescription() const {
        std::lock_guard<std::mutex> lock(mu_);
        if (chain_.count == 0) return "[]";

        std::string result = "[";
        for (int i = 0; i < chain_.count; ++i) {
            const auto& e = chain_.at(i);
            if (i > 0) result += ",";
            result += "{\"step\":";
            result += std::to_string(i + 1);
            result += ",\"time\":\"";
            result += StateCode::timeName(e.state.time);
            result += "\",\"location\":\"";
            result += StateCode::locationName(e.state.location);
            result += "\",\"motion\":\"";
            result += StateCode::motionName(e.state.motion);
            result += "\",\"phone\":\"";
            result += StateCode::phoneName(e.state.phone);
            result += "\",\"light\":\"";
            result += StateCode::lightName(e.state.light);
            result += "\",\"sound\":\"";
            result += StateCode::soundName(e.state.sound);
            result += "\",\"dayType\":\"";
            result += StateCode::dayTypeName(e.state.dayType);
            result += "\",\"code\":\"";
            result += StateCode::encode(e.state);
            result += "\"}";
        }
        result += "]";
        return result;
    }

    /** Serialize V2 state (LinUCB arms + MLP weights) */
    bool save(const std::string& path) const {
        std::lock_guard<std::mutex> lock(mu_);
        std::ofstream f(path, std::ios::binary);
        if (!f) return false;
        uint32_t magic = 0x56324152;  // "V2AR"
        uint32_t version = 2;         // v2: includes distiller learned patterns
        f.write(reinterpret_cast<const char*>(&magic), 4);
        f.write(reinterpret_cast<const char*>(&version), 4);
        // MLP weights
        f.write(reinterpret_cast<const char*>(&mlp_), sizeof(mlp_));
        // LinUCB arms
        for (const auto& arm : arms_) {
            f.write(reinterpret_cast<const char*>(&arm), sizeof(arm));
        }
        return f.good();
    }

    /** Save learned scenario patterns (separate file) */
    bool saveLearnedPatterns(const std::string& path) const {
        std::lock_guard<std::mutex> lock(mu_);
        return distiller_.saveLearned(path);
    }

    bool load(const std::string& path) {
        std::lock_guard<std::mutex> lock(mu_);
        std::ifstream f(path, std::ios::binary);
        if (!f) return false;
        uint32_t magic, version;
        f.read(reinterpret_cast<char*>(&magic), 4);
        f.read(reinterpret_cast<char*>(&version), 4);
        if (magic != 0x56324152 || (version != 1 && version != 2)) return false;
        f.read(reinterpret_cast<char*>(&mlp_), sizeof(mlp_));
        for (auto& arm : arms_) {
            f.read(reinterpret_cast<char*>(&arm), sizeof(arm));
        }
        return f.good();
    }

    /** Load learned scenario patterns */
    bool loadLearnedPatterns(const std::string& path) {
        std::lock_guard<std::mutex> lock(mu_);
        return distiller_.loadLearned(path);
    }

    /** Stats for diagnostics */
    struct ArmStats { int idx; const char* code; int updates; };
    std::vector<ArmStats> stats() const {
        std::lock_guard<std::mutex> lock(mu_);
        std::vector<ArmStats> out;
        for (int i = 0; i < ACT_COUNT; ++i) {
            if (arms_[i].n > 0) {
                out.push_back({ i, actionMeta(i).code, arms_[i].n });
            }
        }
        return out;
    }

    /** Distiller diagnostics */
    int scenarioBuiltinCount() const { return distiller_.builtinCount(); }
    int scenarioLearnedCount() const { return distiller_.learnedCount(); }
    float lastScenarioConfidence() const { return lastMatchConf_; }

    /** Access distiller for direct pattern learning (used by NAPI) */
    ScenarioDistiller& distiller() { return distiller_; }

private:
    ActionMLPv2            mlp_;
    MLPTrainerV2           trainer_;
    ScenarioDistiller      distiller_;     // Tier 1: scenario chain matching
    std::array<UCBArmV2, ACT_COUNT> arms_;
    StateChain             chain_;
    ChainFeature           lastFeat_;
    float                  mlpWeight_;
    float                  ucbAlpha_;
    float                  lastMatchConf_ = 0.0f; // last scenario match confidence
    mutable std::mutex     mu_;

    /** Load distilled MLP weights from pretrained_weights_v2.h */
    void loadDistilledWeights() {
        constexpr int IN  = ActionMLPv2::IN;
        constexpr int HID = ActionMLPv2::HID;
        constexpr int OUT = ActionMLPv2::OUT;
        // Copy from static arrays generated by distill_scenarios.py
        std::copy(DISTILLED_W1, DISTILLED_W1 + HID * IN, &mlp_.W1[0][0]);
        std::copy(DISTILLED_B1, DISTILLED_B1 + HID, mlp_.b1);
        std::copy(DISTILLED_W2, DISTILLED_W2 + OUT * HID, &mlp_.W2[0][0]);
        std::copy(DISTILLED_B2, DISTILLED_B2 + OUT, mlp_.b2);
    }
};

} // namespace context_engine
