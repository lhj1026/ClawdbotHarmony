/**
 * sampling_strategy.h — 多级采集策略 C++ 实现
 *
 * 根据运动状态动态调整传感器采集频率
 * 实现功耗优化
 */
#pragma once

#include <string>
#include <cstdint>
#include "motion_detector.h"

namespace sampling_strategy {

// ============================================================
// 采集配置
// ============================================================

/** 单个传感器的采集间隔配置 */
struct SensorIntervals {
    int64_t gpsIntervalMs;      // GPS采集间隔 (毫秒)
    int64_t wifiIntervalMs;     // WiFi扫描间隔 (毫秒)
    int64_t accelIntervalNs;    // 加速度计间隔 (纳秒)
};

/** 默认配置 */
struct DefaultConfig {
    // 静止状态
    SensorIntervals stationary = {
        5 * 60 * 1000,      // GPS: 5分钟
        5 * 60 * 1000,      // WiFi: 5分钟
        5 * 1000000000LL    // 加速度计: 5秒
    };
    
    // 步行状态
    SensorIntervals walking = {
        30 * 1000,          // GPS: 30秒
        2 * 60 * 1000,      // WiFi: 2分钟
        1 * 1000000000LL    // 加速度计: 1秒
    };
    
    // 跑步状态
    SensorIntervals running = {
        15 * 1000,          // GPS: 15秒
        5 * 60 * 1000,      // WiFi: 5分钟
        500 * 1000000LL     // 加速度计: 500ms
    };
    
    // 驾驶状态
    SensorIntervals driving = {
        5 * 1000,           // GPS: 5秒
        0,                  // WiFi: 关闭
        2 * 1000000000LL    // 加速度计: 2秒
    };
    
    // 未知状态
    SensorIntervals unknown = {
        60 * 1000,          // GPS: 1分钟
        2 * 60 * 1000,      // WiFi: 2分钟
        1 * 1000000000LL    // 加速度计: 1秒
    };
};

// ============================================================
// 策略类
// ============================================================

class SamplingStrategy {
public:
    SamplingStrategy() : config_(), currentIntervals_() {}
    
    /**
     * 根据运动状态获取采集间隔
     */
    SensorIntervals getIntervalsForState(motion_detector::MotionState state) const {
        switch (state) {
            case motion_detector::MotionState::STATIONARY:
                return config_.stationary;
            case motion_detector::MotionState::WALKING:
                return config_.walking;
            case motion_detector::MotionState::RUNNING:
                return config_.running;
            case motion_detector::MotionState::DRIVING:
                return config_.driving;
            default:
                return config_.unknown;
        }
    }
    
    /**
     * 更新当前采集间隔
     * @return 是否有变化
     */
    bool updateForState(motion_detector::MotionState state) {
        SensorIntervals newIntervals = getIntervalsForState(state);
        
        bool changed = (newIntervals.gpsIntervalMs != currentIntervals_.gpsIntervalMs ||
                       newIntervals.wifiIntervalMs != currentIntervals_.wifiIntervalMs ||
                       newIntervals.accelIntervalNs != currentIntervals_.accelIntervalNs);
        
        if (changed) {
            currentIntervals_ = newIntervals;
        }
        
        return changed;
    }
    
    const SensorIntervals& getCurrentIntervals() const {
        return currentIntervals_;
    }
    
    const DefaultConfig& getConfig() const { return config_; }
    void setConfig(const DefaultConfig& config) { config_ = config; }

private:
    DefaultConfig config_;
    SensorIntervals currentIntervals_;
};

}  // namespace sampling_strategy
