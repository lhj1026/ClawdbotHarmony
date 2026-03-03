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
 *   pushEvent(eventJson: string): void      // push event to buffer
 *   setLimits(limitsJson: string): void      // configure rate limits
 */
#include <napi/native_api.h>
#include "context_engine.h"
#include "stream_mlp.h"
#include "state_transition.h"
#include <string>
#include <memory>
#include <sstream>
#include <chrono>

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
    return context_engine::safe_stod(json.substr(pos), defVal);
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

// ── NAPI 函数前向声明（供 napi_property_descriptor desc[] 引用）──────────
static napi_value RecommenderInit   (napi_env env, napi_callback_info info);
static napi_value RecommenderPredict(napi_env env, napi_callback_info info);
static napi_value RecommenderReward (napi_env env, napi_callback_info info);
static napi_value RecommenderSave   (napi_env env, napi_callback_info info);
static napi_value RecommenderStats  (napi_env env, napi_callback_info info);

// NAPI functions

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
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 2) {
        napi_throw_error(env, nullptr, "updateReward requires actionId and reward");
        return nullptr;
    }
    auto actionId = napiGetString(env, args[0]);
    double reward;
    napi_get_value_double(env, args[1], &reward);

    // Always update MAB (backward compat)
    g_engine.mab().update(actionId, reward);

    // If context provided, also update LinUCB
    if (argc >= 3) {
        auto contextJson = napiGetString(env, args[2]);
        auto ctx = parseContextMap(contextJson);
        g_engine.linucb().update(actionId, reward, ctx);
    }

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

// Parse simple JSON array of strings: ["id1","id2",...]
static std::vector<std::string> parseStringArray(const std::string& json) {
    std::vector<std::string> result;
    size_t pos = 0;
    while (pos < json.size()) {
        auto qs = json.find('"', pos);
        if (qs == std::string::npos) break;
        auto qe = json.find('"', qs + 1);
        if (qe == std::string::npos) break;
        result.push_back(json.substr(qs + 1, qe - qs - 1));
        pos = qe + 1;
    }
    return result;
}

static napi_value SelectAction(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "selectAction requires JSON array of action IDs");
        return nullptr;
    }

    auto actionIdsJson = napiGetString(env, args[0]);
    auto actionIds = parseStringArray(actionIdsJson);

    int idx;
    if (argc >= 2) {
        // Context provided → use LinUCB
        auto contextJson = napiGetString(env, args[1]);
        auto ctx = parseContextMap(contextJson);
        idx = g_engine.linucb().select(actionIds, ctx);
    } else {
        // No context → fallback to epsilon-greedy MAB
        idx = g_engine.mab().select(actionIds);
    }

    napi_value val;
    napi_create_int32(env, idx, &val);
    return val;
}

static napi_value ExportLinUCB(napi_env env, napi_callback_info info) {
    return napiString(env, g_engine.linucb().exportJson());
}

static napi_value ImportLinUCB(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullptr;
    auto json = napiGetString(env, args[0]);
    g_engine.linucb().importJson(json);
    return nullptr;
}

static napi_value PushEvent(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "pushEvent requires a JSON string");
        return nullptr;
    }

    auto json = napiGetString(env, args[0]);

    context_engine::ContextEvent event;
    event.eventType = jsonGetStr(json, "eventType");
    event.timestampMs = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();

    // Parse context snapshot if present
    auto ctxPos = json.find("\"context\"");
    if (ctxPos != std::string::npos) {
        auto bracePos = json.find('{', ctxPos);
        if (bracePos != std::string::npos) {
            int depth = 1;
            size_t end = bracePos + 1;
            while (end < json.size() && depth > 0) {
                if (json[end] == '{') depth++;
                else if (json[end] == '}') depth--;
                end++;
            }
            std::string ctxJson = json.substr(bracePos, end - bracePos);
            event.context = parseContextMap(ctxJson);
        }
    }

    g_engine.pushEvent(event);
    return nullptr;
}

static napi_value SetLimits(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_throw_error(env, nullptr, "setLimits requires a JSON string");
        return nullptr;
    }

    auto json = napiGetString(env, args[0]);

    context_engine::RateLimits limits;
    limits.categoryCooldownCount = static_cast<int>(
        jsonGetNum(json, "categoryCooldownCount", 3));
    limits.categoryCooldownWindowMs = static_cast<int64_t>(
        jsonGetNum(json, "categoryCooldownWindowMs", 600000));
    limits.globalMaxPerHour = static_cast<int>(
        jsonGetNum(json, "globalMaxPerHour", 10));

    g_engine.setLimits(limits);
    return nullptr;
}

// ============================================================
// Stream RL NAPI functions
// ============================================================

static napi_value TrainStreamRL(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) {
        napi_throw_error(env, nullptr, "trainStreamRL requires actionId, reward, contextJson");
        return nullptr;
    }

    auto actionId = napiGetString(env, args[0]);
    double reward;
    napi_get_value_double(env, args[1], &reward);
    auto contextJson = napiGetString(env, args[2]);

    auto ctx = parseContextMap(contextJson);
    double features[context_engine::STREAM_FEAT_DIM];
    context_engine::StreamRLEngine::buildFeatures(ctx, features);
    g_engine.streamRL().trainArm(actionId, features, reward);

    return nullptr;
}

static napi_value ExportStreamRL(napi_env env, napi_callback_info info) {
    return napiString(env, g_engine.streamRL().exportJson());
}

static napi_value ImportStreamRL(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullptr;
    auto json = napiGetString(env, args[0]);
    g_engine.streamRL().importJson(json);
    return nullptr;
}

static napi_value GetStreamRLStats(napi_env env, napi_callback_info info) {
    return napiString(env, g_engine.streamRL().getSummaryJson());
}

static napi_value GetStreamRLArmSamples(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) {
        napi_value val;
        napi_create_int32(env, 0, &val);
        return val;
    }
    auto actionId = napiGetString(env, args[0]);
    int samples = g_engine.streamRL().getArmSamples(actionId);
    napi_value val;
    napi_create_int32(env, samples, &val);
    return val;
}

// ============================================================
// State Transition NAPI functions
// ============================================================

static napi_value GetTransitionInfo(napi_env env, napi_callback_info info) {
    return napiString(env, g_engine.transitionTracker().getTransitionJson());
}

static napi_value ExportTransitionState(napi_env env, napi_callback_info info) {
    return napiString(env, g_engine.transitionTracker().exportJson());
}

static napi_value ImportTransitionState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return nullptr;
    auto json = napiGetString(env, args[0]);
    g_engine.transitionTracker().importJson(json);
    return nullptr;
}

// Module registration

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
        {"exportLinUCB", nullptr, ExportLinUCB, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"importLinUCB", nullptr, ImportLinUCB, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"pushEvent",       nullptr, PushEvent,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setLimits",       nullptr, SetLimits,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"trainStreamRL",        nullptr, TrainStreamRL,        nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportStreamRL",       nullptr, ExportStreamRL,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"importStreamRL",       nullptr, ImportStreamRL,       nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStreamRLStats",     nullptr, GetStreamRLStats,     nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStreamRLArmSamples", nullptr, GetStreamRLArmSamples, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getTransitionInfo",      nullptr, GetTransitionInfo,      nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportTransitionState",  nullptr, ExportTransitionState,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"importTransitionState",  nullptr, ImportTransitionState,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recommenderInit",    nullptr, RecommenderInit,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recommenderPredict", nullptr, RecommenderPredict, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recommenderReward",  nullptr, RecommenderReward,  nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recommenderSave",    nullptr, RecommenderSave,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recommenderStats",   nullptr, RecommenderStats,   nullptr, nullptr, nullptr, napi_default, nullptr},
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

// ============================================================
// ActionRecommender — MLP + LinUCB 推荐器 NAPI 桥接
// ============================================================

#define HAVE_ACTION_WEIGHTS
#include "action_weights.h"
#include "action_recommender.h"

// 全局推荐器单例（懒初始化）
static context_engine::ActionRecommender* g_recommender = nullptr;
static std::mutex g_rec_mu;
static int g_reward_count = 0;
static const int SAVE_INTERVAL = 5;  // 每5次反馈自动保存
static std::string g_save_path;      // ArkTS 初始化时设置

static context_engine::ActionRecommender& getRecommender() {
    if (!g_recommender) {
        std::lock_guard<std::mutex> lk(g_rec_mu);
        if (!g_recommender) g_recommender = new context_engine::ActionRecommender();
    }
    return *g_recommender;
}

/**
 * recommenderInit(savePath: string): void
 * 初始化推荐器，加载持久化 UCB 参数。App 启动时调用。
 */
static napi_value RecommenderInit(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc >= 1) {
        g_save_path = napiGetString(env, args[0]);
        std::lock_guard<std::mutex> lk(g_rec_mu);
        getRecommender().load(g_save_path);  // 如果文件不存在静默忽略
    }
    return nullptr;
}

/**
 * recommenderPredict(stateCode: string, topK?: number): string
 * 返回 JSON 数组: [{code:"B7", name:"检查行程/车票", score:0.85}, ...]
 */
static napi_value RecommenderPredict(napi_env env, napi_callback_info info) {
    size_t argc = 2; napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 1) return napiString(env, "[]");

    std::string stateCode = napiGetString(env, args[0]);
    int topK = 3;
    if (argc >= 2) {
        int32_t k; napi_get_value_int32(env, args[1], &k); topK = k;
    }

    // 解码 StateCode → PhysicalState（enum class : char，需要 static_cast）
    context_engine::PhysicalState state;
    if (stateCode.size() >= 7) {
        state.time     = static_cast<context_engine::TimeSlot> (stateCode[0]);
        state.location = static_cast<context_engine::Location> (stateCode[1]);
        state.motion   = static_cast<context_engine::Motion>   (stateCode[2]);
        state.phone    = static_cast<context_engine::PhonePos>  (stateCode[3]);
        state.light    = static_cast<context_engine::Light>    (stateCode[4]);
        state.sound    = static_cast<context_engine::Sound>    (stateCode[5]);
        state.dayType  = static_cast<context_engine::DayType>  (stateCode[6]);
    }

    auto recs = getRecommender().recommend(state, topK);

    std::ostringstream oss;
    oss << "[";
    for (size_t i = 0; i < recs.size(); ++i) {
        if (i > 0) oss << ",";
        oss << "{\"code\":\"" << recs[i].code << "\""
            << ",\"name\":\"" << recs[i].name << "\""
            << ",\"score\":" << std::fixed << std::setprecision(4) << recs[i].score
            << ",\"mlpProb\":" << std::fixed << std::setprecision(4) << recs[i].mlp_prob
            << "}";
    }
    oss << "]";
    return napiString(env, oss.str());
}

/**
 * recommenderReward(stateCode: string, actionCode: string, reward: number): void
 * reward: 1.0=接受, 0.5=中性, 0.0=拒绝
 * 每 SAVE_INTERVAL 次自动保存到 savePath
 */
static napi_value RecommenderReward(napi_env env, napi_callback_info info) {
    size_t argc = 3; napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    if (argc < 3) return nullptr;

    std::string stateCode   = napiGetString(env, args[0]);
    std::string actionCode  = napiGetString(env, args[1]);
    double rewardVal = 0.0;
    napi_get_value_double(env, args[2], &rewardVal);

    // 解码 PhysicalState（enum class : char，需要 static_cast）
    context_engine::PhysicalState state;
    if (stateCode.size() >= 7) {
        state.time     = static_cast<context_engine::TimeSlot> (stateCode[0]);
        state.location = static_cast<context_engine::Location> (stateCode[1]);
        state.motion   = static_cast<context_engine::Motion>   (stateCode[2]);
        state.phone    = static_cast<context_engine::PhonePos>  (stateCode[3]);
        state.light    = static_cast<context_engine::Light>    (stateCode[4]);
        state.sound    = static_cast<context_engine::Sound>    (stateCode[5]);
        state.dayType  = static_cast<context_engine::DayType>  (stateCode[6]);
    }

    int actIdx = context_engine::actionIndex(actionCode);
    if (actIdx >= 0) {
        getRecommender().reward(state, actIdx, static_cast<float>(rewardVal));
        // 自动保存
        std::lock_guard<std::mutex> lk(g_rec_mu);
        ++g_reward_count;
        if (!g_save_path.empty() && g_reward_count % SAVE_INTERVAL == 0) {
            getRecommender().save(g_save_path);
        }
    }
    return nullptr;
}

/**
 * recommenderSave(path?: string): void
 * 立即保存 UCB 参数（App 退到后台时调用）
 */
static napi_value RecommenderSave(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    std::string path = (argc >= 1) ? napiGetString(env, args[0]) : g_save_path;
    if (!path.empty()) getRecommender().save(path);
    return nullptr;
}

/**
 * recommenderStats(): string
 * 返回 JSON: [{code:"B7", updates:5, avgReward:0.8}, ...]
 */
static napi_value RecommenderStats(napi_env env, napi_callback_info info) {
    auto stats = getRecommender().stats();
    std::ostringstream oss; oss << "[";
    for (size_t i = 0; i < stats.size(); ++i) {
        if (i > 0) oss << ",";
        oss << "{\"code\":\"" << stats[i].code << "\""
            << ",\"updates\":" << stats[i].updates
            << ",\"avgReward\":" << std::fixed << std::setprecision(3) << stats[i].avgReward << "}";
    }
    oss << "]"; return napiString(env, oss.str());
}
