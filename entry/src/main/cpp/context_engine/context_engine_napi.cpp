/**
 * context_engine_napi.cpp — NAPI bridge: ArkTS ↔ C++ 规则引擎
 *
 * Exposed functions:
 *   loadRules(rulesJson: string): boolean
 *   addRule(ruleJson: string): boolean
 *   removeRule(ruleId: string): boolean
 *   evaluate(contextJson: string, maxResults?: number): string  // returns JSON
 *   updateReward(actionId: string, reward: number): void
 *   getStats(): string  // MAB stats as JSON
 *   loadStats(statsJson: string): void
 *   getRuleCount(): number
 *   exportRules(): string
 */
#include <napi/native_api.h>
#include "context_engine.h"
#include <string>
#include <memory>
#include <sstream>

// Simple JSON parsing helpers (no external deps)
// For MVP we use a minimal approach — production could use nlohmann/json

namespace {

context_engine::RuleEngine g_engine;

std::string napiGetString(napi_env env, napi_value val) {
    size_t len = 0;
    napi_get_value_string_utf8(env, val, nullptr, 0, &len);
    std::string s(len, '\0');
    napi_get_value_string_utf8(env, val, &s[0], len + 1, &len);
    return s;
}

napi_value napiString(napi_env env, const std::string& s) {
    napi_value val;
    napi_create_string_utf8(env, s.c_str(), s.size(), &val);
    return val;
}

napi_value napiBool(napi_env env, bool b) {
    napi_value val;
    napi_get_boolean(env, b, &val);
    return val;
}

// Minimal JSON string extractor: find "key":"value" pattern
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

double jsonGetNum(const std::string& json, const std::string& key, double defVal) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return defVal;
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return defVal;
    pos++;
    while (pos < json.size() && (json[pos] == ' ' || json[pos] == '\t')) pos++;
    try { return std::stod(json.substr(pos)); } catch (...) { return defVal; }
}

bool jsonGetBool(const std::string& json, const std::string& key, bool defVal) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return defVal;
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return defVal;
    auto rest = json.substr(pos + 1);
    if (rest.find("true") < rest.find("false")) return true;
    if (rest.find("false") != std::string::npos) return false;
    return defVal;
}

// Parse a single rule from a JSON object substring
context_engine::Rule parseRule(const std::string& json) {
    context_engine::Rule rule;
    rule.id = jsonGetStr(json, "id");
    rule.name = jsonGetStr(json, "name");
    rule.priority = jsonGetNum(json, "priority", 1.0);
    rule.cooldownMs = static_cast<int64_t>(jsonGetNum(json, "cooldownMs", 0));
    rule.enabled = jsonGetBool(json, "enabled", true);

    // Parse action
    rule.action.id = jsonGetStr(json, "actionId");
    if (rule.action.id.empty()) {
        // Try nested action object
        auto actionPos = json.find("\"action\"");
        if (actionPos != std::string::npos) {
            auto bracePos = json.find('{', actionPos);
            if (bracePos != std::string::npos) {
                int depth = 1;
                size_t end = bracePos + 1;
                while (end < json.size() && depth > 0) {
                    if (json[end] == '{') depth++;
                    else if (json[end] == '}') depth--;
                    end++;
                }
                std::string actionJson = json.substr(bracePos, end - bracePos);
                rule.action.id = jsonGetStr(actionJson, "id");
                rule.action.type = jsonGetStr(actionJson, "type");
                rule.action.payload = jsonGetStr(actionJson, "payload");
            }
        }
    }

    // Parse conditions array
    auto condPos = json.find("\"conditions\"");
    if (condPos != std::string::npos) {
        auto arrStart = json.find('[', condPos);
        if (arrStart != std::string::npos) {
            // Find each {...} object in the array
            size_t pos = arrStart + 1;
            while (pos < json.size()) {
                auto objStart = json.find('{', pos);
                if (objStart == std::string::npos) break;
                int depth = 1;
                size_t objEnd = objStart + 1;
                while (objEnd < json.size() && depth > 0) {
                    if (json[objEnd] == '{') depth++;
                    else if (json[objEnd] == '}') depth--;
                    objEnd++;
                }
                std::string condJson = json.substr(objStart, objEnd - objStart);
                context_engine::Condition cond;
                cond.key = jsonGetStr(condJson, "key");
                cond.op = jsonGetStr(condJson, "op");
                cond.value = jsonGetStr(condJson, "value");
                if (!cond.key.empty()) {
                    rule.conditions.push_back(cond);
                }
                pos = objEnd;
                // Check if we hit ] (end of array)
                auto nextBrace = json.find_first_of("[]{}", pos);
                if (nextBrace != std::string::npos && json[nextBrace] == ']') break;
            }
        }
    }

    return rule;
}

// Parse JSON array of rules
std::vector<context_engine::Rule> parseRulesArray(const std::string& json) {
    std::vector<context_engine::Rule> rules;
    size_t pos = json.find('[');
    if (pos == std::string::npos) {
        // Single rule object
        rules.push_back(parseRule(json));
        return rules;
    }

    pos++;
    while (pos < json.size()) {
        auto objStart = json.find('{', pos);
        if (objStart == std::string::npos) break;
        // Find matching closing brace (handling nesting)
        int depth = 1;
        size_t objEnd = objStart + 1;
        while (objEnd < json.size() && depth > 0) {
            if (json[objEnd] == '{') depth++;
            else if (json[objEnd] == '}') depth--;
            objEnd++;
        }
        std::string ruleJson = json.substr(objStart, objEnd - objStart);
        rules.push_back(parseRule(ruleJson));
        pos = objEnd;
    }
    return rules;
}

// Parse context JSON object into ContextMap
context_engine::ContextMap parseContextMap(const std::string& json) {
    context_engine::ContextMap ctx;
    // Simple parser: find all "key":"value" pairs
    size_t pos = 0;
    while (pos < json.size()) {
        auto keyStart = json.find('"', pos);
        if (keyStart == std::string::npos) break;
        auto keyEnd = json.find('"', keyStart + 1);
        if (keyEnd == std::string::npos) break;

        std::string key = json.substr(keyStart + 1, keyEnd - keyStart - 1);

        auto colon = json.find(':', keyEnd + 1);
        if (colon == std::string::npos) break;

        // Skip whitespace
        size_t valStart = colon + 1;
        while (valStart < json.size() && (json[valStart] == ' ' || json[valStart] == '\t')) valStart++;

        if (valStart >= json.size()) break;

        std::string value;
        if (json[valStart] == '"') {
            // String value
            auto valEnd = json.find('"', valStart + 1);
            if (valEnd == std::string::npos) break;
            value = json.substr(valStart + 1, valEnd - valStart - 1);
            pos = valEnd + 1;
        } else {
            // Number/bool value
            auto valEnd = json.find_first_of(",}]", valStart);
            if (valEnd == std::string::npos) valEnd = json.size();
            value = json.substr(valStart, valEnd - valStart);
            // Trim whitespace
            auto ws = value.find_last_not_of(" \t\n\r");
            if (ws != std::string::npos) value = value.substr(0, ws + 1);
            pos = valEnd;
        }

        if (!key.empty()) {
            ctx[key] = value;
        }
    }
    return ctx;
}

}  // namespace

// ============================================================
// NAPI functions
// ============================================================

static napi_value LoadRules(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "loadRules requires a JSON string");
        return nullptr;
    }
    auto json = napiGetString(env, args[0]);
    auto rules = parseRulesArray(json);
    bool ok = g_engine.loadRules(rules);
    return napiBool(env, ok);
}

static napi_value AddRule(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "addRule requires a JSON string");
        return nullptr;
    }
    auto json = napiGetString(env, args[0]);
    auto rule = parseRule(json);
    bool ok = g_engine.addRule(rule);
    return napiBool(env, ok);
}

static napi_value RemoveRule(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "removeRule requires a rule ID");
        return nullptr;
    }
    auto ruleId = napiGetString(env, args[0]);
    bool ok = g_engine.removeRule(ruleId);
    return napiBool(env, ok);
}

static napi_value Evaluate(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "evaluate requires a context JSON string");
        return nullptr;
    }

    auto contextJson = napiGetString(env, args[0]);
    int maxResults = 5;
    if (argc > 1) {
        napi_get_value_int32(env, args[1], &maxResults);
    }

    auto ctx = parseContextMap(contextJson);
    auto results = g_engine.evaluate(ctx, maxResults);

    // Build JSON result
    std::ostringstream ss;
    ss << "[";
    for (size_t i = 0; i < results.size(); i++) {
        if (i > 0) ss << ",";
        ss << "{\"ruleId\":\"" << results[i].ruleId
           << "\",\"confidence\":" << results[i].confidence
           << ",\"action\":{\"id\":\"" << results[i].action.id
           << "\",\"type\":\"" << results[i].action.type
           << "\",\"payload\":\"" << results[i].action.payload << "\"}}";
    }
    ss << "]";

    return napiString(env, ss.str());
}

static napi_value UpdateReward(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, nullptr, "updateReward requires actionId and reward");
        return nullptr;
    }
    auto actionId = napiGetString(env, args[0]);
    double reward;
    napi_get_value_double(env, args[1], &reward);
    g_engine.mab().update(actionId, reward);
    return nullptr;
}

static napi_value GetStats(napi_env env, napi_callback_info info) {
    auto stats = g_engine.mab().getStats();
    std::ostringstream ss;
    ss << "{";
    bool first = true;
    for (const auto& [id, arm] : stats) {
        if (!first) ss << ",";
        first = false;
        ss << "\"" << id << "\":{\"pulls\":" << arm.pulls
           << ",\"totalReward\":" << arm.totalReward
           << ",\"avgReward\":" << arm.avgReward() << "}";
    }
    ss << "}";
    return napiString(env, ss.str());
}

static napi_value LoadStats(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullptr;

    auto json = napiGetString(env, args[0]);
    // Minimal parse of stats JSON
    std::unordered_map<std::string, context_engine::ArmStats> stats;
    // TODO: proper parsing for loadStats
    g_engine.mab().loadStats(stats);
    return nullptr;
}

static napi_value GetRuleCount(napi_env env, napi_callback_info info) {
    napi_value val;
    napi_create_int32(env, static_cast<int>(g_engine.ruleCount()), &val);
    return val;
}

static napi_value ExportRules(napi_env env, napi_callback_info info) {
    return napiString(env, g_engine.exportRulesJson());
}

static napi_value SelectAction(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "selectAction requires JSON array of action IDs");
        return nullptr;
    }
    // Parse simple JSON array of strings: ["id1","id2",...]
    auto json = napiGetString(env, args[0]);
    std::vector<std::string> actionIds;
    size_t pos = 0;
    while (pos < json.size()) {
        auto qs = json.find('"', pos);
        if (qs == std::string::npos) break;
        auto qe = json.find('"', qs + 1);
        if (qe == std::string::npos) break;
        actionIds.push_back(json.substr(qs + 1, qe - qs - 1));
        pos = qe + 1;
    }

    int idx = g_engine.mab().select(actionIds);
    napi_value val;
    napi_create_int32(env, idx, &val);
    return val;
}

// ============================================================
// Module registration
// ============================================================

EXTERN_C_START
static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"loadRules",    nullptr, LoadRules,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"addRule",      nullptr, AddRule,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"removeRule",   nullptr, RemoveRule,   nullptr, nullptr, nullptr, napi_default, nullptr},
        {"evaluate",     nullptr, Evaluate,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"updateReward", nullptr, UpdateReward, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"selectAction", nullptr, SelectAction, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStats",     nullptr, GetStats,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"loadStats",    nullptr, LoadStats,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRuleCount", nullptr, GetRuleCount, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportRules",  nullptr, ExportRules,  nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}
EXTERN_C_END

static napi_module contextEngineModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "context_engine",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterContextEngineModule(void) {
    napi_module_register(&contextEngineModule);
}
