/**
 * federated_sync.cpp — 联邦学习同步 C++ 核心实现
 *
 * 核心职责:
 * 1. 匿名化: 去除所有设备级 PII (WiFi SSID, 围栏名, GPS, 蓝牙设备名)
 * 2. 导出: 构建 FederatedModelUpdate JSON
 * 3. 解析: 解析服务器返回的 FederatedModel
 * 4. 转换: 社区规则 → 引擎规则
 */
#include "federated_sync.h"
#include <sstream>
#include <iomanip>
#include <algorithm>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <cerrno>
#include <numeric>

namespace federated_sync {

// ============================================================
// SHA256 — 简化实现 (无外部依赖)
// ============================================================

namespace {

// SHA256 常量
static const uint32_t K256[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
};

inline uint32_t rotr(uint32_t x, uint32_t n) { return (x >> n) | (x << (32 - n)); }
inline uint32_t ch(uint32_t x, uint32_t y, uint32_t z) { return (x & y) ^ (~x & z); }
inline uint32_t maj(uint32_t x, uint32_t y, uint32_t z) { return (x & y) ^ (x & z) ^ (y & z); }
inline uint32_t sig0(uint32_t x) { return rotr(x, 2) ^ rotr(x, 13) ^ rotr(x, 22); }
inline uint32_t sig1(uint32_t x) { return rotr(x, 6) ^ rotr(x, 11) ^ rotr(x, 25); }
inline uint32_t ssig0(uint32_t x) { return rotr(x, 7) ^ rotr(x, 18) ^ (x >> 3); }
inline uint32_t ssig1(uint32_t x) { return rotr(x, 17) ^ rotr(x, 19) ^ (x >> 10); }

std::string computeSha256(const std::string& input) {
    // Initial hash values
    uint32_t h[8] = {
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
    };

    // Pre-processing: padding
    size_t origLen = input.size();
    size_t bitLen = origLen * 8;

    // Message needs to be padded to 512-bit (64-byte) blocks
    size_t padLen = origLen + 1;
    while (padLen % 64 != 56) padLen++;
    padLen += 8;

    std::vector<uint8_t> msg(padLen, 0);
    std::memcpy(msg.data(), input.data(), origLen);
    msg[origLen] = 0x80;

    // Append length in big-endian
    for (int i = 0; i < 8; i++) {
        msg[padLen - 1 - i] = static_cast<uint8_t>((bitLen >> (i * 8)) & 0xff);
    }

    // Process each 64-byte block
    for (size_t offset = 0; offset < padLen; offset += 64) {
        uint32_t w[64];
        for (int i = 0; i < 16; i++) {
            w[i] = (static_cast<uint32_t>(msg[offset + i * 4]) << 24) |
                   (static_cast<uint32_t>(msg[offset + i * 4 + 1]) << 16) |
                   (static_cast<uint32_t>(msg[offset + i * 4 + 2]) << 8) |
                   (static_cast<uint32_t>(msg[offset + i * 4 + 3]));
        }
        for (int i = 16; i < 64; i++) {
            w[i] = ssig1(w[i - 2]) + w[i - 7] + ssig0(w[i - 15]) + w[i - 16];
        }

        uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
        uint32_t e = h[4], f = h[5], g = h[6], hh = h[7];

        for (int i = 0; i < 64; i++) {
            uint32_t t1 = hh + sig1(e) + ch(e, f, g) + K256[i] + w[i];
            uint32_t t2 = sig0(a) + maj(a, b, c);
            hh = g; g = f; f = e; e = d + t1;
            d = c; c = b; b = a; a = t1 + t2;
        }

        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }

    // Output as hex string
    std::ostringstream oss;
    for (int i = 0; i < 8; i++) {
        oss << std::hex << std::setw(8) << std::setfill('0') << h[i];
    }
    return oss.str();
}

// Safe stod: uses strtod to avoid throwing exceptions
double safe_stod(const std::string& s, double defVal = 0.0) {
    if (s.empty()) return defVal;
    const char* start = s.c_str();
    while (*start == ' ' || *start == '\t' || *start == '\n' || *start == '\r') start++;
    if (*start == '\0') return defVal;
    char* end = nullptr;
    errno = 0;
    double val = strtod(start, &end);
    if (end == start || errno == ERANGE) return defVal;
    return val;
}

// Minimal JSON string extractor
std::string jsonGetStr(const std::string& json, const std::string& key) {
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

double jsonGetNum(const std::string& json, const std::string& key, double defVal = 0.0) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return defVal;
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return defVal;
    pos++;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) pos++;
    return safe_stod(json.substr(pos), defVal);
}

bool jsonGetBool(const std::string& json, const std::string& key, bool defVal = false) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return defVal;
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return defVal;
    auto rest = json.substr(pos + 1);
    auto truePos = rest.find("true");
    auto falsePos = rest.find("false");
    if (truePos != std::string::npos && (falsePos == std::string::npos || truePos < falsePos))
        return true;
    if (falsePos != std::string::npos) return false;
    return defVal;
}

// Find matching brace
size_t findMatchingBrace(const std::string& s, size_t openPos) {
    int depth = 1;
    for (size_t i = openPos + 1; i < s.size(); i++) {
        if (s[i] == '{') depth++;
        else if (s[i] == '}') {
            depth--;
            if (depth == 0) return i;
        }
    }
    return std::string::npos;
}

// Find matching bracket
size_t findMatchingBracket(const std::string& s, size_t openPos) {
    int depth = 1;
    for (size_t i = openPos + 1; i < s.size(); i++) {
        if (s[i] == '[') depth++;
        else if (s[i] == ']') {
            depth--;
            if (depth == 0) return i;
        }
    }
    return std::string::npos;
}

}  // anonymous namespace

// ============================================================
// 安全 key 白名单
// ============================================================

const std::set<std::string>& FederatedSync::safeKeys() {
    static const std::set<std::string> keys = {
        "timeOfDay", "hour", "dayOfWeek", "isWeekend",
        "motionState", "batteryLevel", "isCharging",
        "networkType", "sensorTier", "heart_rate_status",
        "transportMode", "activityState", "wearing_state"
    };
    return keys;
}

// ============================================================
// 单例
// ============================================================

FederatedSync& FederatedSync::getInstance() {
    static FederatedSync instance;
    return instance;
}

FederatedSync::FederatedSync() {}

// ============================================================
// 初始化
// ============================================================

void FederatedSync::init(const std::string& deviceId) {
    std::lock_guard<std::mutex> lock(mutex_);
    deviceId_ = deviceId;
    deviceFingerprint_ = sha256(deviceId);
}

void FederatedSync::setGeofenceCategories(
    const std::vector<GeofenceCategoryEntry>& categories) {
    std::lock_guard<std::mutex> lock(mutex_);
    geofenceToCategory_.clear();
    categoryToGeofence_.clear();
    for (const auto& entry : categories) {
        geofenceToCategory_[entry.geofenceId] = entry.category;
        // 每个类别只记录第一个围栏
        if (categoryToGeofence_.find(entry.category) == categoryToGeofence_.end()) {
            categoryToGeofence_[entry.category] = entry.geofenceId;
        }
    }
}

// ============================================================
// 匿名化
// ============================================================

bool FederatedSync::anonymizeCondition(const RuleCondition& cond,
                                        AnonymizedCondition& out) const {
    // 白名单: 允许直接传输的 key
    if (safeKeys().count(cond.key) > 0) {
        out.key = cond.key;
        out.op = cond.op;
        out.value = cond.value;
        return true;
    }

    // 围栏 → 地点类别
    if (cond.key == "geofence") {
        std::string category = getGeofenceCategory(cond.value);
        if (category.empty() || category == "custom") return false;
        out.key = "placeCategory";
        out.op = "eq";
        out.value = category;
        return true;
    }

    // WiFi 围栏类别 (wifiGeofence 已经是类别)
    if (cond.key == "wifiGeofence") {
        out.key = "placeCategory";
        out.op = cond.op;
        out.value = cond.value;
        return true;
    }

    // 不安全的 key 一律丢弃
    // wifiSsid, wifiLost, bt_fixed_devices, bt_vehicle_devices,
    // latitude, longitude, cellId, etc.
    return false;
}

std::string FederatedSync::getGeofenceCategory(
    const std::string& geofenceId) const {
    auto it = geofenceToCategory_.find(geofenceId);
    if (it != geofenceToCategory_.end()) return it->second;
    return "";
}

std::string FederatedSync::findGeofenceByCategory(
    const std::string& category) const {
    auto it = categoryToGeofence_.find(category);
    if (it != categoryToGeofence_.end()) return it->second;
    return "";
}

// ============================================================
// 规则 JSON 解析
// ============================================================

std::vector<EngineRule> FederatedSync::parseRules(const std::string& json) const {
    std::vector<EngineRule> rules;

    size_t pos = json.find('[');
    if (pos == std::string::npos) return rules;

    pos++;
    while (pos < json.size()) {
        auto objStart = json.find('{', pos);
        if (objStart == std::string::npos) break;
        auto objEnd = findMatchingBrace(json, objStart);
        if (objEnd == std::string::npos) break;

        std::string ruleJson = json.substr(objStart, objEnd - objStart + 1);

        EngineRule rule;
        rule.id = jsonGetStr(ruleJson, "id");
        rule.name = jsonGetStr(ruleJson, "name");
        rule.priority = jsonGetNum(ruleJson, "priority", 1.0);
        rule.cooldownMs = static_cast<int64_t>(jsonGetNum(ruleJson, "cooldownMs", 0));
        rule.enabled = jsonGetBool(ruleJson, "enabled", true);
        rule.triggerCount = 0;
        rule.acceptCount = 0;
        rule.confidence = 0.0;

        // Parse action
        auto actionPos = ruleJson.find("\"action\"");
        if (actionPos != std::string::npos) {
            auto bracePos = ruleJson.find('{', actionPos);
            if (bracePos != std::string::npos) {
                auto braceEnd = findMatchingBrace(ruleJson, bracePos);
                if (braceEnd != std::string::npos) {
                    std::string actJson = ruleJson.substr(bracePos, braceEnd - bracePos + 1);
                    rule.action.id = jsonGetStr(actJson, "id");
                    rule.action.type = jsonGetStr(actJson, "type");
                    rule.action.payload = jsonGetStr(actJson, "payload");
                }
            }
        }

        // Parse conditions
        auto condPos = ruleJson.find("\"conditions\"");
        if (condPos != std::string::npos) {
            auto arrStart = ruleJson.find('[', condPos);
            if (arrStart != std::string::npos) {
                size_t p = arrStart + 1;
                while (p < ruleJson.size()) {
                    auto cObjStart = ruleJson.find('{', p);
                    if (cObjStart == std::string::npos) break;
                    auto cObjEnd = findMatchingBrace(ruleJson, cObjStart);
                    if (cObjEnd == std::string::npos) break;
                    std::string condJson = ruleJson.substr(cObjStart, cObjEnd - cObjStart + 1);

                    RuleCondition cond;
                    cond.key = jsonGetStr(condJson, "key");
                    cond.op = jsonGetStr(condJson, "op");
                    cond.value = jsonGetStr(condJson, "value");
                    if (!cond.key.empty()) {
                        rule.conditions.push_back(cond);
                    }
                    p = cObjEnd + 1;
                    auto nextBrace = ruleJson.find_first_of("[]{}", p);
                    if (nextBrace != std::string::npos && ruleJson[nextBrace] == ']') break;
                }
            }
        }

        if (!rule.id.empty()) {
            rules.push_back(rule);
        }
        pos = objEnd + 1;
    }

    return rules;
}

std::map<std::string, int> FederatedSync::parseStats(const std::string& json) const {
    std::map<std::string, int> stats;
    // Parse MAB stats: {"actionId":{"pulls":N,...},...}
    // We just need pull counts per action for triggerCount estimation
    size_t pos = 1;
    while (pos < json.size()) {
        auto keyStart = json.find('"', pos);
        if (keyStart == std::string::npos) break;
        auto keyEnd = json.find('"', keyStart + 1);
        if (keyEnd == std::string::npos) break;
        std::string key = json.substr(keyStart + 1, keyEnd - keyStart - 1);

        auto objStart = json.find('{', keyEnd);
        if (objStart == std::string::npos) break;
        auto objEnd = findMatchingBrace(json, objStart);
        if (objEnd == std::string::npos) break;
        std::string objJson = json.substr(objStart, objEnd - objStart + 1);

        int pulls = static_cast<int>(jsonGetNum(objJson, "pulls", 0));
        stats[key] = pulls;
        pos = objEnd + 1;
    }
    return stats;
}

// ============================================================
// 导出匿名化规则
// ============================================================

std::vector<AnonymizedRule> FederatedSync::exportAnonymizedRules(
    const std::string& rulesJson,
    const std::string& statsJson) {

    std::lock_guard<std::mutex> lock(mutex_);

    auto rules = parseRules(rulesJson);
    auto stats = parseStats(statsJson);

    std::vector<AnonymizedRule> result;

    for (auto& rule : rules) {
        if (!rule.enabled) continue;

        // 用 MAB stats 补充统计信息
        auto statIt = stats.find(rule.action.id);
        if (statIt != stats.end()) {
            rule.triggerCount = statIt->second;
        }

        // 只导出有足够数据的规则
        if (rule.triggerCount < 5) continue;

        // 估算 confidence (如果没有精确数据，用 MAB avgReward 作为近似)
        // 实际 confidence 需要从 feedback 数据计算
        if (rule.confidence < 0.1) {
            rule.confidence = 0.6;  // 默认: 已启用的规则假设中等置信度
        }

        // 匿名化条件
        std::vector<AnonymizedCondition> anonConds;
        for (const auto& cond : rule.conditions) {
            AnonymizedCondition anonCond;
            if (anonymizeCondition(cond, anonCond)) {
                anonConds.push_back(anonCond);
            }
        }

        // 至少保留 2 个有意义的条件
        if (anonConds.size() < 2) continue;

        // 构建条件指纹
        std::vector<std::string> condStrs;
        for (const auto& ac : anonConds) {
            condStrs.push_back(ac.key + ":" + ac.op + ":" + ac.value);
        }
        std::sort(condStrs.begin(), condStrs.end());
        std::string condConcat;
        for (const auto& s : condStrs) {
            if (!condConcat.empty()) condConcat += "|";
            condConcat += s;
        }

        AnonymizedRule anonRule;
        anonRule.conditionFingerprint = sha256(condConcat);
        anonRule.conditions = anonConds;
        anonRule.actionType = rule.action.type;
        anonRule.actionPayloadHash = sha256(rule.action.payload);
        anonRule.confidence = rule.confidence;
        anonRule.triggerCount = rule.triggerCount;
        anonRule.acceptCount = rule.acceptCount;

        result.push_back(anonRule);
    }

    return result;
}

// ============================================================
// 导出行为模式
// ============================================================

std::vector<BehaviorPattern> FederatedSync::exportBehaviorPatterns(
    const std::vector<BehaviorRecord>& records) {

    std::lock_guard<std::mutex> lock(mutex_);

    // 聚合: key = placeCategory|timeOfDay|dayType|motionState|actionType
    std::map<std::string, int> freq;

    for (const auto& rec : records) {
        std::string key = rec.placeCategory + "|" + rec.timeOfDay + "|" +
                          (rec.isWeekend ? "weekend" : "weekday") + "|" +
                          rec.motionState + "|" + rec.actionType;
        freq[key]++;
    }

    std::vector<BehaviorPattern> patterns;
    for (const auto& [key, count] : freq) {
        if (count < 2) continue;  // 忽略偶发模式

        // 解析 key
        BehaviorPattern pat;
        std::istringstream iss(key);
        std::string token;
        int idx = 0;
        while (std::getline(iss, token, '|')) {
            switch (idx) {
                case 0: pat.placeCategory = token; break;
                case 1: pat.timeOfDay = token; break;
                case 2: pat.dayType = token; break;
                case 3: pat.motionState = token; break;
                case 4: pat.actionType = token; break;
            }
            idx++;
        }
        pat.frequency = count;
        patterns.push_back(pat);
    }

    // 按频次降序排列
    std::sort(patterns.begin(), patterns.end(),
        [](const BehaviorPattern& a, const BehaviorPattern& b) {
            return a.frequency > b.frequency;
        });

    // Top-20
    if (patterns.size() > 20) {
        patterns.resize(20);
    }

    return patterns;
}

// ============================================================
// 构建联邦模型更新 JSON
// ============================================================

std::string FederatedSync::buildModelUpdate(
    const std::string& rulesJson,
    const std::string& statsJson,
    const std::string& linucbJson,
    const std::vector<BehaviorRecord>& records,
    int localDataPoints) {

    auto anonRules = exportAnonymizedRules(rulesJson, statsJson);
    auto patterns = exportBehaviorPatterns(records);

    std::lock_guard<std::mutex> lock(mutex_);

    std::ostringstream oss;
    oss << "{";
    oss << "\"protocolVersion\":1,";
    oss << "\"deviceFingerprint\":\"" << escapeJson(deviceFingerprint_) << "\",";
    oss << "\"timestamp\":" << currentTimeMs() << ",";
    oss << "\"dataPoints\":" << localDataPoints << ",";

    // L1: 匿名化规则
    oss << "\"rules\":[";
    for (size_t i = 0; i < anonRules.size(); i++) {
        if (i > 0) oss << ",";
        const auto& r = anonRules[i];
        oss << "{";
        oss << "\"conditionFingerprint\":\"" << escapeJson(r.conditionFingerprint) << "\",";
        oss << "\"conditions\":[";
        for (size_t j = 0; j < r.conditions.size(); j++) {
            if (j > 0) oss << ",";
            const auto& c = r.conditions[j];
            oss << "{\"key\":\"" << escapeJson(c.key) << "\",";
            oss << "\"op\":\"" << escapeJson(c.op) << "\",";
            oss << "\"value\":\"" << escapeJson(c.value) << "\"}";
        }
        oss << "],";
        oss << "\"actionType\":\"" << escapeJson(r.actionType) << "\",";
        oss << "\"actionPayloadHash\":\"" << escapeJson(r.actionPayloadHash) << "\",";
        oss << "\"confidence\":" << r.confidence << ",";
        oss << "\"triggerCount\":" << r.triggerCount << ",";
        oss << "\"acceptCount\":" << r.acceptCount;
        oss << "}";
    }
    oss << "],";

    // L2: LinUCB 状态 (pass through — 本身无 PII)
    oss << "\"linucbState\":" << (linucbJson.empty() ? "null" : "\"" + escapeJson(linucbJson) + "\"") << ",";

    // L3: 行为模式
    oss << "\"patterns\":[";
    for (size_t i = 0; i < patterns.size(); i++) {
        if (i > 0) oss << ",";
        const auto& p = patterns[i];
        oss << "{\"placeCategory\":\"" << escapeJson(p.placeCategory) << "\",";
        oss << "\"timeOfDay\":\"" << escapeJson(p.timeOfDay) << "\",";
        oss << "\"dayType\":\"" << escapeJson(p.dayType) << "\",";
        oss << "\"motionState\":\"" << escapeJson(p.motionState) << "\",";
        oss << "\"actionType\":\"" << escapeJson(p.actionType) << "\",";
        oss << "\"frequency\":" << p.frequency << "}";
    }
    oss << "]";

    oss << "}";
    return oss.str();
}

// ============================================================
// 解析联邦模型（服务器 → 设备）
// ============================================================

FederatedModel FederatedSync::parseFederatedModel(const std::string& json) {
    std::lock_guard<std::mutex> lock(mutex_);

    FederatedModel model;
    model.protocolVersion = static_cast<int>(jsonGetNum(json, "protocolVersion", 1));
    model.aggregatedAt = static_cast<int64_t>(jsonGetNum(json, "aggregatedAt", 0));
    model.participantCount = static_cast<int>(jsonGetNum(json, "participantCount", 0));
    model.linucbState = jsonGetStr(json, "linucbState");
    model.modelVersion = static_cast<int>(jsonGetNum(json, "modelVersion", 0));

    // Parse communityRules array
    auto rulesPos = json.find("\"communityRules\"");
    if (rulesPos != std::string::npos) {
        auto arrStart = json.find('[', rulesPos);
        if (arrStart != std::string::npos) {
            auto arrEnd = findMatchingBracket(json, arrStart);
            if (arrEnd != std::string::npos) {
                std::string arrJson = json.substr(arrStart, arrEnd - arrStart + 1);
                size_t pos = 1;
                while (pos < arrJson.size()) {
                    auto objStart = arrJson.find('{', pos);
                    if (objStart == std::string::npos) break;
                    auto objEnd = findMatchingBrace(arrJson, objStart);
                    if (objEnd == std::string::npos) break;
                    std::string rJson = arrJson.substr(objStart, objEnd - objStart + 1);

                    CommunityRule cr;
                    cr.id = jsonGetStr(rJson, "id");
                    cr.actionType = jsonGetStr(rJson, "actionType");
                    cr.actionPayload = jsonGetStr(rJson, "actionPayload");
                    cr.communityConfidence = jsonGetNum(rJson, "communityConfidence", 0);
                    cr.deviceCount = static_cast<int>(jsonGetNum(rJson, "deviceCount", 0));
                    cr.name = jsonGetStr(rJson, "name");

                    // Parse conditions
                    auto condPos = rJson.find("\"conditions\"");
                    if (condPos != std::string::npos) {
                        auto cArrStart = rJson.find('[', condPos);
                        if (cArrStart != std::string::npos) {
                            size_t cp = cArrStart + 1;
                            while (cp < rJson.size()) {
                                auto cObjStart = rJson.find('{', cp);
                                if (cObjStart == std::string::npos) break;
                                auto cObjEnd = findMatchingBrace(rJson, cObjStart);
                                if (cObjEnd == std::string::npos) break;
                                std::string cJson = rJson.substr(cObjStart, cObjEnd - cObjStart + 1);

                                AnonymizedCondition ac;
                                ac.key = jsonGetStr(cJson, "key");
                                ac.op = jsonGetStr(cJson, "op");
                                ac.value = jsonGetStr(cJson, "value");
                                if (!ac.key.empty()) cr.conditions.push_back(ac);

                                cp = cObjEnd + 1;
                                auto nb = rJson.find_first_of("[]{}", cp);
                                if (nb != std::string::npos && rJson[nb] == ']') break;
                            }
                        }
                    }

                    if (!cr.id.empty()) model.communityRules.push_back(cr);
                    pos = objEnd + 1;
                }
            }
        }
    }

    // Parse topPatterns array
    auto patPos = json.find("\"topPatterns\"");
    if (patPos != std::string::npos) {
        auto arrStart = json.find('[', patPos);
        if (arrStart != std::string::npos) {
            auto arrEnd = findMatchingBracket(json, arrStart);
            if (arrEnd != std::string::npos) {
                std::string arrJson = json.substr(arrStart, arrEnd - arrStart + 1);
                size_t pos = 1;
                while (pos < arrJson.size()) {
                    auto objStart = arrJson.find('{', pos);
                    if (objStart == std::string::npos) break;
                    auto objEnd = findMatchingBrace(arrJson, objStart);
                    if (objEnd == std::string::npos) break;
                    std::string pJson = arrJson.substr(objStart, objEnd - objStart + 1);

                    BehaviorPattern pat;
                    pat.placeCategory = jsonGetStr(pJson, "placeCategory");
                    pat.timeOfDay = jsonGetStr(pJson, "timeOfDay");
                    pat.dayType = jsonGetStr(pJson, "dayType");
                    pat.motionState = jsonGetStr(pJson, "motionState");
                    pat.actionType = jsonGetStr(pJson, "actionType");
                    pat.frequency = static_cast<int>(jsonGetNum(pJson, "frequency", 0));

                    model.topPatterns.push_back(pat);
                    pos = objEnd + 1;
                }
            }
        }
    }

    return model;
}

// ============================================================
// 社区规则 → 引擎规则 JSON
// ============================================================

std::string FederatedSync::communityRulesToEngineJson(
    const std::vector<CommunityRule>& rules) {

    std::lock_guard<std::mutex> lock(mutex_);

    std::ostringstream oss;
    oss << "[";
    bool first = true;

    for (const auto& cr : rules) {
        // 跳过低置信度或少设备的规则
        if (cr.communityConfidence < 0.5 || cr.deviceCount < 3) continue;

        if (!first) oss << ",";
        first = false;

        oss << "{";
        oss << "\"id\":\"" << escapeJson(cr.id) << "\",";
        oss << "\"name\":\"" << escapeJson(cr.name) << "\",";

        // 反匿名化条件: placeCategory → geofence (如果本地有对应围栏)
        oss << "\"conditions\":[";
        bool firstCond = true;
        for (const auto& ac : cr.conditions) {
            if (!firstCond) oss << ",";
            firstCond = false;

            if (ac.key == "placeCategory") {
                // 查找本地该类别的围栏 ID
                std::string gfId = findGeofenceByCategory(ac.value);
                if (!gfId.empty()) {
                    oss << "{\"key\":\"geofence\",\"op\":\"eq\",\"value\":\"" << escapeJson(gfId) << "\"}";
                } else {
                    // 没有对应围栏，使用 wifiGeofence
                    oss << "{\"key\":\"wifiGeofence\",\"op\":\"eq\",\"value\":\"" << escapeJson(ac.value) << "\"}";
                }
            } else {
                oss << "{\"key\":\"" << escapeJson(ac.key) << "\",";
                oss << "\"op\":\"" << escapeJson(ac.op) << "\",";
                oss << "\"value\":\"" << escapeJson(ac.value) << "\"}";
            }
        }
        oss << "],";

        oss << "\"action\":{";
        oss << "\"id\":\"" << escapeJson(cr.id) << "\",";
        oss << "\"type\":\"" << escapeJson(cr.actionType) << "\",";
        oss << "\"payload\":\"" << escapeJson(cr.actionPayload) << "\"},";

        oss << "\"priority\":0.5,";     // 低于用户自定义规则
        oss << "\"cooldownMs\":7200000,"; // 2h cooldown
        oss << "\"enabled\":true}";
    }
    oss << "]";
    return oss.str();
}

// ============================================================
// 工具方法
// ============================================================

std::string FederatedSync::getDeviceFingerprint() const {
    std::lock_guard<std::mutex> lock(mutex_);
    return deviceFingerprint_;
}

std::string FederatedSync::sha256(const std::string& input) const {
    return computeSha256(input);
}

std::string FederatedSync::escapeJson(const std::string& s) const {
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

int64_t FederatedSync::currentTimeMs() const {
    auto now = std::chrono::system_clock::now();
    auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch());
    return ms.count();
}

}  // namespace federated_sync
