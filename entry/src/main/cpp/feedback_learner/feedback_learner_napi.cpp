/**
 * feedback_learner_napi.cpp — 用户反馈学习 NAPI 绑定
 */
#include <napi/native_api.h>
#include "feedback_learner.h"
#include <string>

using namespace feedback_learner;

static FeedbackLearner g_learner;

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

static FeedbackContext ParseContext(napi_env env, napi_value obj) {
    FeedbackContext ctx;
    ctx.ruleId = GetStringProp(env, obj, "ruleId", "");
    ctx.ruleName = GetStringProp(env, obj, "ruleName", "");
    ctx.feedbackTime = GetInt64Prop(env, obj, "feedbackTime", 0);
    ctx.hour = GetInt32Prop(env, obj, "hour", 0);
    ctx.minute = GetInt32Prop(env, obj, "minute", 0);
    ctx.timeOfDay = GetStringProp(env, obj, "timeOfDay", "");
    ctx.isWeekend = GetBoolProp(env, obj, "isWeekend", false);
    ctx.latitude = GetDoubleProp(env, obj, "latitude", 0);
    ctx.longitude = GetDoubleProp(env, obj, "longitude", 0);
    ctx.geofence = GetStringProp(env, obj, "geofence", "");
    ctx.wifiSsid = GetStringProp(env, obj, "wifiSsid", "");
    ctx.motionState = GetStringProp(env, obj, "motionState", "");
    ctx.activityContext = GetStringProp(env, obj, "activityContext", "");
    ctx.payload = GetStringProp(env, obj, "payload", "");
    return ctx;
}

static napi_value RecordSimpleFeedback(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 3) {
        napi_throw_error(env, nullptr, "Expected 3 arguments: ruleId, feedbackType, context");
        return nullptr;
    }
    
    std::string ruleId = GetStringProp(env, args[0], "ruleId");
    if (ruleId.empty()) {
        size_t len;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        ruleId.resize(len);
        napi_get_value_string_utf8(env, args[0], &ruleId[0], len + 1, &len);
    }
    
    int32_t typeInt;
    napi_get_value_int32(env, args[1], &typeInt);
    FeedbackType type = static_cast<FeedbackType>(typeInt);
    
    FeedbackContext context = ParseContext(env, args[2]);
    
    g_learner.recordSimpleFeedback(ruleId, type, context);
    
    return nullptr;
}

static napi_value RecordAdjustment(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value args[3];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 3) {
        napi_throw_error(env, nullptr, "Expected 3 arguments: ruleId, context, adjustment");
        return nullptr;
    }
    
    std::string ruleId = GetStringProp(env, args[0], "ruleId");
    if (ruleId.empty()) {
        size_t len;
        napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
        ruleId.resize(len);
        napi_get_value_string_utf8(env, args[0], &ruleId[0], len + 1, &len);
    }
    
    FeedbackContext context = ParseContext(env, args[1]);
    
    AdjustmentValue adjustment;
    adjustment.key = GetStringProp(env, args[2], "key", "");
    adjustment.originalValue = GetDoubleProp(env, args[2], "originalValue", 0);
    adjustment.adjustedValue = GetDoubleProp(env, args[2], "adjustedValue", 0);
    adjustment.unit = GetStringProp(env, args[2], "unit", "");
    
    g_learner.recordAdjustment(ruleId, context, adjustment);
    
    return nullptr;
}

static napi_value GetPreference(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: ruleId");
        return nullptr;
    }
    
    size_t len;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    std::string ruleId(len, '\0');
    napi_get_value_string_utf8(env, args[0], &ruleId[0], len + 1, &len);
    
    const RulePreference* pref = g_learner.getPreference(ruleId);
    
    if (!pref) {
        napi_value nullVal;
        napi_get_null(env, &nullVal);
        return nullVal;
    }
    
    napi_value obj;
    napi_create_object(env, &obj);
    
    napi_set_named_property(env, obj, "ruleId", CreateString(env, pref->ruleId));
    napi_set_named_property(env, obj, "preferredHour", CreateDouble(env, pref->preferredHour));
    napi_set_named_property(env, obj, "preferredMinute", CreateDouble(env, pref->preferredMinute));
    napi_set_named_property(env, obj, "hourAdjustment", CreateDouble(env, pref->hourAdjustment));
    napi_set_named_property(env, obj, "confidence", CreateDouble(env, pref->confidence));
    napi_set_named_property(env, obj, "usefulCount", CreateInt32(env, pref->usefulCount));
    napi_set_named_property(env, obj, "inaccurateCount", CreateInt32(env, pref->inaccurateCount));
    napi_set_named_property(env, obj, "dismissCount", CreateInt32(env, pref->dismissCount));
    napi_set_named_property(env, obj, "adjustCount", CreateInt32(env, pref->adjustCount));
    napi_set_named_property(env, obj, "lastFeedbackTime", CreateInt64(env, pref->lastFeedbackTime));
    
    return obj;
}

static napi_value GetAdjustedHour(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Expected 2 arguments: ruleId, originalHour");
        return nullptr;
    }
    
    size_t len;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    std::string ruleId(len, '\0');
    napi_get_value_string_utf8(env, args[0], &ruleId[0], len + 1, &len);
    
    double originalHour;
    napi_get_value_double(env, args[1], &originalHour);
    
    double adjusted = g_learner.getAdjustedHour(ruleId, originalHour);
    
    return CreateDouble(env, adjusted);
}

static napi_value ExportPreferences(napi_env env, napi_callback_info info) {
    std::string json = g_learner.exportPreferences();
    return CreateString(env, json);
}

static napi_value ClearPreference(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: ruleId");
        return nullptr;
    }
    
    size_t len;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    std::string ruleId(len, '\0');
    napi_get_value_string_utf8(env, args[0], &ruleId[0], len + 1, &len);
    
    g_learner.clearPreference(ruleId);
    
    return nullptr;
}

EXTERN_C_START

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"recordSimpleFeedback", nullptr, RecordSimpleFeedback, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"recordAdjustment", nullptr, RecordAdjustment, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getPreference", nullptr, GetPreference, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAdjustedHour", nullptr, GetAdjustedHour, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"exportPreferences", nullptr, ExportPreferences, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clearPreference", nullptr, ClearPreference, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module feedback_learner_module = {
    .nm_version = 1,
    .nm_flags = NAPI_MODULE_VERSION,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "feedback_learner",
    .nm_priv = nullptr,
    .reserved = {0},
};

EXTERN_C_END

extern "C" __attribute__((constructor)) void RegisterFeedbackLearnerModule(void) {
    napi_module_register(&feedback_learner_module);
}
