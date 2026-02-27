/**
 * sleep_pattern_napi.cpp — 睡眠时间学习 NAPI 绑定
 */
#include <napi/native_api.h>
#include "sleep_pattern.h"
#include <string>

using namespace sleep_pattern;

static SleepPatternLearner g_learner;

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

static napi_value CreateBool(napi_env env, bool val) {
    napi_value result;
    napi_get_boolean(env, val, &result);
    return result;
}

static napi_value CreateInt64(napi_env env, int64_t val) {
    napi_value result;
    napi_create_int64(env, val, &result);
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

static int64_t GetInt64Prop(napi_env env, napi_value obj, const char* key, int64_t defaultVal = 0) {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;
    
    int64_t val;
    status = napi_get_value_int64(env, prop, &val);
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

static napi_value RecordMotionChange(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: snapshot");
        return nullptr;
    }
    
    MotionSnapshot snapshot;
    snapshot.state = GetStringProp(env, args[0], "state", "unknown");
    snapshot.timestamp = GetInt64Prop(env, args[0], "timestamp", 0);
    snapshot.latitude = GetDoubleProp(env, args[0], "latitude", 0);
    snapshot.longitude = GetDoubleProp(env, args[0], "longitude", 0);
    snapshot.geofence = GetStringProp(env, args[0], "geofence", "");
    
    g_learner.recordMotionChange(snapshot);
    
    return nullptr;
}

static napi_value RecordFromWearable(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: record");
        return nullptr;
    }
    
    SleepRecord record;
    record.date = GetStringProp(env, args[0], "date", "");
    record.bedtime = GetInt64Prop(env, args[0], "bedtime", 0);
    record.wakeTime = GetInt64Prop(env, args[0], "wakeTime", 0);
    record.durationMs = GetInt64Prop(env, args[0], "durationMs", 0);
    record.source = GetStringProp(env, args[0], "source", "wearable");
    
    g_learner.recordFromWearable(record);
    
    return nullptr;
}

static napi_value GetPattern(napi_env env, napi_callback_info info) {
    const SleepPattern& pattern = g_learner.getPattern();
    
    napi_value obj;
    napi_create_object(env, &obj);
    
    napi_set_named_property(env, obj, "typicalBedtime", CreateDouble(env, pattern.typicalBedtime));
    napi_set_named_property(env, obj, "typicalWakeTime", CreateDouble(env, pattern.typicalWakeTime));
    napi_set_named_property(env, obj, "sleepDurationHours", CreateDouble(env, pattern.sleepDurationHours));
    napi_set_named_property(env, obj, "confidence", CreateDouble(env, pattern.confidence));
    napi_set_named_property(env, obj, "lastUpdated", CreateInt64(env, pattern.lastUpdated));
    
    napi_value weekdays;
    napi_create_object(env, &weekdays);
    napi_set_named_property(env, weekdays, "bedtime", CreateDouble(env, pattern.weekdays.bedtime));
    napi_set_named_property(env, weekdays, "wakeTime", CreateDouble(env, pattern.weekdays.wakeTime));
    napi_set_named_property(env, weekdays, "sampleCount", CreateDouble(env, pattern.weekdays.sampleCount));
    napi_set_named_property(env, obj, "weekdays", weekdays);
    
    napi_value weekends;
    napi_create_object(env, &weekends);
    napi_set_named_property(env, weekends, "bedtime", CreateDouble(env, pattern.weekends.bedtime));
    napi_set_named_property(env, weekends, "wakeTime", CreateDouble(env, pattern.weekends.wakeTime));
    napi_set_named_property(env, weekends, "sampleCount", CreateDouble(env, pattern.weekends.sampleCount));
    napi_set_named_property(env, obj, "weekends", weekends);
    
    return obj;
}

static napi_value GetRecommendedBedtimeReminder(napi_env env, napi_callback_info info) {
    double reminder = g_learner.getRecommendedBedtimeReminder();
    return CreateDouble(env, reminder);
}

static napi_value IsNearBedtime(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Expected at least 2 arguments: hour, minute");
        return nullptr;
    }
    
    int32_t hour, minute;
    napi_get_value_int32(env, args[0], &hour);
    napi_get_value_int32(env, args[1], &minute);
    
    int marginMinutes = 30;
    if (argc >= 3) {
        napi_get_value_int32(env, args[2], &marginMinutes);
    }
    
    bool near = g_learner.isNearBedtime(hour, minute, marginMinutes);
    
    return CreateBool(env, near);
}

static napi_value Clear(napi_env env, napi_callback_info info) {
    g_learner.clear();
    return nullptr;
}

EXTERN_C_START

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"recordMotionChange", nullptr, RecordMotionChange, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recordFromWearable", nullptr, RecordFromWearable, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPattern", nullptr, GetPattern, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getRecommendedBedtimeReminder", nullptr, GetRecommendedBedtimeReminder, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isNearBedtime", nullptr, IsNearBedtime, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clear", nullptr, Clear, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module sleep_pattern_module = {
    .nm_version = 1,
    .nm_flags = NAPI_MODULE_VERSION,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "sleep_pattern",
    .nm_priv = nullptr,
    .reserved = {0},
};

EXTERN_C_END

extern "C" __attribute__((constructor)) void RegisterSleepPatternModule(void) {
    napi_module_register(&sleep_pattern_module);
}
