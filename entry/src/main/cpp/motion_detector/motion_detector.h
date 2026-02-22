/**
 * motion_detector.h — 运动状态检测 C++ 实现
 *
 * 基于加速度计和GPS速度检测运动状态
 * 支持检测：静止、步行、跑步、驾驶
 */
#pragma once

#include <string>
#include <cmath>
#include <vector>

namespace motion_detector {

// ============================================================
// 数据类型
// ============================================================

/** 运动状态 */
enum class MotionState {
    UNKNOWN = 0,
    STATIONARY = 1,  // 静止
    WALKING = 2,      // 步行
    RUNNING = 3,      // 跑步
    DRIVING = 4       // 驾驶
};

/** 加速度数据 */
struct AccelerometerData {
    double x;
    double y;
    double z;
    int64_t timestamp;
};

/** 运动检测结果 */
struct MotionResult {
    MotionState state;
    double magnitude;      // 加速度幅度
    double gpsSpeed;       // GPS速度 (m/s)
    double confidence;     // 置信度 0-1
    bool stateChanged;
};

/** 配置参数 */
struct MotionConfig {
    // 加速度阈值
    double stationaryThreshold = 10.5;    // < 此值为静止
    double walkingThreshold = 12.0;       // < 此值为步行
    double runningThreshold = 15.0;       // < 此值为跑步
    
    // GPS速度阈值 (m/s)
    double drivingSpeedThreshold = 5.0;   // > 此值为驾驶
    double highSpeedThreshold = 20.0;     // > 此值为高速驾驶
    
    // 历史窗口大小
    int historySize = 5;
};

// ============================================================
// 检测器类
// ============================================================

class MotionDetector {
public:
    MotionDetector() : lastState_(MotionState::UNKNOWN), config_() {}
    
    explicit MotionDetector(const MotionConfig& config) 
        : lastState_(MotionState::UNKNOWN), config_(config) {}
    
    /**
     * 检测运动状态
     * @param accel 加速度数据
     * @param gpsSpeed GPS速度 (m/s)，如果没有传-1
     * @return 检测结果
     */
    MotionResult detect(const AccelerometerData& accel, double gpsSpeed) {
        MotionResult result;
        result.gpsSpeed = gpsSpeed;
        
        // 计算加速度幅度
        result.magnitude = std::sqrt(
            accel.x * accel.x + 
            accel.y * accel.y + 
            accel.z * accel.z
        );
        
        // 添加到历史记录
        magnitudeHistory_.push_back(result.magnitude);
        if (static_cast<int>(magnitudeHistory_.size()) > config_.historySize) {
            magnitudeHistory_.erase(magnitudeHistory_.begin());
        }
        
        // 计算平均幅度
        double avgMagnitude = 0;
        if (!magnitudeHistory_.empty()) {
            for (double m : magnitudeHistory_) {
                avgMagnitude += m;
            }
            avgMagnitude /= magnitudeHistory_.size();
        }
        
        // 优先使用GPS速度判断（解决开车/高铁匀速问题）
        if (gpsSpeed >= 0) {
            if (gpsSpeed > config_.highSpeedThreshold) {
                // > 72 km/h: 高铁/高速公路
                result.state = MotionState::DRIVING;
                result.confidence = 0.95;
            } else if (gpsSpeed > config_.drivingSpeedThreshold) {
                // > 18 km/h: 驾驶/骑行
                result.state = MotionState::DRIVING;
                result.confidence = 0.85;
            } else if (gpsSpeed > 1.5) {
                // > 5.4 km/h: 跑步/快走
                result.state = avgMagnitude > config_.walkingThreshold 
                    ? MotionState::RUNNING : MotionState::WALKING;
                result.confidence = 0.75;
            } else {
                // GPS速度慢，用加速度判断
                result.state = detectFromAcceleration(avgMagnitude);
                result.confidence = 0.6;
            }
        } else {
            // 没有GPS速度，纯靠加速度
            result.state = detectFromAcceleration(avgMagnitude);
            result.confidence = 0.5;
        }
        
        // 检查状态变化
        result.stateChanged = (result.state != lastState_);
        if (result.stateChanged) {
            lastState_ = result.state;
        }
        
        return result;
    }
    
    /**
     * 获取运动状态名称
     */
    static std::string stateToString(MotionState state) {
        switch (state) {
            case MotionState::STATIONARY: return "stationary";
            case MotionState::WALKING: return "walking";
            case MotionState::RUNNING: return "running";
            case MotionState::DRIVING: return "driving";
            default: return "unknown";
        }
    }
    
    /**
     * 从字符串解析运动状态
     */
    static MotionState stringToState(const std::string& str) {
        if (str == "stationary") return MotionState::STATIONARY;
        if (str == "walking") return MotionState::WALKING;
        if (str == "running") return MotionState::RUNNING;
        if (str == "driving") return MotionState::DRIVING;
        return MotionState::UNKNOWN;
    }
    
    MotionState getLastState() const { return lastState_; }
    
    void reset() {
        lastState_ = MotionState::UNKNOWN;
        magnitudeHistory_.clear();
    }

private:
    MotionState detectFromAcceleration(double magnitude) {
        if (magnitude < config_.stationaryThreshold) {
            return MotionState::STATIONARY;
        } else if (magnitude < config_.walkingThreshold) {
            return MotionState::WALKING;
        } else if (magnitude < config_.runningThreshold) {
            return MotionState::RUNNING;
        } else {
            return MotionState::DRIVING;
        }
    }
    
    MotionState lastState_;
    MotionConfig config_;
    std::vector<double> magnitudeHistory_;
};

}  // namespace motion_detector
