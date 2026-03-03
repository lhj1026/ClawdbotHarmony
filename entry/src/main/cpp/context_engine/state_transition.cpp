/**
 * state_transition.cpp — State Transition Tracking implementation
 *
 * Tracks geofence and motion state changes, detects routine patterns,
 * injects 9 transition features into the context map for Stream MLP.
 */
#include "state_transition.h"
#include "context_engine.h"  // for safe_stod

#include <sstream>
#include <chrono>
#include <algorithm>
#include <cstring>

namespace context_engine {

// ============================================================
// Static helpers
// ============================================================

int64_t StateTransitionTracker::nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

std::string StateTransitionTracker::geoCategory(const std::string& geo) {
    if (geo.empty()) return "";
    // "rest" locations
    if (geo.find("home") != std::string::npos) return "rest";
    if (geo.find("cafe") != std::string::npos) return "rest";
    if (geo.find("gym") != std::string::npos) return "rest";
    if (geo.find("park") != std::string::npos) return "rest";
    if (geo.find("mall") != std::string::npos) return "rest";
    // "work" locations
    if (geo.find("office") != std::string::npos) return "work";
    if (geo.find("work") != std::string::npos) return "work";
    if (geo.find("school") != std::string::npos) return "work";
    if (geo.find("hospital") != std::string::npos) return "work";
    return "";
}

std::string StateTransitionTracker::geofenceIcon(const std::string& geo) {
    if (geo.empty()) return "";
    if (geo.find("home") != std::string::npos) return "\xF0\x9F\x8F\xA0";       // 🏠
    if (geo.find("office") != std::string::npos || geo.find("work") != std::string::npos)
        return "\xF0\x9F\x8F\xA2";  // 🏢
    if (geo.find("gym") != std::string::npos) return "\xF0\x9F\x92\xAA";        // 💪
    if (geo.find("cafe") != std::string::npos) return "\xE2\x98\x95";           // ☕
    if (geo.find("mall") != std::string::npos) return "\xF0\x9F\x9B\x8D\xEF\xB8\x8F"; // 🛍️
    if (geo.find("hospital") != std::string::npos) return "\xF0\x9F\x8F\xA5";   // 🏥
    if (geo.find("airport") != std::string::npos) return "\xE2\x9C\x88\xEF\xB8\x8F"; // ✈️
    if (geo.find("school") != std::string::npos) return "\xF0\x9F\x8F\xAB";     // 🏫
    if (geo.find("park") != std::string::npos) return "\xF0\x9F\x8C\xB3";       // 🌳
    if (geo.find("transit") != std::string::npos || geo.find("station") != std::string::npos)
        return "\xF0\x9F\x9A\x8C";  // 🚌
    return "\xF0\x9F\x93\x8D";  // 📍 default
}

std::string StateTransitionTracker::geofenceLabel(const std::string& geo) {
    if (geo.empty()) return "";
    if (geo.find("home") != std::string::npos) return "\xE5\xAE\xB6";           // 家
    if (geo.find("office") != std::string::npos || geo.find("work") != std::string::npos)
        return "\xE5\x8A\x9E\xE5\x85\xAC\xE5\xAE\xA4";  // 办公室
    if (geo.find("gym") != std::string::npos) return "\xE5\x81\xA5\xE8\xBA\xAB\xE6\x88\xBF"; // 健身房
    if (geo.find("cafe") != std::string::npos) return "\xE5\x92\x96\xE5\x95\xA1\xE5\x8E\x85"; // 咖啡厅
    if (geo.find("mall") != std::string::npos) return "\xE5\x95\x86\xE5\x9C\xBA"; // 商场
    if (geo.find("hospital") != std::string::npos) return "\xE5\x8C\xBB\xE9\x99\xA2"; // 医院
    if (geo.find("airport") != std::string::npos) return "\xE6\x9C\xBA\xE5\x9C\xBA"; // 机场
    if (geo.find("school") != std::string::npos) return "\xE5\xAD\xA6\xE6\xA0\xA1"; // 学校
    if (geo.find("park") != std::string::npos) return "\xE5\x85\xAC\xE5\x9B\xAD"; // 公园
    if (geo.find("transit") != std::string::npos || geo.find("station") != std::string::npos)
        return "\xE8\xBD\xA6\xE7\xAB\x99";  // 车站
    // Use the geo ID itself as label if no match
    return geo;
}

void StateTransitionTracker::pruneOldTimestamps(int64_t cutoff) {
    while (!transitionTimestamps_.empty() && transitionTimestamps_.front() < cutoff) {
        transitionTimestamps_.erase(transitionTimestamps_.begin());
    }
}

// ============================================================
// Core logic
// ============================================================

bool StateTransitionTracker::detectStateChange(const ContextMap& ctx) const {
    // 首次调用由 update() 直接处理，不在此判断
    if (current_.timestamp == 0) return false;

    auto geoIt = ctx.find("geofence");
    std::string newGeo = (geoIt != ctx.end()) ? geoIt->second : "";

    auto motionIt = ctx.find("motionState");
    std::string newMotion = (motionIt != ctx.end()) ? motionIt->second : "stationary";

    // Check geofence change
    if (newGeo != current_.geofence) return true;

    // Check motion state change
    if (newMotion != current_.motionState) return true;

    return false;
}

int StateTransitionTracker::classifyDirection(const std::string& fromGeo, const std::string& toGeo) const {
    std::string fromCat = geoCategory(fromGeo);
    std::string toCat = geoCategory(toGeo);

    if (fromCat.empty() || toCat.empty()) return 0;
    if (fromCat == toCat) return 0;

    // rest → work = +1, work → rest = -1
    if (fromCat == "rest" && toCat == "work") return 1;
    if (fromCat == "work" && toCat == "rest") return -1;

    return 0;
}

bool StateTransitionTracker::update(const ContextMap& ctx) {
    bool isFirstCall = (current_.timestamp == 0);

    if (!isFirstCall && !detectStateChange(ctx)) {
        // No state change — just update time_in_current
        return false;
    }

    int64_t now = nowMs();

    if (isFirstCall) {
        // 首次调用：初始化 current_ 但不记录转移
        auto geoIt = ctx.find("geofence");
        current_.geofence = (geoIt != ctx.end()) ? geoIt->second : "";
        current_.geofenceLabel = geofenceLabel(current_.geofence);
        current_.geofenceIcon = geofenceIcon(current_.geofence);
        auto motionIt = ctx.find("motionState");
        current_.motionState = (motionIt != ctx.end()) ? motionIt->second : "stationary";
        current_.timestamp = now;
        // 不设置 hasTransition_, 不修改 previous_
        return false;
    }

    // Save previous state
    previous_ = current_;

    // Build new current state
    auto geoIt = ctx.find("geofence");
    current_.geofence = (geoIt != ctx.end()) ? geoIt->second : "";
    current_.geofenceLabel = geofenceLabel(current_.geofence);
    current_.geofenceIcon = geofenceIcon(current_.geofence);

    auto motionIt = ctx.find("motionState");
    current_.motionState = (motionIt != ctx.end()) ? motionIt->second : "stationary";

    current_.timestamp = now;

    // Record transition timestamp
    transitionTimestamps_.push_back(now);

    // Prune timestamps older than 1 hour
    pruneOldTimestamps(now - 3600000);

    // Update routine detection
    if (previous_.timestamp > 0 && !previous_.geofence.empty() && !current_.geofence.empty()) {
        // Compute hour bucket (0-5, each covers 4 hours)
        auto tp = std::chrono::system_clock::from_time_t(now / 1000);
        std::time_t tt = std::chrono::system_clock::to_time_t(tp);
        struct tm tmBuf;
#ifdef _WIN32
        localtime_s(&tmBuf, &tt);
#else
        localtime_r(&tt, &tmBuf);
#endif
        int hourBucket = tmBuf.tm_hour / 4;

        std::string routeKey = previous_.geofence + "|" + current_.geofence + "|" + std::to_string(hourBucket);
        routeCounts_[routeKey]++;
    }

    hasTransition_ = (previous_.timestamp > 0);
    return true;
}

void StateTransitionTracker::injectFeatures(ContextMap& ctx) const {
    if (!hasTransition_) {
        // No transition data — all features default to "0" (buildFeatures handles missing keys)
        return;
    }

    // [16] prev_geofence: had a previous geofence?
    ctx["prev_geofence"] = (!previous_.geofence.empty()) ? "1" : "0";

    // [17] geofence_changed
    ctx["geofence_changed"] = (previous_.geofence != current_.geofence) ? "1" : "0";

    // [18-19] prev_motionState 2-hot
    bool wasStationary = (previous_.motionState == "stationary");
    bool wasMoving = (previous_.motionState == "walking" || previous_.motionState == "running" ||
                      previous_.motionState == "driving" || previous_.motionState == "transit");
    ctx["prev_motionState_stationary"] = wasStationary ? "1" : "0";
    ctx["prev_motionState_moving"] = wasMoving ? "1" : "0";

    // [20] transition_duration_min
    double durationMin = 0.0;
    if (previous_.timestamp > 0 && current_.timestamp > previous_.timestamp) {
        durationMin = static_cast<double>(current_.timestamp - previous_.timestamp) / 60000.0;
    }
    double normalizedDuration = std::min(durationMin / 120.0, 1.0);
    ctx["transition_duration_min"] = std::to_string(normalizedDuration);

    // [21] time_in_current_state_min
    int64_t now = nowMs();
    double timeInCurrentMin = 0.0;
    if (current_.timestamp > 0) {
        timeInCurrentMin = static_cast<double>(now - current_.timestamp) / 60000.0;
    }
    double normalizedTimeInCurrent = std::min(timeInCurrentMin / 240.0, 1.0);
    ctx["time_in_current_state_min"] = std::to_string(normalizedTimeInCurrent);

    // [22] transitions_last_hour
    int count = static_cast<int>(transitionTimestamps_.size());
    double normalizedCount = std::min(static_cast<double>(count) / 10.0, 1.0);
    ctx["transitions_last_hour"] = std::to_string(normalizedCount);

    // [23] is_routine_transition
    bool isRoutine = false;
    if (!previous_.geofence.empty() && !current_.geofence.empty()) {
        // Check all hour buckets for this route
        for (int hb = 0; hb < 6; ++hb) {
            std::string routeKey = previous_.geofence + "|" + current_.geofence + "|" + std::to_string(hb);
            auto it = routeCounts_.find(routeKey);
            if (it != routeCounts_.end() && it->second >= ROUTINE_THRESHOLD) {
                isRoutine = true;
                break;
            }
        }
    }
    ctx["is_routine_transition"] = isRoutine ? "1" : "0";

    // [24] transition_direction: (dir+1)/2 → [0, 1]
    int dir = classifyDirection(previous_.geofence, current_.geofence);
    double normalizedDir = (static_cast<double>(dir) + 1.0) / 2.0;
    ctx["transition_direction"] = std::to_string(normalizedDir);
}

TransitionInfo StateTransitionTracker::getTransitionInfo() const {
    TransitionInfo info;
    info.prev = previous_;
    info.current = current_;

    if (hasTransition_ && previous_.timestamp > 0 && current_.timestamp > previous_.timestamp) {
        info.durationMin = static_cast<double>(current_.timestamp - previous_.timestamp) / 60000.0;
    }

    int64_t now = nowMs();
    if (current_.timestamp > 0) {
        info.timeInCurrentMin = static_cast<double>(now - current_.timestamp) / 60000.0;
    }

    info.transitionsLastHour = static_cast<int>(transitionTimestamps_.size());
    info.direction = classifyDirection(previous_.geofence, current_.geofence);

    // Check routine
    if (!previous_.geofence.empty() && !current_.geofence.empty()) {
        for (int hb = 0; hb < 6; ++hb) {
            std::string routeKey = previous_.geofence + "|" + current_.geofence + "|" + std::to_string(hb);
            auto it = routeCounts_.find(routeKey);
            if (it != routeCounts_.end() && it->second >= ROUTINE_THRESHOLD) {
                info.isRoutine = true;
                break;
            }
        }
    }

    // Build pattern label
    if (info.isRoutine) {
        // 常规通勤
        info.patternLabel = "\xE5\xB8\xB8\xE8\xA7\x84\xE9\x80\x9A\xE5\x8B\xA4";  // 常规通勤
    }

    return info;
}

// Escape a string for embedding in JSON
static std::string jsonEscape(const std::string& s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:   out += c; break;
        }
    }
    return out;
}

std::string StateTransitionTracker::getTransitionJson() const {
    if (!hasTransition_ || previous_.timestamp == 0) {
        return "{}";
    }
    // from 和 to 都无 label 时不显示路径条
    if (previous_.geofenceLabel.empty() && current_.geofenceLabel.empty()) {
        return "{}";
    }

    TransitionInfo info = getTransitionInfo();

    std::ostringstream ss;
    ss << "{\"from\":{\"icon\":\"" << jsonEscape(previous_.geofenceIcon)
       << "\",\"label\":\"" << jsonEscape(previous_.geofenceLabel)
       << "\",\"geofence\":\"" << jsonEscape(previous_.geofence)
       << "\",\"motionState\":\"" << jsonEscape(previous_.motionState)
       << "\"},\"to\":{\"icon\":\"" << jsonEscape(current_.geofenceIcon)
       << "\",\"label\":\"" << jsonEscape(current_.geofenceLabel)
       << "\",\"geofence\":\"" << jsonEscape(current_.geofence)
       << "\",\"motionState\":\"" << jsonEscape(current_.motionState)
       << "\"},\"durationMin\":" << info.durationMin
       << ",\"timeInCurrentMin\":" << info.timeInCurrentMin
       << ",\"transitionsLastHour\":" << info.transitionsLastHour
       << ",\"isRoutine\":" << (info.isRoutine ? "true" : "false")
       << ",\"direction\":" << info.direction;

    if (!info.patternLabel.empty()) {
        ss << ",\"patternLabel\":\"" << jsonEscape(info.patternLabel) << "\"";
    }

    ss << "}";
    return ss.str();
}

// ============================================================
// Persistence
// ============================================================

std::string StateTransitionTracker::exportJson() const {
    std::ostringstream ss;
    ss << "{\"hasTransition\":" << (hasTransition_ ? "true" : "false");

    // Current state
    ss << ",\"current\":{\"geofence\":\"" << jsonEscape(current_.geofence)
       << "\",\"geofenceLabel\":\"" << jsonEscape(current_.geofenceLabel)
       << "\",\"geofenceIcon\":\"" << jsonEscape(current_.geofenceIcon)
       << "\",\"motionState\":\"" << jsonEscape(current_.motionState)
       << "\",\"timestamp\":" << current_.timestamp << "}";

    // Previous state
    ss << ",\"previous\":{\"geofence\":\"" << jsonEscape(previous_.geofence)
       << "\",\"geofenceLabel\":\"" << jsonEscape(previous_.geofenceLabel)
       << "\",\"geofenceIcon\":\"" << jsonEscape(previous_.geofenceIcon)
       << "\",\"motionState\":\"" << jsonEscape(previous_.motionState)
       << "\",\"timestamp\":" << previous_.timestamp << "}";

    // Route counts
    ss << ",\"routeCounts\":{";
    bool first = true;
    for (const auto& [key, count] : routeCounts_) {
        if (!first) ss << ",";
        first = false;
        ss << "\"" << jsonEscape(key) << "\":" << count;
    }
    ss << "}}";

    return ss.str();
}

// Minimal JSON helpers for import
static std::string findStrVal(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return "";
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return "";
    pos = json.find('"', pos + 1);
    if (pos == std::string::npos) return "";
    auto end = json.find('"', pos + 1);
    if (end == std::string::npos) return "";
    return json.substr(pos + 1, end - pos - 1);
}

static int64_t findIntVal(const std::string& json, const std::string& key, int64_t def) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return def;
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return def;
    pos++;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) pos++;
    char* end = nullptr;
    long long val = strtoll(json.c_str() + pos, &end, 10);
    if (end == json.c_str() + pos) return def;
    return static_cast<int64_t>(val);
}

static bool findBoolVal(const std::string& json, const std::string& key, bool def) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return def;
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return def;
    auto rest = json.substr(pos + 1, 10);
    if (rest.find("true") != std::string::npos) return true;
    if (rest.find("false") != std::string::npos) return false;
    return def;
}

void StateTransitionTracker::importJson(const std::string& json) {
    if (json.empty() || json == "{}") return;

    hasTransition_ = findBoolVal(json, "hasTransition", false);

    // Parse current state
    auto curPos = json.find("\"current\"");
    if (curPos != std::string::npos) {
        auto bracePos = json.find('{', curPos + 9);
        if (bracePos != std::string::npos) {
            int depth = 1;
            size_t end = bracePos + 1;
            while (end < json.size() && depth > 0) {
                if (json[end] == '{') depth++;
                else if (json[end] == '}') depth--;
                end++;
            }
            std::string curJson = json.substr(bracePos, end - bracePos);
            current_.geofence = findStrVal(curJson, "geofence");
            current_.geofenceLabel = findStrVal(curJson, "geofenceLabel");
            current_.geofenceIcon = findStrVal(curJson, "geofenceIcon");
            current_.motionState = findStrVal(curJson, "motionState");
            current_.timestamp = findIntVal(curJson, "timestamp", 0);
        }
    }

    // Parse previous state
    auto prevPos = json.find("\"previous\"");
    if (prevPos != std::string::npos) {
        auto bracePos = json.find('{', prevPos + 10);
        if (bracePos != std::string::npos) {
            int depth = 1;
            size_t end = bracePos + 1;
            while (end < json.size() && depth > 0) {
                if (json[end] == '{') depth++;
                else if (json[end] == '}') depth--;
                end++;
            }
            std::string prevJson = json.substr(bracePos, end - bracePos);
            previous_.geofence = findStrVal(prevJson, "geofence");
            previous_.geofenceLabel = findStrVal(prevJson, "geofenceLabel");
            previous_.geofenceIcon = findStrVal(prevJson, "geofenceIcon");
            previous_.motionState = findStrVal(prevJson, "motionState");
            previous_.timestamp = findIntVal(prevJson, "timestamp", 0);
        }
    }

    // Parse route counts
    routeCounts_.clear();
    auto rcPos = json.find("\"routeCounts\"");
    if (rcPos != std::string::npos) {
        auto bracePos = json.find('{', rcPos + 13);
        if (bracePos != std::string::npos) {
            int depth = 1;
            size_t end = bracePos + 1;
            while (end < json.size() && depth > 0) {
                if (json[end] == '{') depth++;
                else if (json[end] == '}') depth--;
                end++;
            }
            std::string rcJson = json.substr(bracePos, end - bracePos);

            // Parse "key":count pairs
            size_t pos = 0;
            while (pos < rcJson.size()) {
                auto keyStart = rcJson.find('"', pos);
                if (keyStart == std::string::npos) break;
                auto keyEnd = rcJson.find('"', keyStart + 1);
                if (keyEnd == std::string::npos) break;
                std::string key = rcJson.substr(keyStart + 1, keyEnd - keyStart - 1);

                auto colonPos = rcJson.find(':', keyEnd + 1);
                if (colonPos == std::string::npos) break;
                size_t numStart = colonPos + 1;
                while (numStart < rcJson.size() && (rcJson[numStart] == ' ')) numStart++;

                char* numEnd = nullptr;
                int count = static_cast<int>(strtol(rcJson.c_str() + numStart, &numEnd, 10));
                if (numEnd > rcJson.c_str() + numStart && !key.empty()) {
                    routeCounts_[key] = count;
                }
                pos = static_cast<size_t>(numEnd - rcJson.c_str());
            }
        }
    }
}

}  // namespace context_engine
