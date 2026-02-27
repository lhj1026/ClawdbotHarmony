/**
 * training_sync_napi.cpp — 训练数据同步 NAPI 绑定
 */
#include <napi/native_api.h>
#include "training_sync.h"
#include <string>
#include <vector>
#include <stdexcept>

using namespace training_sync;

static napi_value CreateString(napi_env env, const std::string& str) {
    napi_value result;
    napi_create_string_utf8(env, str.c_str(), str.length(), &result);
    return result;
}

static napi_value CreateDouble(napi_env env, double val) {
    napi_value result;
    napi_create_double(env, val, &result);
    return result;
}

static napi_value CreateInt32(napi_env env, int32_t val) {
    napi_value result;
    napi_create_int32(env, val, &result);
    return result;
}

static napi_value CreateInt64(napi_env env, int64_t val) {
    napi_value result;
    napi_create_int64(env, val, &result);
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

static double GetDoubleProp(napi_env env, napi_value obj, const char* key, double defaultVal = 0.0) {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;
    
    double val;
    status = napi_get_value_double(env, prop, &val);
    return (status == napi_ok) ? val : defaultVal;
}

static int32_t GetInt32Prop(napi_env env, napi_value obj, const char* key, int32_t defaultVal = 0) {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;
    
    int32_t val;
    status = napi_get_value_int32(env, prop, &val);
    return (status == napi_ok) ? val : defaultVal;
}

static int64_t GetInt64Prop(napi_env env, napi_value obj, const char* key, int64_t defaultVal = 0) {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;
    
    int64_t val;
    status = napi_get_value_int64(env, prop, &val);
    return (status == napi_ok) ? val : defaultVal;
}

static bool GetBoolProp(napi_env env, napi_value obj, const char* key, bool defaultVal = false) {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;
    
    bool val;
    status = napi_get_value_bool(env, prop, &val);
    return (status == napi_ok) ? val : defaultVal;
}

static std::string GetStringProp(napi_env env, napi_value obj, const char* key, const std::string& defaultVal = "") {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;
    
    size_t len;
    status = napi_get_value_string_utf8(env, prop, nullptr, 0, &len);
    if (status != napi_ok || len == 0) return defaultVal;
    
    std::string result(len, '\0');
    napi_get_value_string_utf8(env, prop, &result[0], len + 1, &len);
    return result;
}

// ============================================================
// NAPI 函数
// ============================================================

static napi_value Init(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    std::string deviceId = GetStringProp(env, args[0], "deviceId", "unknown");
    
    TrainingDataSync::getInstance().init(deviceId);
    
    return nullptr;
}

static napi_value RecordRuleMatch(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    napi_value data = args[0];
    
    RuleMatchData matchData;
    matchData.ruleId = GetStringProp(env, data, "ruleId", "");
    matchData.action = GetStringProp(env, data, "action", "");
    matchData.confidence = GetDoubleProp(env, data, "confidence", 0);
    matchData.timeOfDay = GetStringProp(env, data, "timeOfDay", "");
    matchData.hour = GetInt32Prop(env, data, "hour", 0);
    matchData.motionState = GetStringProp(env, data, "motionState", "");
    matchData.prevMotionState = GetStringProp(env, data, "prevMotionState", "");
    matchData.prevActivityState = GetStringProp(env, data, "prevActivityState", "");
    matchData.activityDuration = GetInt64Prop(env, data, "activityDuration", 0);
    matchData.geofence = GetStringProp(env, data, "geofence", "");
    matchData.wifiSsid = GetStringProp(env, data, "wifiSsid", "");
    matchData.batteryLevel = GetInt32Prop(env, data, "batteryLevel", 0);
    matchData.isCharging = GetBoolProp(env, data, "isCharging", false);
    
    TrainingDataSync::getInstance().recordRuleMatch(matchData);
    
    return nullptr;
}

static napi_value RecordFeedback(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    napi_value data = args[0];
    
    UserFeedbackData feedbackData;
    feedbackData.ruleId = GetStringProp(env, data, "ruleId", "");
    feedbackData.feedbackType = GetStringProp(env, data, "feedbackType", "");
    feedbackData.originalValue = GetStringProp(env, data, "originalValue", "");
    feedbackData.adjustedValue = GetStringProp(env, data, "adjustedValue", "");
    feedbackData.timeOfDay = GetStringProp(env, data, "timeOfDay", "");
    feedbackData.hour = GetInt32Prop(env, data, "hour", 0);
    feedbackData.motionState = GetStringProp(env, data, "motionState", "");
    feedbackData.prevActivityState = GetStringProp(env, data, "prevActivityState", "");
    feedbackData.activityDuration = GetInt64Prop(env, data, "activityDuration", 0);
    feedbackData.geofence = GetStringProp(env, data, "geofence", "");
    
    TrainingDataSync::getInstance().recordFeedback(feedbackData);
    
    return nullptr;
}

static napi_value RecordStateTransition(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    napi_value data = args[0];
    
    StateTransitionData transData;
    transData.prevState = GetStringProp(env, data, "prevState", "");
    transData.newState = GetStringProp(env, data, "newState", "");
    transData.duration = GetInt64Prop(env, data, "duration", 0);
    transData.timeOfDay = GetStringProp(env, data, "timeOfDay", "");
    transData.hour = GetInt32Prop(env, data, "hour", 0);
    transData.geofence = GetStringProp(env, data, "geofence", "");
    transData.wifiSsid = GetStringProp(env, data, "wifiSsid", "");
    
    TrainingDataSync::getInstance().recordStateTransition(transData);
    
    return nullptr;
}

static napi_value RecordGeofenceFeature(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    napi_value data = args[0];
    
    GeofenceFeatureData featureData;
    featureData.geofenceId = GetStringProp(env, data, "geofenceId", "");
    featureData.geofenceName = GetStringProp(env, data, "geofenceName", "");
    featureData.wifiSsid = GetStringProp(env, data, "wifiSsid", "");
    featureData.timeOfDay = GetStringProp(env, data, "timeOfDay", "");
    featureData.hour = GetInt32Prop(env, data, "hour", 0);
    featureData.duration = GetInt64Prop(env, data, "duration", 0);
    
    TrainingDataSync::getInstance().recordGeofenceFeature(featureData);
    
    return nullptr;
}

static napi_value ExportPending(napi_env env, napi_callback_info info) {
    std::string json = TrainingDataSync::getInstance().exportPendingAsJson();
    return CreateString(env, json);
}

static napi_value MarkSynced(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    napi_value idsArray = args[0];
    
    uint32_t arrayLen = 0;
    napi_get_array_length(env, idsArray, &arrayLen);
    
    std::vector<std::string> ids;
    for (uint32_t i = 0; i < arrayLen; i++) {
        napi_value elem;
        napi_get_element(env, idsArray, i, &elem);
        
        size_t len;
        napi_get_value_string_utf8(env, elem, nullptr, 0, &len);
        if (len > 0) {
            std::string id(len, '\0');
            napi_get_value_string_utf8(env, elem, &id[0], len + 1, &len);
            ids.push_back(id);
        }
    }
    
    TrainingDataSync::getInstance().markAsSynced(ids);
    
    return nullptr;
}

static napi_value CleanupSynced(napi_env env, napi_callback_info info) {
    TrainingDataSync::getInstance().cleanupSynced();
    return nullptr;
}

static napi_value GetStats(napi_env env, napi_callback_info info) {
    SyncStats stats = TrainingDataSync::getInstance().getStats();
    
    napi_value result = CreateObject(env);
    napi_set_named_property(env, result, "pending", CreateInt32(env, stats.pendingCount));
    napi_set_named_property(env, result, "synced", CreateInt32(env, stats.syncedCount));
    napi_set_named_property(env, result, "lastSync", CreateInt64(env, stats.lastSyncTime));
    napi_set_named_property(env, result, "totalRecords", CreateInt64(env, stats.totalRecords));
    
    return result;
}

static napi_value Serialize(napi_env env, napi_callback_info info) {
    std::string json = TrainingDataSync::getInstance().serialize();
    return CreateString(env, json);
}

static napi_value Deserialize(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    size_t len;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    if (len == 0) {
        return CreateBool(env, false);
    }
    
    std::string json(len, '\0');
    napi_get_value_string_utf8(env, args[0], &json[0], len + 1, &len);
    
    bool success = false;
    try {
        success = TrainingDataSync::getInstance().deserialize(json);
    } catch (const std::exception& e) {
        // Prevent native crash from corrupted data
        success = false;
    } catch (...) {
        success = false;
    }
    return CreateBool(env, success);
}

static napi_value Clear(napi_env env, napi_callback_info info) {
    TrainingDataSync::getInstance().clear();
    return nullptr;
}

static napi_value SetMaxRecords(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    int32_t maxRecords;
    napi_get_value_int32(env, args[0], &maxRecords);
    
    TrainingDataSync::getInstance().setMaxRecords(maxRecords);
    
    return nullptr;
}

static napi_value GetDeviceId(napi_env env, napi_callback_info info) {
    std::string deviceId = TrainingDataSync::getInstance().getDeviceId();
    return CreateString(env, deviceId);
}

// ============================================================
// 模块注册
// ============================================================

EXTERN_C_START

static napi_value InitModule(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"init", nullptr, Init, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recordRuleMatch", nullptr, RecordRuleMatch, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recordFeedback", nullptr, RecordFeedback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recordStateTransition", nullptr, RecordStateTransition, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recordGeofenceFeature", nullptr, RecordGeofenceFeature, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportPending", nullptr, ExportPending, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"markSynced", nullptr, MarkSynced, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"cleanupSynced", nullptr, CleanupSynced, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStats", nullptr, GetStats, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"serialize", nullptr, Serialize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"deserialize", nullptr, Deserialize, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clear", nullptr, Clear, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setMaxRecords", nullptr, SetMaxRecords, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getDeviceId", nullptr, GetDeviceId, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module addon = {
    .nm_version = NAPI_MODULE_VERSION,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = InitModule,
    .nm_modname = "training_sync",
    .nm_priv = nullptr,
    .reserved = {0},
};

EXTERN_C_END

extern "C" __attribute__((constructor)) void RegisterTrainingSyncModule(void) {
    napi_module_register(&addon);
}
