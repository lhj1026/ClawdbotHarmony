/**
 * feedback_learner.h — 用户反馈学习 C++ 实现
 *
 * 记录用户对推荐的反馈，包括：
 * - 反馈时的上下文（时间、地点、WiFi、场景等）
 * - 用户评价（有用/不准/忽略）
 * - 用户调整值（如希望的提醒时间）
 *
 * 用于优化规则参数
 */
#pragma once

#include <string>
#include <vector>
#include <map>
#include <cstdint>

namespace feedback_learner {

// ============================================================
// 数据类型
// ============================================================

/** 反馈类型 */
enum class FeedbackType {
    USEFUL = 0,        // 有用
    INACCURATE = 1,    // 不准
    DISMISS = 2,       // 忽略
    ADJUST = 3         // 调整（用户提供了调整值）
};

/** 反馈上下文 */
struct FeedbackContext {
    std::string ruleId;          // 规则ID
    std::string ruleName;        // 规则名称
    
    // 时间上下文
    int64_t feedbackTime;        // 反馈时间戳
    int hour;                    // 小时 (0-23)
    int minute;                  // 分钟 (0-59)
    std::string timeOfDay;       // morning/afternoon/evening/night
    bool isWeekend;              // 是否周末
    
    // 地点上下文
    double latitude;
    double longitude;
    std::string geofence;        // 当前围栏
    std::string wifiSsid;        // 当前WiFi
    
    // 场景上下文
    std::string motionState;     // stationary/walking/running/driving
    std::string activityContext; // 活动上下文描述
    
    // 其他
    std::string payload;         // 原始推荐内容
};

/** 用户调整值 */
struct AdjustmentValue {
    std::string key;             // 调整的参数名 (如 "hour", "minute")
    double originalValue;        // 原始值
    double adjustedValue;        // 调整后的值
    std::string unit;            // 单位 (如 "hour", "minute")
};

/** 完整的反馈记录 */
struct FeedbackRecord {
    std::string id;              // 记录ID
    FeedbackType type;           // 反馈类型
    FeedbackContext context;     // 上下文
    AdjustmentValue adjustment;  // 用户调整值（如果有）
    int64_t timestamp;           // 时间戳
};

/** 规则偏好（学习结果） */
struct RulePreference {
    std::string ruleId;
    
    // 时间偏好
    double preferredHour;        // 偏好的小时
    double preferredMinute;      // 偏好的分钟
    double hourAdjustment;       // 小时调整量
    double confidence;           // 置信度
    
    // 统计
    int usefulCount;             // 有用次数
    int inaccurateCount;         // 不准次数
    int dismissCount;            // 忽略次数
    int adjustCount;             // 调整次数
    
    // 最近反馈
    int64_t lastFeedbackTime;
    
    RulePreference() : preferredHour(-1), preferredMinute(-1), 
                       hourAdjustment(0), confidence(0),
                       usefulCount(0), inaccurateCount(0), 
                       dismissCount(0), adjustCount(0), lastFeedbackTime(0) {}
};

// ============================================================
// 反馈学习器
// ============================================================

class FeedbackLearner {
public:
    FeedbackLearner() {}
    
    /**
     * 记录用户反馈
     */
    void recordFeedback(const FeedbackRecord& record) {
        records_.push_back(record);
        updatePreference(record);
    }
    
    /**
     * 记录简单反馈（有用/不准/忽略）
     */
    void recordSimpleFeedback(const std::string& ruleId, FeedbackType type, 
                               const FeedbackContext& context) {
        FeedbackRecord record;
        record.id = generateId();
        record.type = type;
        record.context = context;
        record.timestamp = currentTimeMs();
        record.context.ruleId = ruleId;
        
        recordFeedback(record);
    }
    
    /**
     * 记录带调整的反馈
     */
    void recordAdjustment(const std::string& ruleId, const FeedbackContext& context,
                          const AdjustmentValue& adjustment) {
        FeedbackRecord record;
        record.id = generateId();
        record.type = FeedbackType::ADJUST;
        record.context = context;
        record.adjustment = adjustment;
        record.timestamp = currentTimeMs();
        record.context.ruleId = ruleId;
        
        recordFeedback(record);
    }
    
    /**
     * 获取规则偏好
     */
    const RulePreference* getPreference(const std::string& ruleId) const {
        auto it = preferences_.find(ruleId);
        return it != preferences_.end() ? &it->second : nullptr;
    }
    
    /**
     * 获取调整后的推荐时间
     * @return 小时 (0-23.99)，如果没有调整返回原始值
     */
    double getAdjustedHour(const std::string& ruleId, double originalHour) const {
        auto pref = getPreference(ruleId);
        if (pref && pref->confidence > 0.5) {
            return pref->preferredHour;
        }
        return originalHour;
    }
    
    /**
     * 获取所有偏好
     */
    const std::map<std::string, RulePreference>& getAllPreferences() const {
        return preferences_;
    }
    
    /**
     * 清除规则偏好
     */
    void clearPreference(const std::string& ruleId) {
        preferences_.erase(ruleId);
    }
    
    /**
     * 导出偏好为JSON
     */
    std::string exportPreferences() const {
        std::string result = "{";
        bool first = true;
        for (const auto& [id, pref] : preferences_) {
            if (!first) result += ",";
            first = false;
            result += "\"" + id + "\":{";
            result += "\"preferredHour\":" + std::to_string(pref.preferredHour) + ",";
            result += "\"preferredMinute\":" + std::to_string(pref.preferredMinute) + ",";
            result += "\"hourAdjustment\":" + std::to_string(pref.hourAdjustment) + ",";
            result += "\"confidence\":" + std::to_string(pref.confidence) + ",";
            result += "\"usefulCount\":" + std::to_string(pref.usefulCount) + ",";
            result += "\"inaccurateCount\":" + std::to_string(pref.inaccurateCount);
            result += "}";
        }
        result += "}";
        return result;
    }

private:
    std::vector<FeedbackRecord> records_;
    std::map<std::string, RulePreference> preferences_;
    
    void updatePreference(const FeedbackRecord& record) {
        const std::string& ruleId = record.context.ruleId;
        RulePreference& pref = preferences_[ruleId];
        pref.ruleId = ruleId;
        
        switch (record.type) {
            case FeedbackType::USEFUL:
                pref.usefulCount++;
                break;
            case FeedbackType::INACCURATE:
                pref.inaccurateCount++;
                break;
            case FeedbackType::DISMISS:
                pref.dismissCount++;
                break;
            case FeedbackType::ADJUST:
                pref.adjustCount++;
                // 应用调整
                if (record.adjustment.key == "hour") {
                    pref.preferredHour = record.adjustment.adjustedValue;
                    pref.hourAdjustment = record.adjustment.adjustedValue - record.adjustment.originalValue;
                } else if (record.adjustment.key == "minute") {
                    pref.preferredMinute = record.adjustment.adjustedValue;
                }
                break;
        }
        
        pref.lastFeedbackTime = record.timestamp;
        
        // 更新置信度
        int total = pref.usefulCount + pref.inaccurateCount + pref.adjustCount;
        if (total > 0) {
            pref.confidence = std::min(1.0, total / 5.0);  // 5次反馈达到100%
        }
    }
    
    std::string generateId() const {
        return "fb_" + std::to_string(currentTimeMs());
    }
    
    int64_t currentTimeMs() const {
        return 0;  // 实际实现需要平台特定代码
    }
};

}  // namespace feedback_learner
