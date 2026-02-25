/**
 * federated_sync_napi.cpp — 联邦学习同步 NAPI 绑定
 *
 * ArkTS ↔ C++ 接口:
 *   init(config): void
 *   setGeofenceCategories(json): void
 *   buildModelUpdate(rulesJson, statsJson, linucbJson, patternsJson, dataPoints): string
 *   parseFederatedModel(modelJson): string  // 返回 {communityRulesJson, linucbState, ...}
 *   communityRulesToEngineJson(modelJson): string  // 返回引擎规则 JSON
 *   getDeviceFingerprint(): string
 */
#include <napi/native_api.h>
#include "federated_sync.h"
#include <string>
#include <vector>
#include <sstream>

using namespace federated_sync;

// ============================================================
// NAPI 辅助函数
// ============================================================

static napi_value CreateString(napi_env env, const std::string& str) {
    napi_value result;
    napi_create_string_utf8(env, str.c_str(), str.length(), &result);
    return result;
}

static napi_value CreateInt32(napi_env env, int32_t val) {
    napi_value result;
    napi_create_int32(env, val, &result);
    return result;
}

static napi_value CreateDouble(napi_env env, double val) {
    napi_value result;
    napi_create_double(env, val, &result);
    return result;
}

static napi_value CreateBool(napi_env env, bool val) {
    napi_value result;
    napi_get_boolean(env, val, &result);
    return result;
}

static napi_value CreateObject(napi_env env) {
    napi_value result;
    napi_create_object(env, &result);
    return result;
}

static std::string GetString(napi_env env, napi_value val) {
    size_t len = 0;
    napi_get_value_string_utf8(env, val, nullptr, 0, &len);
    if (len == 0) return "";
    std::string result(len, '\0');
    napi_get_value_string_utf8(env, val, &result[0], len + 1, &len);
    return result;
}

static std::string GetStringProp(napi_env env, napi_value obj, const char* key,
                                  const std::string& defaultVal = "") {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;
    return GetString(env, prop);
}

static int32_t GetInt32Prop(napi_env env, napi_value obj, const char* key,
                             int32_t defaultVal = 0) {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;
    int32_t val;
    status = napi_get_value_int32(env, prop, &val);
    return (status == napi_ok) ? val : defaultVal;
}

// ============================================================
// NAPI 函数
// ============================================================

/** init({deviceId: string}) */
static napi_value Init(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string deviceId = GetStringProp(env, args[0], "deviceId", "unknown");
    FederatedSync::getInstance().init(deviceId);

    return nullptr;
}

/** setGeofenceCategories(json: string)
 *  json = [{"geofenceId":"xxx","category":"home"},...]
 */
static napi_value SetGeofenceCategories(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string json = GetString(env, args[0]);

    // Parse JSON array of {geofenceId, category}
    std::vector<GeofenceCategoryEntry> entries;
    size_t pos = json.find('[');
    if (pos != std::string::npos) {
        pos++;
        while (pos < json.size()) {
            auto objStart = json.find('{', pos);
            if (objStart == std::string::npos) break;
            // Find matching }
            int depth = 1;
            size_t objEnd = objStart + 1;
            while (objEnd < json.size() && depth > 0) {
                if (json[objEnd] == '{') depth++;
                else if (json[objEnd] == '}') depth--;
                objEnd++;
            }
            std::string objJson = json.substr(objStart, objEnd - objStart);

            // Extract fields using simple search
            GeofenceCategoryEntry entry;
            // geofenceId
            auto idPos = objJson.find("\"geofenceId\"");
            if (idPos != std::string::npos) {
                auto colon = objJson.find(':', idPos);
                auto qStart = objJson.find('"', colon + 1);
                auto qEnd = objJson.find('"', qStart + 1);
                if (qStart != std::string::npos && qEnd != std::string::npos)
                    entry.geofenceId = objJson.substr(qStart + 1, qEnd - qStart - 1);
            }
            // category
            auto catPos = objJson.find("\"category\"");
            if (catPos != std::string::npos) {
                auto colon = objJson.find(':', catPos);
                auto qStart = objJson.find('"', colon + 1);
                auto qEnd = objJson.find('"', qStart + 1);
                if (qStart != std::string::npos && qEnd != std::string::npos)
                    entry.category = objJson.substr(qStart + 1, qEnd - qStart - 1);
            }

            if (!entry.geofenceId.empty() && !entry.category.empty()) {
                entries.push_back(entry);
            }
            pos = objEnd;
        }
    }

    FederatedSync::getInstance().setGeofenceCategories(entries);
    return nullptr;
}

/**
 * buildModelUpdate(rulesJson, statsJson, linucbJson, patternsJson, dataPoints)
 * patternsJson = [{"placeCategory":"home","timeOfDay":"morning","isWeekend":false,
 *                  "motionState":"stationary","actionType":"suggestion"},...]
 * Returns: FederatedModelUpdate JSON string
 */
static napi_value BuildModelUpdate(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value args[5];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string rulesJson = (argc > 0) ? GetString(env, args[0]) : "[]";
    std::string statsJson = (argc > 1) ? GetString(env, args[1]) : "{}";
    std::string linucbJson = (argc > 2) ? GetString(env, args[2]) : "";
    std::string patternsJson = (argc > 3) ? GetString(env, args[3]) : "[]";
    int32_t dataPoints = 0;
    if (argc > 4) napi_get_value_int32(env, args[4], &dataPoints);

    // Parse patterns JSON into BehaviorRecord vector
    std::vector<BehaviorRecord> records;
    size_t pos = patternsJson.find('[');
    if (pos != std::string::npos) {
        pos++;
        while (pos < patternsJson.size()) {
            auto objStart = patternsJson.find('{', pos);
            if (objStart == std::string::npos) break;
            int depth = 1;
            size_t objEnd = objStart + 1;
            while (objEnd < patternsJson.size() && depth > 0) {
                if (patternsJson[objEnd] == '{') depth++;
                else if (patternsJson[objEnd] == '}') depth--;
                objEnd++;
            }
            std::string objJson = patternsJson.substr(objStart, objEnd - objStart);

            // Simple inline parsing
            BehaviorRecord rec;
            // placeCategory
            auto p1 = objJson.find("\"placeCategory\"");
            if (p1 != std::string::npos) {
                auto c = objJson.find(':', p1); auto q1 = objJson.find('"', c + 1); auto q2 = objJson.find('"', q1 + 1);
                if (q1 != std::string::npos && q2 != std::string::npos) rec.placeCategory = objJson.substr(q1 + 1, q2 - q1 - 1);
            }
            auto p2 = objJson.find("\"timeOfDay\"");
            if (p2 != std::string::npos) {
                auto c = objJson.find(':', p2); auto q1 = objJson.find('"', c + 1); auto q2 = objJson.find('"', q1 + 1);
                if (q1 != std::string::npos && q2 != std::string::npos) rec.timeOfDay = objJson.substr(q1 + 1, q2 - q1 - 1);
            }
            auto p3 = objJson.find("\"isWeekend\"");
            if (p3 != std::string::npos) {
                auto c = objJson.find(':', p3);
                rec.isWeekend = (objJson.find("true", c) < objJson.find_first_of(",}", c + 1));
            }
            auto p4 = objJson.find("\"motionState\"");
            if (p4 != std::string::npos) {
                auto c = objJson.find(':', p4); auto q1 = objJson.find('"', c + 1); auto q2 = objJson.find('"', q1 + 1);
                if (q1 != std::string::npos && q2 != std::string::npos) rec.motionState = objJson.substr(q1 + 1, q2 - q1 - 1);
            }
            auto p5 = objJson.find("\"actionType\"");
            if (p5 != std::string::npos) {
                auto c = objJson.find(':', p5); auto q1 = objJson.find('"', c + 1); auto q2 = objJson.find('"', q1 + 1);
                if (q1 != std::string::npos && q2 != std::string::npos) rec.actionType = objJson.substr(q1 + 1, q2 - q1 - 1);
            }

            records.push_back(rec);
            pos = objEnd;
        }
    }

    std::string result = FederatedSync::getInstance().buildModelUpdate(
        rulesJson, statsJson, linucbJson, records, dataPoints);

    return CreateString(env, result);
}

/**
 * parseFederatedModel(modelJson: string): object
 * Returns: { communityRulesJson: string, linucbState: string,
 *            modelVersion: number, participantCount: number }
 */
static napi_value ParseFederatedModel(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    std::string modelJson = GetString(env, args[0]);
    FederatedModel model = FederatedSync::getInstance().parseFederatedModel(modelJson);

    // Convert community rules to engine JSON
    std::string engineJson = FederatedSync::getInstance().communityRulesToEngineJson(
        model.communityRules);

    napi_value result = CreateObject(env);
    napi_set_named_property(env, result, "communityRulesJson", CreateString(env, engineJson));
    napi_set_named_property(env, result, "linucbState", CreateString(env, model.linucbState));
    napi_set_named_property(env, result, "modelVersion", CreateInt32(env, model.modelVersion));
    napi_set_named_property(env, result, "participantCount", CreateInt32(env, model.participantCount));
    napi_set_named_property(env, result, "communityRuleCount",
        CreateInt32(env, static_cast<int>(model.communityRules.size())));

    return result;
}

/** getDeviceFingerprint(): string */
static napi_value GetDeviceFingerprint(napi_env env, napi_callback_info info) {
    return CreateString(env, FederatedSync::getInstance().getDeviceFingerprint());
}

// ============================================================
// 模块注册
// ============================================================

EXTERN_C_START

static napi_value InitModule(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setGeofenceCategories", nullptr, SetGeofenceCategories, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"buildModelUpdate", nullptr, BuildModelUpdate, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"parseFederatedModel", nullptr, ParseFederatedModel, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDeviceFingerprint", nullptr, GetDeviceFingerprint, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module addon = {
    .nm_version = NAPI_MODULE_VERSION,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = InitModule,
    .nm_modname = "federated_sync",
    .nm_priv = nullptr,
    .reserved = {0},
};

EXTERN_C_END

extern "C" __attribute__((constructor)) void RegisterFederatedSyncModule(void) {
    napi_module_register(&addon);
}
