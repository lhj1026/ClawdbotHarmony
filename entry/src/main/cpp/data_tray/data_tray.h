/**
 * data_tray.h — 传感器数据托盘 C++ 实现
 *
 * 感知层和决策层之间的缓存中间层。
 * 传感器异步写入 (put)，引擎同步读取 (get/getSnapshot)。
 * 每个槽位携带 TTL，过期数据 quality 线性衰减。
 */
#pragma once

#include <string>
#include <unordered_map>
#include <chrono>
#include <mutex>
#include <optional>
#include <cstdint>

namespace data_tray {

// ============================================================
// Data types
// ============================================================

/** 托盘槽位 */
struct TraySlot {
    std::string key;
    std::string value;
    int64_t updatedAt;    // steady_clock ms
    int64_t ttlMs;
    double quality;       // 0~1
    std::string source;
};

/** 读取结果（含 TTL 衰减后的有效 quality） */
struct TrayReadResult {
    std::optional<std::string> value;
    double quality;       // effective quality after TTL decay
    bool fresh;           // age < ttl
    int64_t ageMs;        // how old the data is
};

/** 调试用状态信息 */
struct TrayStatus {
    std::string key;
    std::string value;
    int64_t ageMs;
    int64_t ttlMs;
    bool fresh;
    double effectiveQuality;
    std::string source;
};

/** 上下文快照 */
struct ContextSnapshot {
    std::string timeOfDay;
    std::string hour;
    std::string dayOfWeek;
    std::string isWeekend;
    std::string motionState;
    std::string batteryLevel;
    std::string isCharging;
    std::string networkType;
    std::optional<std::string> geofence;
    std::optional<std::string> wifiSsid;
    std::optional<std::string> wifiLostWork;
    std::optional<std::string> cellId;
    std::optional<std::string> latitude;
    std::optional<std::string> longitude;
    std::optional<std::string> stepCount;
};

// ============================================================
// 默认 TTL 配置
// ============================================================

/** 默认 TTL 配置（毫秒） */
inline int64_t getDefaultTTL(const std::string& key) {
    static const std::unordered_map<std::string, int64_t> defaultTTL = {
        // 时间类 — 实时计算，永远新鲜
        {"hour", 0x7FFFFFFF},
        {"timeOfDay", 0x7FFFFFFF},
        {"dayOfWeek", 0x7FFFFFFF},
        {"isWeekend", 0x7FFFFFFF},

        // 设备状态
        {"batteryLevel", 5 * 60 * 1000},    // 5 min
        {"isCharging", 5 * 60 * 1000},      // 5 min

        // 网络
        {"networkType", 2 * 60 * 1000},     // 2 min
        {"wifiSsid", 2 * 60 * 1000},        // 2 min

        // 运动
        {"motionState", 30 * 1000},         // 30 sec
        {"stepCount", 30 * 1000},           // 30 sec

        // 位置
        {"latitude", 2 * 60 * 1000},        // 2 min
        {"longitude", 2 * 60 * 1000},       // 2 min
        {"geofence", 5 * 60 * 1000},        // 5 min
        {"cellId", 10 * 60 * 1000},         // 10 min - 基站变化较慢

        // 环境
        {"heartRate", 60 * 1000},           // 1 min
        {"ambientLight", 30 * 1000},        // 30 sec
        {"noiseLevel", 30 * 1000},          // 30 sec
    };

    auto it = defaultTTL.find(key);
    if (it != defaultTTL.end()) {
        return it->second;
    }
    return 2 * 60 * 1000;  // FALLBACK: 2 min
}

// ============================================================
// SensorDataTray 主类
// ============================================================

class SensorDataTray {
public:
    static SensorDataTray& getInstance() {
        static SensorDataTray instance;
        return instance;
    }

    /**
     * 传感器写入数据
     * @param key      传感器标识
     * @param value    最新值（字符串）
     * @param quality  数据质量 0~1，默认 1.0
     * @param source   来源标识，默认与 key 相同
     */
    void put(const std::string& key, const std::string& value,
             double quality = 1.0, const std::string& source = "") {
        std::lock_guard<std::mutex> lock(mu_);
        
        int64_t ttl = getTTL(key);
        TraySlot slot{
            key,
            value,
            nowMs(),
            ttl,
            quality,
            source.empty() ? key : source
        };
        slots_[key] = slot;
    }

    /**
     * 引擎读取数据（含 TTL 衰减）
     */
    TrayReadResult get(const std::string& key) {
        std::lock_guard<std::mutex> lock(mu_);
        
        auto it = slots_.find(key);
        if (it == slots_.end()) {
            return {std::nullopt, 0.5, false, 0};
        }

        const TraySlot& slot = it->second;
        int64_t age = nowMs() - slot.updatedAt;
        int64_t ttl = slot.ttlMs;

        // 新鲜
        if (age < ttl) {
            return {slot.value, slot.quality, true, age};
        }

        // 过期但未超过 2x TTL — quality 线性衰减
        double decay = 1.0 - static_cast<double>(age - ttl) / static_cast<double>(ttl);
        if (decay < 0) decay = 0;
        double effectiveQuality = slot.quality * decay;

        return {slot.value, effectiveQuality, false, age};
    }

    /**
     * 从所有槽位构建 ContextSnapshot
     */
    ContextSnapshot getSnapshot() {
        std::lock_guard<std::mutex> lock(mu_);
        
        ContextSnapshot snap;
        snap.timeOfDay = getValueOrDefault("timeOfDay", "unknown");
        snap.hour = getValueOrDefault("hour", "0");
        snap.dayOfWeek = getValueOrDefault("dayOfWeek", "0");
        snap.isWeekend = getValueOrDefault("isWeekend", "false");
        snap.motionState = getValueOrDefault("motionState", "unknown");
        snap.batteryLevel = getValueOrDefault("batteryLevel", "100");
        snap.isCharging = getValueOrDefault("isCharging", "false");
        snap.networkType = getValueOrDefault("networkType", "none");

        // Optional fields
        auto geofence = getUnlocked("geofence");
        if (geofence.value.has_value()) {
            snap.geofence = geofence.value;
        }
        auto wifiSsid = getUnlocked("wifiSsid");
        if (wifiSsid.value.has_value()) {
            snap.wifiSsid = wifiSsid.value;
        }
        auto wifiLostWork = getUnlocked("wifiLostWork");
        if (wifiLostWork.value.has_value()) {
            snap.wifiLostWork = wifiLostWork.value;
        }
        auto cellId = getUnlocked("cellId");
        if (cellId.value.has_value()) {
            snap.cellId = cellId.value;
        }
        auto lat = getUnlocked("latitude");
        if (lat.value.has_value()) {
            snap.latitude = lat.value;
        }
        auto lon = getUnlocked("longitude");
        if (lon.value.has_value()) {
            snap.longitude = lon.value;
        }
        auto steps = getUnlocked("stepCount");
        if (steps.value.has_value()) {
            snap.stepCount = steps.value;
        }

        return snap;
    }

    /**
     * 配置单个 key 的 TTL
     */
    void setTTL(const std::string& key, int64_t ttlMs) {
        std::lock_guard<std::mutex> lock(mu_);
        
        ttlOverrides_[key] = ttlMs;
        // 更新已有槽位
        auto it = slots_.find(key);
        if (it != slots_.end()) {
            it->second.ttlMs = ttlMs;
        }
    }

    /**
     * 获取所有槽位的调试状态
     */
    std::vector<TrayStatus> getStatus() {
        std::lock_guard<std::mutex> lock(mu_);
        
        int64_t now = nowMs();
        std::vector<TrayStatus> result;
        result.reserve(slots_.size());
        
        for (const auto& [key, slot] : slots_) {
            int64_t age = now - slot.updatedAt;
            bool fresh = age < slot.ttlMs;
            double decay = fresh ? 1.0 : std::max(0.0, 1.0 - static_cast<double>(age - slot.ttlMs) / static_cast<double>(slot.ttlMs));
            double eq = slot.quality * decay;
            
            result.push_back({
                slot.key,
                slot.value,
                age,
                slot.ttlMs,
                fresh,
                eq,
                slot.source
            });
        }
        return result;
    }

    /**
     * 清除所有数据（测试用）
     */
    void clear() {
        std::lock_guard<std::mutex> lock(mu_);
        slots_.clear();
    }

    /**
     * 获取槽位数量
     */
    size_t size() const {
        std::lock_guard<std::mutex> lock(mu_);
        return slots_.size();
    }

private:
    SensorDataTray() = default;
    SensorDataTray(const SensorDataTray&) = delete;
    SensorDataTray& operator=(const SensorDataTray&) = delete;

    int64_t nowMs() const {
        auto now = std::chrono::steady_clock::now();
        return std::chrono::duration_cast<std::chrono::milliseconds>(
            now.time_since_epoch()).count();
    }

    std::string getValueOrDefault(const std::string& key, const std::string& defaultValue) {
        auto result = getUnlocked(key);
        return result.value.has_value() ? result.value.value() : defaultValue;
    }

    // 不加锁版本，内部使用
    TrayReadResult getUnlocked(const std::string& key) {
        auto it = slots_.find(key);
        if (it == slots_.end()) {
            return {std::nullopt, 0.5, false, 0};
        }

        const TraySlot& slot = it->second;
        int64_t age = nowMs() - slot.updatedAt;
        int64_t ttl = slot.ttlMs;

        if (age < ttl) {
            return {slot.value, slot.quality, true, age};
        }

        double decay = 1.0 - static_cast<double>(age - ttl) / static_cast<double>(ttl);
        if (decay < 0) decay = 0;
        double effectiveQuality = slot.quality * decay;

        return {slot.value, effectiveQuality, false, age};
    }

    int64_t getTTL(const std::string& key) {
        // 优先用用户覆盖
        auto overrideIt = ttlOverrides_.find(key);
        if (overrideIt != ttlOverrides_.end()) {
            return overrideIt->second;
        }
        return getDefaultTTL(key);
    }

    std::unordered_map<std::string, TraySlot> slots_;
    std::unordered_map<std::string, int64_t> ttlOverrides_;
    mutable std::mutex mu_;
};

}  // namespace data_tray
