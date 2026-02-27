/**
 * training_sync.h — 训练数据同步 C++ 实现
 *
 * 功能：
 * - 收集用户行为数据、规则匹配结果、反馈记录
 * - 本地缓冲管理、TTL清理
 * - 序列化为JSON供ArkTS上传
 *
 * 数据类型：
 * - RULE_MATCH: 规则匹配记录
 * - USER_FEEDBACK: 用户反馈
 * - STATE_TRANSITION: 状态转换
 * - GEOFENCE_FEATURE: 围栏特征
 */
#pragma once

#include <string>
#include <vector>
#include <map>
#include <cstdint>
#include <mutex>

namespace training_sync {

// ============================================================
// 数据类型
// ============================================================

/** 训练数据类型 */
enum class TrainingDataType {
    RULE_MATCH = 0,
    USER_FEEDBACK = 1,
    STATE_TRANSITION = 2,
    GEOFENCE_FEATURE = 3
};

/** 训练记录 */
struct TrainingRecord {
    std::string id;
    TrainingDataType type;
    int64_t timestamp;
    std::map<std::string, std::string> stringData;
    std::map<std::string, double> numericData;
    std::map<std::string, bool> boolData;
    bool synced;
    
    TrainingRecord() : timestamp(0), synced(false) {}
};

/** 规则匹配数据 */
struct RuleMatchData {
    std::string ruleId;
    std::string action;
    double confidence;
    std::string timeOfDay;
    int hour;
    std::string motionState;
    std::string prevMotionState;
    std::string prevActivityState;
    int64_t activityDuration;
    std::string geofence;
    std::string wifiSsid;
    int batteryLevel;
    bool isCharging;
    
    RuleMatchData() : confidence(0), hour(0), activityDuration(0), batteryLevel(0), isCharging(false) {}
};

/** 用户反馈数据 */
struct UserFeedbackData {
    std::string ruleId;
    std::string feedbackType;
    std::string originalValue;
    std::string adjustedValue;
    std::string timeOfDay;
    int hour;
    std::string motionState;
    std::string prevActivityState;
    int64_t activityDuration;
    std::string geofence;
    
    UserFeedbackData() : hour(0), activityDuration(0) {}
};

/** 状态转换数据 */
struct StateTransitionData {
    std::string prevState;
    std::string newState;
    int64_t duration;
    std::string timeOfDay;
    int hour;
    std::string geofence;
    std::string wifiSsid;
    
    StateTransitionData() : duration(0), hour(0) {}
};

/** 围栏特征数据 */
struct GeofenceFeatureData {
    std::string geofenceId;
    std::string geofenceName;
    std::string wifiSsid;
    std::string timeOfDay;
    int hour;
    int64_t duration;
    
    GeofenceFeatureData() : hour(0), duration(0) {}
};

/** 同步统计 */
struct SyncStats {
    int pendingCount;
    int syncedCount;
    int64_t lastSyncTime;
    int64_t totalRecords;
    
    SyncStats() : pendingCount(0), syncedCount(0), lastSyncTime(0), totalRecords(0) {}
};

// ============================================================
// 训练数据同步器
// ============================================================

class TrainingDataSync {
public:
    static TrainingDataSync& getInstance();
    
    /**
     * 初始化
     */
    void init(const std::string& deviceId);
    
    /**
     * 记录规则匹配
     */
    void recordRuleMatch(const RuleMatchData& data);
    
    /**
     * 记录用户反馈
     */
    void recordFeedback(const UserFeedbackData& data);
    
    /**
     * 记录状态转换
     */
    void recordStateTransition(const StateTransitionData& data);
    
    /**
     * 记录围栏特征
     */
    void recordGeofenceFeature(const GeofenceFeatureData& data);
    
    /**
     * 导出待同步数据为JSON
     */
    std::string exportPendingAsJson();
    
    /**
     * 标记为已同步
     */
    void markAsSynced(const std::vector<std::string>& ids);
    
    /**
     * 清理已同步的记录
     */
    void cleanupSynced();
    
    /**
     * 获取统计信息
     */
    SyncStats getStats() const;
    
    /**
     * 序列化全部数据 (持久化用)
     */
    std::string serialize() const;
    
    /**
     * 反序列化 (恢复用)
     */
    bool deserialize(const std::string& json);
    
    /**
     * 清空所有数据
     */
    void clear();
    
    /**
     * 设置最大记录数
     */
    void setMaxRecords(int maxRecords);
    
    /**
     * 获取设备ID
     */
    std::string getDeviceId() const;

private:
    TrainingDataSync();
    ~TrainingDataSync() = default;
    
    TrainingDataSync(const TrainingDataSync&) = delete;
    TrainingDataSync& operator=(const TrainingDataSync&) = delete;
    
    std::string generateId(const std::string& prefix);
    void pruneIfNeeded();
    std::string escapeJson(const std::string& s) const;
    int64_t currentTimeMs() const;
    
    std::string deviceId_;
    std::vector<TrainingRecord> records_;
    int64_t lastSyncTime_;
    int maxRecords_;
    mutable std::mutex mutex_;
    
    static constexpr int DEFAULT_MAX_RECORDS = 200;
};

}  // namespace training_sync
