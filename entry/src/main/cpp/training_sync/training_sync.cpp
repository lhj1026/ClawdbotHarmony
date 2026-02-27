/**
 * training_sync.cpp — 训练数据同步 C++ 实现
 */
#include "training_sync.h"
#include <sstream>
#include <iomanip>
#include <ctime>
#include <algorithm>
#include <cstdlib>
#include <cerrno>

namespace training_sync {

// Safe stod: uses strtod to avoid throwing exceptions
static double safe_stod(const std::string& s, double defVal = 0.0) {
    if (s.empty()) return defVal;
    const char* start = s.c_str();
    // skip whitespace
    while (*start == ' ' || *start == '\t' || *start == '\n' || *start == '\r') start++;
    if (*start == '\0') return defVal;
    char* end = nullptr;
    errno = 0;
    double val = strtod(start, &end);
    if (end == start || errno == ERANGE) return defVal;
    return val;
}

// ============================================================
// 单例
// ============================================================

TrainingDataSync& TrainingDataSync::getInstance() {
    static TrainingDataSync instance;
    return instance;
}

TrainingDataSync::TrainingDataSync()
    : lastSyncTime_(0)
    , maxRecords_(DEFAULT_MAX_RECORDS) {
}

// ============================================================
// 初始化
// ============================================================

void TrainingDataSync::init(const std::string& deviceId) {
    std::lock_guard<std::mutex> lock(mutex_);
    deviceId_ = deviceId;
}

// ============================================================
// 记录数据
// ============================================================

void TrainingDataSync::recordRuleMatch(const RuleMatchData& data) {
    std::lock_guard<std::mutex> lock(mutex_);
    
    TrainingRecord record;
    record.id = generateId("rm");
    record.type = TrainingDataType::RULE_MATCH;
    record.timestamp = currentTimeMs();
    record.synced = false;
    
    record.stringData["ruleId"] = data.ruleId;
    record.stringData["action"] = data.action;
    record.stringData["timeOfDay"] = data.timeOfDay;
    record.stringData["motionState"] = data.motionState;
    record.stringData["prevMotionState"] = data.prevMotionState;
    record.stringData["prevActivityState"] = data.prevActivityState;
    record.stringData["geofence"] = data.geofence;
    record.stringData["wifiSsid"] = data.wifiSsid;
    
    record.numericData["confidence"] = data.confidence;
    record.numericData["hour"] = data.hour;
    record.numericData["activityDuration"] = static_cast<double>(data.activityDuration);
    record.numericData["batteryLevel"] = data.batteryLevel;
    
    record.boolData["isCharging"] = data.isCharging;
    
    records_.push_back(record);
    pruneIfNeeded();
}

void TrainingDataSync::recordFeedback(const UserFeedbackData& data) {
    std::lock_guard<std::mutex> lock(mutex_);
    
    TrainingRecord record;
    record.id = generateId("fb");
    record.type = TrainingDataType::USER_FEEDBACK;
    record.timestamp = currentTimeMs();
    record.synced = false;
    
    record.stringData["ruleId"] = data.ruleId;
    record.stringData["feedbackType"] = data.feedbackType;
    record.stringData["originalValue"] = data.originalValue;
    record.stringData["adjustedValue"] = data.adjustedValue;
    record.stringData["timeOfDay"] = data.timeOfDay;
    record.stringData["motionState"] = data.motionState;
    record.stringData["prevActivityState"] = data.prevActivityState;
    record.stringData["geofence"] = data.geofence;
    
    record.numericData["hour"] = data.hour;
    record.numericData["activityDuration"] = static_cast<double>(data.activityDuration);
    
    records_.push_back(record);
    pruneIfNeeded();
}

void TrainingDataSync::recordStateTransition(const StateTransitionData& data) {
    std::lock_guard<std::mutex> lock(mutex_);
    
    TrainingRecord record;
    record.id = generateId("st");
    record.type = TrainingDataType::STATE_TRANSITION;
    record.timestamp = currentTimeMs();
    record.synced = false;
    
    record.stringData["prevState"] = data.prevState;
    record.stringData["newState"] = data.newState;
    record.stringData["timeOfDay"] = data.timeOfDay;
    record.stringData["geofence"] = data.geofence;
    record.stringData["wifiSsid"] = data.wifiSsid;
    
    record.numericData["duration"] = static_cast<double>(data.duration);
    record.numericData["hour"] = data.hour;
    
    records_.push_back(record);
    pruneIfNeeded();
}

void TrainingDataSync::recordGeofenceFeature(const GeofenceFeatureData& data) {
    std::lock_guard<std::mutex> lock(mutex_);
    
    TrainingRecord record;
    record.id = generateId("gf");
    record.type = TrainingDataType::GEOFENCE_FEATURE;
    record.timestamp = currentTimeMs();
    record.synced = false;
    
    record.stringData["geofenceId"] = data.geofenceId;
    record.stringData["geofenceName"] = data.geofenceName;
    record.stringData["wifiSsid"] = data.wifiSsid;
    record.stringData["timeOfDay"] = data.timeOfDay;
    
    record.numericData["hour"] = data.hour;
    record.numericData["duration"] = static_cast<double>(data.duration);
    
    records_.push_back(record);
    pruneIfNeeded();
}

// ============================================================
// 导出与同步
// ============================================================

std::string TrainingDataSync::exportPendingAsJson() {
    std::lock_guard<std::mutex> lock(mutex_);
    
    std::ostringstream oss;
    oss << "{\"deviceId\":\"" << escapeJson(deviceId_) << "\",";
    oss << "\"timestamp\":" << currentTimeMs() << ",";
    oss << "\"records\":[";
    
    bool first = true;
    for (const auto& record : records_) {
        if (record.synced) continue;
        
        if (!first) oss << ",";
        first = false;
        
        oss << "{\"id\":\"" << escapeJson(record.id) << "\",";
        oss << "\"type\":\"";
        switch (record.type) {
            case TrainingDataType::RULE_MATCH: oss << "rule_match"; break;
            case TrainingDataType::USER_FEEDBACK: oss << "user_feedback"; break;
            case TrainingDataType::STATE_TRANSITION: oss << "state_transition"; break;
            case TrainingDataType::GEOFENCE_FEATURE: oss << "geofence_feature"; break;
        }
        oss << "\",";
        oss << "\"timestamp\":" << record.timestamp << ",";
        oss << "\"data\":{";
        
        bool firstData = true;
        for (const auto& [k, v] : record.stringData) {
            if (!firstData) oss << ",";
            firstData = false;
            oss << "\"" << escapeJson(k) << "\":\"" << escapeJson(v) << "\"";
        }
        for (const auto& [k, v] : record.numericData) {
            if (!firstData) oss << ",";
            firstData = false;
            oss << "\"" << escapeJson(k) << "\":" << v;
        }
        for (const auto& [k, v] : record.boolData) {
            if (!firstData) oss << ",";
            firstData = false;
            oss << "\"" << escapeJson(k) << "\":" << (v ? "true" : "false");
        }
        
        oss << "}}";
    }
    
    oss << "]}";
    return oss.str();
}

void TrainingDataSync::markAsSynced(const std::vector<std::string>& ids) {
    std::lock_guard<std::mutex> lock(mutex_);
    
    for (const auto& id : ids) {
        for (auto& record : records_) {
            if (record.id == id) {
                record.synced = true;
            }
        }
    }
    lastSyncTime_ = currentTimeMs();
}

void TrainingDataSync::cleanupSynced() {
    std::lock_guard<std::mutex> lock(mutex_);
    
    auto it = std::remove_if(records_.begin(), records_.end(),
        [](const TrainingRecord& r) { return r.synced; });
    records_.erase(it, records_.end());
}

// ============================================================
// 统计
// ============================================================

SyncStats TrainingDataSync::getStats() const {
    std::lock_guard<std::mutex> lock(mutex_);
    
    SyncStats stats;
    stats.lastSyncTime = lastSyncTime_;
    stats.totalRecords = static_cast<int64_t>(records_.size());
    
    for (const auto& record : records_) {
        if (record.synced) {
            stats.syncedCount++;
        } else {
            stats.pendingCount++;
        }
    }
    
    return stats;
}

// ============================================================
// 持久化
// ============================================================

std::string TrainingDataSync::serialize() const {
    std::lock_guard<std::mutex> lock(mutex_);
    
    std::ostringstream oss;
    oss << "{\"deviceId\":\"" << escapeJson(deviceId_) << "\",";
    oss << "\"lastSyncTime\":" << lastSyncTime_ << ",";
    oss << "\"maxRecords\":" << maxRecords_ << ",";
    oss << "\"records\":[";
    
    bool first = true;
    for (const auto& record : records_) {
        if (!first) oss << ",";
        first = false;
        
        oss << "{\"id\":\"" << escapeJson(record.id) << "\",";
        oss << "\"type\":" << static_cast<int>(record.type) << ",";
        oss << "\"timestamp\":" << record.timestamp << ",";
        oss << "\"synced\":" << (record.synced ? "true" : "false") << ",";
        oss << "\"stringData\":{";
        
        bool firstStr = true;
        for (const auto& [k, v] : record.stringData) {
            if (!firstStr) oss << ",";
            firstStr = false;
            oss << "\"" << escapeJson(k) << "\":\"" << escapeJson(v) << "\"";
        }
        oss << "},\"numericData\":{";
        
        bool firstNum = true;
        for (const auto& [k, v] : record.numericData) {
            if (!firstNum) oss << ",";
            firstNum = false;
            oss << "\"" << escapeJson(k) << "\":" << v;
        }
        oss << "},\"boolData\":{";
        
        bool firstBool = true;
        for (const auto& [k, v] : record.boolData) {
            if (!firstBool) oss << ",";
            firstBool = false;
            oss << "\"" << escapeJson(k) << "\":" << (v ? "true" : "false");
        }
        oss << "}}";
    }
    
    oss << "]}";
    return oss.str();
}

bool TrainingDataSync::deserialize(const std::string& json) {
    std::lock_guard<std::mutex> lock(mutex_);

    records_.clear();

    // Helper lambdas that take the string to search in as parameter
    auto extractString = [](const std::string& s, size_t start) -> std::string {
        size_t quoteStart = s.find('"', start);
        if (quoteStart == std::string::npos) return "";
        size_t quoteEnd = s.find('"', quoteStart + 1);
        if (quoteEnd == std::string::npos) return "";
        return s.substr(quoteStart + 1, quoteEnd - quoteStart - 1);
    };

    auto extractNumber = [](const std::string& s, size_t start) -> double {
        size_t colon = s.find(':', start);
        if (colon == std::string::npos) return 0;
        size_t end = s.find_first_of(",}]", colon + 1);
        if (end == std::string::npos) return 0;
        std::string numStr = s.substr(colon + 1, end - colon - 1);
        return safe_stod(numStr);
    };

    auto extractBool = [](const std::string& s, size_t start) -> bool {
        size_t colon = s.find(':', start);
        if (colon == std::string::npos) return false;
        return s.find("true", colon) < s.find_first_of(",}]", colon);
    };

    // Find matching brace to handle nested objects
    auto findMatchingBrace = [](const std::string& s, size_t openPos) -> size_t {
        int depth = 1;
        for (size_t i = openPos + 1; i < s.size(); i++) {
            if (s[i] == '{') depth++;
            else if (s[i] == '}') {
                depth--;
                if (depth == 0) return i;
            }
        }
        return std::string::npos;
    };

    // Parse an object like {"key1":"val1","key2":"val2"} into a map
    auto parseStringMap = [&](const std::string& s, size_t objStart) -> std::map<std::string, std::string> {
        std::map<std::string, std::string> result;
        size_t braceStart = s.find('{', objStart);
        if (braceStart == std::string::npos) return result;
        size_t braceEnd = findMatchingBrace(s, braceStart);
        if (braceEnd == std::string::npos) return result;
        std::string obj = s.substr(braceStart, braceEnd - braceStart + 1);

        size_t pos = 1;
        while (pos < obj.size()) {
            size_t keyStart = obj.find('"', pos);
            if (keyStart == std::string::npos) break;
            size_t keyEnd = obj.find('"', keyStart + 1);
            if (keyEnd == std::string::npos) break;
            std::string key = obj.substr(keyStart + 1, keyEnd - keyStart - 1);

            size_t valStart = obj.find('"', keyEnd + 2);
            if (valStart == std::string::npos) break;
            size_t valEnd = obj.find('"', valStart + 1);
            if (valEnd == std::string::npos) break;
            result[key] = obj.substr(valStart + 1, valEnd - valStart - 1);

            pos = valEnd + 1;
        }
        return result;
    };

    auto parseNumericMap = [&](const std::string& s, size_t objStart) -> std::map<std::string, double> {
        std::map<std::string, double> result;
        size_t braceStart = s.find('{', objStart);
        if (braceStart == std::string::npos) return result;
        size_t braceEnd = findMatchingBrace(s, braceStart);
        if (braceEnd == std::string::npos) return result;
        std::string obj = s.substr(braceStart, braceEnd - braceStart + 1);

        size_t pos = 1;
        while (pos < obj.size()) {
            size_t keyStart = obj.find('"', pos);
            if (keyStart == std::string::npos) break;
            size_t keyEnd = obj.find('"', keyStart + 1);
            if (keyEnd == std::string::npos) break;
            std::string key = obj.substr(keyStart + 1, keyEnd - keyStart - 1);

            size_t colon = obj.find(':', keyEnd);
            if (colon == std::string::npos) break;
            size_t end = obj.find_first_of(",}", colon + 1);
            if (end == std::string::npos) break;
            std::string numStr = obj.substr(colon + 1, end - colon - 1);
            result[key] = safe_stod(numStr);
            pos = end + 1;
        }
        return result;
    };

    auto parseBoolMap = [&](const std::string& s, size_t objStart) -> std::map<std::string, bool> {
        std::map<std::string, bool> result;
        size_t braceStart = s.find('{', objStart);
        if (braceStart == std::string::npos) return result;
        size_t braceEnd = findMatchingBrace(s, braceStart);
        if (braceEnd == std::string::npos) return result;
        std::string obj = s.substr(braceStart, braceEnd - braceStart + 1);

        size_t pos = 1;
        while (pos < obj.size()) {
            size_t keyStart = obj.find('"', pos);
            if (keyStart == std::string::npos) break;
            size_t keyEnd = obj.find('"', keyStart + 1);
            if (keyEnd == std::string::npos) break;
            std::string key = obj.substr(keyStart + 1, keyEnd - keyStart - 1);

            size_t colon = obj.find(':', keyEnd);
            if (colon == std::string::npos) break;
            size_t end = obj.find_first_of(",}", colon + 1);
            if (end == std::string::npos) break;
            std::string val = obj.substr(colon + 1, end - colon - 1);
            result[key] = (val == "true");
            pos = end + 1;
        }
        return result;
    };

    // Parse top-level fields
    size_t deviceIdPos = json.find("\"deviceId\":");
    if (deviceIdPos != std::string::npos) {
        deviceId_ = extractString(json, deviceIdPos);
    }

    size_t lastSyncPos = json.find("\"lastSyncTime\":");
    if (lastSyncPos != std::string::npos) {
        lastSyncTime_ = static_cast<int64_t>(extractNumber(json, lastSyncPos));
    }

    size_t maxRecordsPos = json.find("\"maxRecords\":");
    if (maxRecordsPos != std::string::npos) {
        maxRecords_ = static_cast<int>(extractNumber(json, maxRecordsPos));
    }

    // Parse records array
    size_t recordsStart = json.find("\"records\":[");
    if (recordsStart == std::string::npos) return true;

    size_t arrayStart = json.find('[', recordsStart);
    if (arrayStart == std::string::npos) return true;

    size_t searchPos = arrayStart + 1;
    while (searchPos < json.size()) {
        size_t recordStart = json.find('{', searchPos);
        if (recordStart == std::string::npos) break;

        size_t recordEnd = findMatchingBrace(json, recordStart);
        if (recordEnd == std::string::npos) break;

        std::string rec = json.substr(recordStart, recordEnd - recordStart + 1);

        TrainingRecord record;

        size_t idPos = rec.find("\"id\":");
        if (idPos != std::string::npos) {
            record.id = extractString(rec, idPos);
        }

        size_t typePos = rec.find("\"type\":");
        if (typePos != std::string::npos) {
            int typeVal = static_cast<int>(extractNumber(rec, typePos));
            record.type = static_cast<TrainingDataType>(typeVal);
        }

        size_t tsPos = rec.find("\"timestamp\":");
        if (tsPos != std::string::npos) {
            record.timestamp = static_cast<int64_t>(extractNumber(rec, tsPos));
        }

        size_t syncedPos = rec.find("\"synced\":");
        if (syncedPos != std::string::npos) {
            record.synced = extractBool(rec, syncedPos);
        }

        size_t strDataPos = rec.find("\"stringData\":");
        if (strDataPos != std::string::npos) {
            record.stringData = parseStringMap(rec, strDataPos);
        }

        size_t numDataPos = rec.find("\"numericData\":");
        if (numDataPos != std::string::npos) {
            record.numericData = parseNumericMap(rec, numDataPos);
        }

        size_t boolDataPos = rec.find("\"boolData\":");
        if (boolDataPos != std::string::npos) {
            record.boolData = parseBoolMap(rec, boolDataPos);
        }

        records_.push_back(record);
        searchPos = recordEnd + 1;
    }

    return true;
}

void TrainingDataSync::clear() {
    std::lock_guard<std::mutex> lock(mutex_);
    records_.clear();
    lastSyncTime_ = 0;
}

void TrainingDataSync::setMaxRecords(int maxRecords) {
    std::lock_guard<std::mutex> lock(mutex_);
    maxRecords_ = maxRecords;
}

std::string TrainingDataSync::getDeviceId() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return deviceId_;
}

// ============================================================
// 私有方法
// ============================================================

std::string TrainingDataSync::generateId(const std::string& prefix) {
    int64_t ts = currentTimeMs();
    int rand = static_cast<int>(ts % 100000);
    std::ostringstream oss;
    oss << prefix << "_" << ts << "_" << rand;
    return oss.str();
}

void TrainingDataSync::pruneIfNeeded() {
    if (static_cast<int>(records_.size()) > maxRecords_) {
        auto it = records_.begin();
        while (it != records_.end() && static_cast<int>(records_.size()) > maxRecords_) {
            if (it->synced) {
                it = records_.erase(it);
            } else {
                ++it;
            }
        }
        
        if (static_cast<int>(records_.size()) > maxRecords_) {
            size_t toRemove = records_.size() - maxRecords_;
            records_.erase(records_.begin(), records_.begin() + toRemove);
        }
    }
}

std::string TrainingDataSync::escapeJson(const std::string& s) const {
    std::ostringstream oss;
    for (char c : s) {
        switch (c) {
            case '"': oss << "\\\""; break;
            case '\\': oss << "\\\\"; break;
            case '\b': oss << "\\b"; break;
            case '\f': oss << "\\f"; break;
            case '\n': oss << "\\n"; break;
            case '\r': oss << "\\r"; break;
            case '\t': oss << "\\t"; break;
            default:
                if ('\x00' <= c && c <= '\x1f') {
                    oss << "\\u" << std::hex << std::setw(4) << std::setfill('0') << static_cast<int>(c);
                } else {
                    oss << c;
                }
        }
    }
    return oss.str();
}

int64_t TrainingDataSync::currentTimeMs() const {
    auto now = std::chrono::system_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch());
    return ms.count();
}

}  // namespace training_sync
