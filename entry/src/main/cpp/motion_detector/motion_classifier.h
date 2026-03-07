/**
 * motion_classifier.h — 增强的运动状态分类器
 *
 * 基于 Z 轴特征和地理围栏进行高精度运动状态分类
 * 功能：
 *   - Z 轴频率/幅度特征计算（走路 vs 驾车）
 *   - 地点推断（驾驶 vs 乘车）
 *   - 综合决策
 */
#pragma once

#include <string>
#include <cmath>
#include <vector>
#include <deque>
#include <algorithm>
#include <cstring>

namespace motion_detector {

// ============================================================
// 增强的运动状态枚举（包含 transit）
// ============================================================

enum class EnhancedMotionState {
    UNKNOWN = 0,
    STATIONARY = 1,
    WALKING = 2,
    RUNNING = 3,
    CYCLING = 4,
    DRIVING = 5,
    TRANSIT = 6,      // 新增：乘车（公交/地铁）
    PICKUP = 7,
    PUTDOWN = 8
};

// ============================================================
// Z 轴特征数据
// ============================================================

struct ZAxisSample {
    double value;
    int64_t timestamp;
};

struct ZAxisFeatures {
    double amplitude;     // 振幅 (g)
    double frequency;     // 频率 (Hz)
    double variance;      // 方差
    bool isValid;         // 数据是否有效
};

// ============================================================
// 地点推断数据
// ============================================================

struct TransitInferenceContext {
    std::string prevGeofence;      // 前一个围栏ID
    std::string currentGeofence;   // 当前围栏ID
    int64_t geofenceDepartureTime; // 离开围栏时间戳
    double gpsSpeed;               // GPS速度 (m/s)
};

// ============================================================
// Z 轴特征提取器
// ============================================================

class ZAxisFeatureExtractor {
public:
    static const int HISTORY_SIZE = 1000;      // 5秒@200Hz
    static const int MIN_SAMPLES = 50;         // 最少采样数
    
    ZAxisFeatureExtractor() : samples_() {
    }
    
    /**
     * 添加 Z 轴样本
     */
    void addSample(double z, int64_t timestamp) {
        samples_.push_back({z, timestamp});
        if (static_cast<int>(samples_.size()) > HISTORY_SIZE) {
            samples_.erase(samples_.begin());
        }
    }
    
    /**
     * 计算 Z 轴特征
     */
    ZAxisFeatures computeFeatures() {
        ZAxisFeatures features;
        features.isValid = false;
        
        if (static_cast<int>(samples_.size()) < MIN_SAMPLES) {
            return features;
        }
        
        // 取最近 2.5 秒的数据
        int64_t now = samples_.back().timestamp;
        int64_t cutoff = now - 2500;  // 2500ms
        
        std::vector<double> recentValues;
        for (const auto& sample : samples_) {
            if (sample.timestamp >= cutoff) {
                recentValues.push_back(sample.value);
            }
        }
        
        if (recentValues.size() < 10) {
            return features;
        }
        
        // 计算振幅
        double maxVal = *std::max_element(recentValues.begin(), recentValues.end());
        double minVal = *std::min_element(recentValues.begin(), recentValues.end());
        features.amplitude = (maxVal - minVal) / 9.8;
        
        // 计算方差
        double sum = 0;
        for (double v : recentValues) {
            sum += v;
        }
        double mean = sum / recentValues.size();
        
        double varianceSum = 0;
        for (double v : recentValues) {
            double diff = v - mean;
            varianceSum += diff * diff;
        }
        features.variance = varianceSum / recentValues.size();
        
        // 计算频率（自相关）
        features.frequency = estimateFrequency(recentValues);
        
        features.isValid = true;
        return features;
    }
    
    /**
     * 根据 Z 轴特征分类运动状态
     */
    static EnhancedMotionState classifyByZAxis(const ZAxisFeatures& features) {
        if (!features.isValid) {
            return EnhancedMotionState::UNKNOWN;
        }
        
        // 静止：极小幅度
        if (features.amplitude < 0.2) {
            return EnhancedMotionState::STATIONARY;
        }
        
        // 走路特征：高频 + 大幅度
        if (features.frequency >= 1.2 && features.frequency <= 2.5 && 
            features.amplitude >= 0.35) {
            return EnhancedMotionState::WALKING;
        }
        
        // 驾车特征：低频 + 中等幅度
        if (features.amplitude >= 0.15 && features.amplitude < 0.35) {
            if (features.frequency < 0.8 || features.frequency == 0) {
                return EnhancedMotionState::DRIVING;
            }
        }
        
        // 高幅度低频 → 驾车（颠簸）
        if (features.amplitude >= 0.4 && features.frequency < 1.0) {
            return EnhancedMotionState::DRIVING;
        }
        
        return EnhancedMotionState::UNKNOWN;
    }
    
    void clear() {
        samples_.clear();
    }
    
private:
    /**
     * 自相关频率估计
     * 返回频率(Hz)，无规律时返回0
     */
    static double estimateFrequency(const std::vector<double>& values) {
        if (values.size() < 50) {
            return 0;
        }
        
        // 中心化
        double sum = 0;
        for (double v : values) {
            sum += v;
        }
        double mean = sum / values.size();
        
        std::vector<double> centered;
        centered.reserve(values.size());
        for (double v : values) {
            centered.push_back(v - mean);
        }
        
        // 自相关寻找第一个负峰
        int bestLag = 0;
        double bestCorr = 0;
        
        for (int lag = 10; lag < static_cast<int>(values.size()) / 2; lag++) {
            double corr = 0;
            for (size_t i = 0; i + lag < centered.size(); i++) {
                corr += centered[i] * centered[i + lag];
            }
            
            // 第一个明显的负值表示一个半周期
            if (corr < -0.1 * static_cast<int>(centered.size()) && bestLag == 0) {
                bestLag = lag * 2;  // 乘以2得到完整周期
                bestCorr = corr;
                break;
            }
        }
        
        if (bestLag == 0) {
            return 0;  // 无规律
        }
        
        // 采样间隔假设为 5ms (200Hz)
        double dtMs = 5.0;
        double frequency = (1000.0 / dtMs) / bestLag;
        
        // 限制在合理范围
        return std::min(frequency, 50.0);
    }
    
    std::deque<ZAxisSample> samples_;
};

// ============================================================
// 地点推断引擎
// ============================================================

class TransitInference {
public:
    static const int DEPARTURE_WINDOW_MS = 5 * 60 * 1000;  // 5分钟
    
    /**
     * 判断地点是否是交通枢纽
     */
    static bool isTransitHub(const std::string& geofenceId) {
        if (geofenceId.empty()) {
            return false;
        }
        
        // 转换为小写进行比较
        std::string lower = geofenceId;
        std::transform(lower.begin(), lower.end(), lower.begin(),
                      [](unsigned char c) { return std::tolower(c); });
        
        return lower.find("transit") != std::string::npos ||
               lower.find("station") != std::string::npos ||
               lower.find("metro") != std::string::npos ||
               lower.find("subway") != std::string::npos ||
               lower.find("bus") != std::string::npos ||
               lower.find("airport") != std::string::npos ||
               lower.find("railway") != std::string::npos ||
               lower.find("train") != std::string::npos ||
               lower.find("ferry") != std::string::npos;
    }
    
    /**
     * 推断驾驶 vs 乘车
     * @param detectedMotion 检测到的运动状态
     * @param context 地点和时间上下文
     * @return 修正后的运动状态
     */
    static EnhancedMotionState inferDrivingVsTransit(
        EnhancedMotionState detectedMotion,
        const TransitInferenceContext& context) {
        
        // 只处理驾驶状态
        if (detectedMotion != EnhancedMotionState::DRIVING) {
            return detectedMotion;
        }
        
        // 检查前一个围栏是否是交通枢纽
        if (!context.prevGeofence.empty() && isTransitHub(context.prevGeofence)) {
            // 检查是否在窗口期内
            int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
            
            bool currentIsTransitHub = !context.currentGeofence.empty() && 
                                     isTransitHub(context.currentGeofence);
            bool inDepartureWindow = (now - context.geofenceDepartureTime) < DEPARTURE_WINDOW_MS;
            
            // 如果当前还在枢纽内或刚离开 → 推断为乘车
            if (currentIsTransitHub || inDepartureWindow) {
                return EnhancedMotionState::TRANSIT;
            }
        }
        
        return detectedMotion;
    }
};

// ============================================================
// 运动状态字符串转换
// ============================================================

inline std::string enhancedStateToString(EnhancedMotionState state) {
    switch (state) {
        case EnhancedMotionState::STATIONARY: return "stationary";
        case EnhancedMotionState::WALKING: return "walking";
        case EnhancedMotionState::RUNNING: return "running";
        case EnhancedMotionState::CYCLING: return "cycling";
        case EnhancedMotionState::DRIVING: return "driving";
        case EnhancedMotionState::TRANSIT: return "transit";
        case EnhancedMotionState::PICKUP: return "pickup";
        case EnhancedMotionState::PUTDOWN: return "putdown";
        default: return "unknown";
    }
}

inline EnhancedMotionState stringToEnhancedState(const std::string& str) {
    if (str == "stationary") return EnhancedMotionState::STATIONARY;
    if (str == "walking") return EnhancedMotionState::WALKING;
    if (str == "running") return EnhancedMotionState::RUNNING;
    if (str == "cycling") return EnhancedMotionState::CYCLING;
    if (str == "driving") return EnhancedMotionState::DRIVING;
    if (str == "transit") return EnhancedMotionState::TRANSIT;
    if (str == "pickup") return EnhancedMotionState::PICKUP;
    if (str == "putdown") return EnhancedMotionState::PUTDOWN;
    return EnhancedMotionState::UNKNOWN;
}

}  // namespace motion_detector
