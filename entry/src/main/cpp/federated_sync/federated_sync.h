/**
 * federated_sync.h — 联邦学习同步 C++ 核心实现
 *
 * 功能:
 * - 匿名化规则导出（去除 WiFi SSID、围栏名、GPS、蓝牙设备名）
 * - 行为模式聚合导出
 * - 联邦模型解析与社区规则转换
 * - SHA256 指纹生成（设备ID、条件集合）
 *
 * 三层联邦:
 * - L1: 规则联邦 — 高置信度匿名化规则
 * - L2: LinUCB 联邦 — bandit 模型参数（本身无 PII）
 * - L3: 行为模式 — 聚合统计（时段×地点类别×动作频次）
 */
#pragma once

#include <string>
#include <vector>
#include <map>
#include <set>
#include <cstdint>
#include <mutex>

namespace federated_sync {

// ============================================================
// 数据结构
// ============================================================

/** 匿名化条件 */
struct AnonymizedCondition {
    std::string key;    // timeOfDay, motionState, placeCategory, etc.
    std::string op;     // eq, neq, gt, lt, etc.
    std::string value;  // 已匿名化的值
};

/** 匿名化规则 */
struct AnonymizedRule {
    std::string conditionFingerprint;  // SHA256(排序后的条件集合)
    std::vector<AnonymizedCondition> conditions;
    std::string actionType;            // suggestion/automation/notification
    std::string actionPayloadHash;     // SHA256(payload) — 用于去重
    double confidence;
    int triggerCount;
    int acceptCount;
};

/** 行为模式 — 聚合统计 */
struct BehaviorPattern {
    std::string placeCategory;  // home/work/gym/unknown
    std::string timeOfDay;      // dawn/morning/afternoon/evening/night
    std::string dayType;        // weekday/weekend
    std::string motionState;
    std::string actionType;
    int frequency;              // 出现频次
};

/** 社区规则 — 服务器聚合后下发 */
struct CommunityRule {
    std::string id;             // 'community_' prefix
    std::vector<AnonymizedCondition> conditions;
    std::string actionType;
    std::string actionPayload;  // 服务器生成的建议文本
    double communityConfidence;
    int deviceCount;
    std::string name;
};

/** 聚合模型 — 服务器 → 设备 */
struct FederatedModel {
    int protocolVersion;
    int64_t aggregatedAt;
    int participantCount;
    std::vector<CommunityRule> communityRules;
    std::string linucbState;    // optional
    std::vector<BehaviorPattern> topPatterns;
    int modelVersion;
};

/** 围栏类别映射 — 从 ArkTS 传入 */
struct GeofenceCategoryEntry {
    std::string geofenceId;
    std::string category;       // home/work/gym/transit/shopping/restaurant/custom
};

// ============================================================
// 输入数据结构（从 ArkTS JSON 解析）
// ============================================================

/** 规则条件 — 对应 ContextEngine 的 Condition */
struct RuleCondition {
    std::string key;
    std::string op;
    std::string value;
};

/** 规则动作 */
struct RuleAction {
    std::string id;
    std::string type;
    std::string payload;
};

/** 引擎规则 — 对应 ContextEngine 的 Rule (带统计信息) */
struct EngineRule {
    std::string id;
    std::string name;
    std::vector<RuleCondition> conditions;
    RuleAction action;
    double priority;
    int64_t cooldownMs;
    bool enabled;
    // 统计信息 (从 MAB stats 补充)
    int triggerCount;
    int acceptCount;
    double confidence;
};

/** 行为记录 — 从 BehaviorLogger 导出 */
struct BehaviorRecord {
    std::string placeCategory;
    std::string timeOfDay;
    bool isWeekend;
    std::string motionState;
    std::string actionType;
};

// ============================================================
// 联邦同步核心类
// ============================================================

class FederatedSync {
public:
    static FederatedSync& getInstance();

    /**
     * 初始化
     * @param deviceId 设备标识（将做 SHA256 哈希）
     */
    void init(const std::string& deviceId);

    /**
     * 设置围栏类别映射
     */
    void setGeofenceCategories(const std::vector<GeofenceCategoryEntry>& categories);

    /**
     * 导出匿名化规则
     * @param rulesJson 从 ContextEngine.exportRules() 获取的 JSON
     * @param statsJson 从 ContextEngine.getStats() 获取的 MAB 统计 JSON
     * @return 匿名化后的规则列表
     */
    std::vector<AnonymizedRule> exportAnonymizedRules(
        const std::string& rulesJson,
        const std::string& statsJson);

    /**
     * 导出聚合行为模式
     * @param records 行为记录列表
     * @return 聚合后的行为模式
     */
    std::vector<BehaviorPattern> exportBehaviorPatterns(
        const std::vector<BehaviorRecord>& records);

    /**
     * 构建联邦模型更新 JSON（设备 → 服务器）
     * @param rulesJson 引擎规则 JSON
     * @param statsJson MAB 统计 JSON
     * @param linucbJson LinUCB 状态 JSON
     * @param records 行为记录
     * @param localDataPoints 本地训练样本数
     * @return FederatedModelUpdate JSON 字符串
     */
    std::string buildModelUpdate(
        const std::string& rulesJson,
        const std::string& statsJson,
        const std::string& linucbJson,
        const std::vector<BehaviorRecord>& records,
        int localDataPoints);

    /**
     * 解析服务器返回的联邦模型
     * @param modelJson 服务器 JSON
     * @return 解析后的 FederatedModel
     */
    FederatedModel parseFederatedModel(const std::string& modelJson);

    /**
     * 将社区规则转换为引擎规则 JSON（用于 addPendingRule）
     * @param rules 社区规则列表
     * @return JSON 数组字符串
     */
    std::string communityRulesToEngineJson(
        const std::vector<CommunityRule>& rules);

    /**
     * 获取设备指纹（SHA256 哈希后）
     */
    std::string getDeviceFingerprint() const;

private:
    FederatedSync();
    ~FederatedSync() = default;
    FederatedSync(const FederatedSync&) = delete;
    FederatedSync& operator=(const FederatedSync&) = delete;

    // 匿名化
    bool anonymizeCondition(const RuleCondition& cond,
                            AnonymizedCondition& out) const;
    std::string getGeofenceCategory(const std::string& geofenceId) const;
    std::string findGeofenceByCategory(const std::string& category) const;

    // JSON 解析
    std::vector<EngineRule> parseRules(const std::string& json) const;
    std::map<std::string, int> parseStats(const std::string& json) const;

    // SHA256
    std::string sha256(const std::string& input) const;

    // JSON 工具
    std::string escapeJson(const std::string& s) const;
    int64_t currentTimeMs() const;

    // 安全 key 白名单
    static const std::set<std::string>& safeKeys();

    std::string deviceId_;
    std::string deviceFingerprint_;
    std::map<std::string, std::string> geofenceToCategory_;   // id → category
    std::map<std::string, std::string> categoryToGeofence_;   // category → first id
    mutable std::mutex mutex_;
};

}  // namespace federated_sync
