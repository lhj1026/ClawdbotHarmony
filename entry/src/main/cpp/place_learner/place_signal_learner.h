/**
 * place_signal_learner.h — 地点信号学习 C++ 实现
 *
 * 学习围栏关联的WiFi/蓝牙/时间特征
 */
#pragma once

#include <string>
#include <vector>
#include <map>
#include <set>
#include <cstdint>

namespace place_learner {

// ============================================================
// 数据类型
// ============================================================

/** 时间范围 */
struct TimeRange {
    int startHour;
    int endHour;
};

/** 学习的地点信号 */
struct LearnedSignals {
    std::set<std::string> wifiSSIDs;
    std::set<std::string> bluetoothDevices;
    std::vector<TimeRange> typicalTimes;
    int64_t lastSeen;
    int visitCount;
    
    LearnedSignals() : lastSeen(0), visitCount(0) {}
};

/** 地点信号摘要 (用于快速匹配) */
struct SignalSummary {
    std::vector<std::string> wifiList;
    std::vector<std::string> btList;
    int visitCount;
};

// ============================================================
// 学习器类
// ============================================================

class PlaceSignalLearner {
public:
    PlaceSignalLearner() {}
    
    /**
     * 学习地点信号
     * @param placeId 地点ID
     * @param wifiSsid 当前WiFi SSID
     * @param btDevice 当前蓝牙设备
     * @return 是否学到了新信号
     */
    bool learn(const std::string& placeId, const std::string& wifiSsid, const std::string& btDevice = "") {
        bool learned = false;
        
        LearnedSignals& signals = signals_[placeId];
        
        // 学习WiFi
        if (!wifiSsid.empty() && signals.wifiSSIDs.find(wifiSsid) == signals.wifiSSIDs.end()) {
            signals.wifiSSIDs.insert(wifiSsid);
            learned = true;
        }
        
        // 学习蓝牙
        if (!btDevice.empty() && signals.bluetoothDevices.find(btDevice) == signals.bluetoothDevices.end()) {
            signals.bluetoothDevices.insert(btDevice);
            learned = true;
        }
        
        // 更新访问统计
        signals.visitCount++;
        signals.lastSeen = currentTimeMs();
        
        // 学习典型时间
        int hour = currentHour();
        bool hasHour = false;
        for (const auto& tr : signals.typicalTimes) {
            if (tr.startHour == hour) {
                hasHour = true;
                break;
            }
        }
        if (!hasHour) {
            signals.typicalTimes.push_back({hour, hour + 1});
            if (signals.typicalTimes.size() > 5) {
                signals.typicalTimes.erase(signals.typicalTimes.begin());
            }
        }
        
        return learned;
    }
    
    /**
     * 检查WiFi是否匹配地点
     */
    bool matchesWifi(const std::string& placeId, const std::string& wifiSsid) const {
        auto it = signals_.find(placeId);
        if (it == signals_.end()) return false;
        return it->second.wifiSSIDs.count(wifiSsid) > 0;
    }
    
    /**
     * 根据WiFi查找匹配的地点
     */
    std::vector<std::string> findPlacesByWifi(const std::string& wifiSsid) const {
        std::vector<std::string> result;
        for (const auto& pair : signals_) {
            if (pair.second.wifiSSIDs.count(wifiSsid) > 0) {
                result.push_back(pair.first);
            }
        }
        return result;
    }
    
    /**
     * 获取地点的学习信号
     */
    const LearnedSignals* getSignals(const std::string& placeId) const {
        auto it = signals_.find(placeId);
        return it != signals_.end() ? &it->second : nullptr;
    }
    
    /**
     * 获取信号摘要 (用于序列化)
     */
    SignalSummary getSummary(const std::string& placeId) const {
        SignalSummary summary;
        auto it = signals_.find(placeId);
        if (it != signals_.end()) {
            for (const auto& ssid : it->second.wifiSSIDs) {
                summary.wifiList.push_back(ssid);
            }
            for (const auto& bt : it->second.bluetoothDevices) {
                summary.btList.push_back(bt);
            }
            summary.visitCount = it->second.visitCount;
        }
        return summary;
    }
    
    /**
     * 清除地点信号
     */
    void clear(const std::string& placeId) {
        signals_.erase(placeId);
    }
    
    /**
     * 清除所有
     */
    void clearAll() {
        signals_.clear();
    }

private:
    std::map<std::string, LearnedSignals> signals_;
    
    static int64_t currentTimeMs() {
        // 使用系统时间
        return 0; // 实际实现需要平台特定代码
    }
    
    static int currentHour() {
        return 0; // 实际实现需要平台特定代码
    }
};

}  // namespace place_learner
