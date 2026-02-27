/**
 * sleep_pattern.h — 睡眠时间学习 C++ 实现
 *
 * 根据用户运动数据推断睡眠时间
 * 结合穿戴设备数据（如果有）进行精确判断
 */
#pragma once

#include <string>
#include <vector>
#include <map>
#include <cmath>
#include <cstdint>

namespace sleep_pattern {

// ============================================================
// 数据类型
// ============================================================

/** 单日睡眠模式 */
struct SleepDayPattern {
    double bedtime;       // 入睡时间 (小时 0-23.99)
    double wakeTime;      // 起床时间 (小时 0-23.99)
    int sampleCount;      // 样本数量
};

/** 睡眠模式 */
struct SleepPattern {
    double typicalBedtime;      // 典型入睡时间
    double typicalWakeTime;     // 典型起床时间
    double sleepDurationHours;  // 平均睡眠时长
    SleepDayPattern weekdays;   // 工作日
    SleepDayPattern weekends;   // 周末
    int64_t lastUpdated;
    double confidence;          // 置信度 0-1
};

/** 单次睡眠记录 */
struct SleepRecord {
    std::string date;           // "YYYY-MM-DD"
    int64_t bedtime;            // 入睡时间戳
    int64_t wakeTime;           // 起床时间戳
    int64_t durationMs;
    std::string source;         // "wearable", "inferred", "manual"
};

/** 运动状态快照 */
struct MotionSnapshot {
    std::string state;          // stationary, walking, etc.
    int64_t timestamp;
    double latitude;
    double longitude;
    std::string geofence;
};

// ============================================================
// 睡眠学习器
// ============================================================

class SleepPatternLearner {
public:
    SleepPatternLearner() : pattern_(), records_(), motionHistory_() {
        pattern_.confidence = 0;
        pattern_.lastUpdated = 0;
    }
    
    /**
     * 记录运动状态变化
     * 用于推断睡眠时间
     */
    void recordMotionChange(const MotionSnapshot& snapshot) {
        motionHistory_.push_back(snapshot);
        
        // 保持最近24小时的历史
        int64_t cutoff = snapshot.timestamp - 24 * 60 * 60 * 1000;
        while (motionHistory_.size() > 2 && motionHistory_.front().timestamp < cutoff) {
            motionHistory_.erase(motionHistory_.begin());
        }
        
        // 检测睡眠
        detectSleep();
    }
    
    /**
     * 从穿戴设备记录睡眠
     */
    void recordFromWearable(const SleepRecord& record) {
        records_.push_back(record);
        updatePattern();
    }
    
    /**
     * 获取睡眠模式
     */
    const SleepPattern& getPattern() const {
        return pattern_;
    }
    
    /**
     * 获取推荐的睡前提醒时间
     * @return 小时 (0-23.99)
     */
    double getRecommendedBedtimeReminder() const {
        if (pattern_.confidence < 0.3) {
            // 置信度太低，使用默认 22:00
            return 22.0;
        }
        // 提前1小时提醒
        double reminder = pattern_.typicalBedtime - 1.0;
        if (reminder < 0) reminder += 24;
        return reminder;
    }
    
    /**
     * 判断当前是否接近睡眠时间
     */
    bool isNearBedtime(int currentHour, int currentMinute, int marginMinutes = 30) const {
        double current = currentHour + currentMinute / 60.0;
        double bedtime = pattern_.confidence >= 0.3 ? pattern_.typicalBedtime : 22.0;
        
        double diff = std::abs(current - bedtime);
        if (diff > 12) diff = 24 - diff;  // 处理跨午夜情况
        
        return diff * 60 <= marginMinutes;
    }
    
    /**
     * 清除所有记录
     */
    void clear() {
        records_.clear();
        motionHistory_.clear();
        pattern_.confidence = 0;
    }

private:
    SleepPattern pattern_;
    std::vector<SleepRecord> records_;
    std::vector<MotionSnapshot> motionHistory_;
    
    /**
     * 从运动历史推断睡眠
     */
    void detectSleep() {
        if (motionHistory_.size() < 10) return;
        
        // 寻找长时间静止的时段（可能是睡眠）
        int64_t stationaryStart = 0;
        int64_t stationaryEnd = 0;
        bool inStationary = false;
        
        for (size_t i = 0; i < motionHistory_.size(); i++) {
            const auto& snap = motionHistory_[i];
            
            if (snap.state == "stationary") {
                if (!inStationary) {
                    stationaryStart = snap.timestamp;
                    inStationary = true;
                }
                stationaryEnd = snap.timestamp;
            } else {
                if (inStationary) {
                    // 检查静止时长
                    int64_t duration = stationaryEnd - stationaryStart;
                    if (duration > 4 * 60 * 60 * 1000) {  // > 4小时
                        // 可能是睡眠
                        addInferredSleep(stationaryStart, stationaryEnd);
                    }
                    inStationary = false;
                }
            }
        }
    }
    
    /**
     * 添加推断的睡眠记录
     */
    void addInferredSleep(int64_t start, int64_t end) {
        SleepRecord record;
        record.bedtime = start;
        record.wakeTime = end;
        record.durationMs = end - start;
        record.source = "inferred";
        
        // 从时间戳提取日期
        // 简化处理，实际需要正确的时间转换
        record.date = "inferred";
        
        records_.push_back(record);
        updatePattern();
    }
    
    /**
     * 更新睡眠模式
     */
    void updatePattern() {
        if (records_.empty()) return;
        
        // 计算平均睡眠时间
        double bedtimeSum = 0;
        double wakeTimeSum = 0;
        double durationSum = 0;
        int count = 0;
        
        for (const auto& rec : records_) {
            if (rec.bedtime > 0 && rec.wakeTime > 0) {
                // 从时间戳提取小时
                double bedtimeHour = (rec.bedtime / (1000 * 60 * 60)) % 24;
                double wakeHour = (rec.wakeTime / (1000 * 60 * 60)) % 24;
                
                bedtimeSum += bedtimeHour;
                wakeTimeSum += wakeHour;
                durationSum += rec.durationMs / (1000.0 * 60 * 60);
                count++;
            }
        }
        
        if (count > 0) {
            pattern_.typicalBedtime = bedtimeSum / count;
            pattern_.typicalWakeTime = wakeTimeSum / count;
            pattern_.sleepDurationHours = durationSum / count;
            pattern_.confidence = std::min(1.0, count / 7.0);  // 7天数据达到100%置信度
            pattern_.lastUpdated = currentTimeMs();
        }
    }
    
    int64_t currentTimeMs() const {
        return 0;  // 实际实现需要平台特定代码
    }
};

}  // namespace sleep_pattern
