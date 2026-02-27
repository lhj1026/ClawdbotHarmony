/**
 * place_signal_learner_napi.cpp — 地点信号学习 NAPI 绑定
 */
#include <napi/native_api.h>
#include "place_signal_learner.h"
#include <vector>
#include <string>

using namespace place_learner;

static PlaceSignalLearner g_learner;

static napi_value CreateString(napi_env env, const std::string& str) {
    napi_value result;
    napi_create_string_utf8(env, str.c_str(), str.length(), &result);
    return result;
}

static napi_value CreateBool(napi_env env, bool val) {
    napi_value result;
    napi_get_boolean(env, val, &result);
    return result;
}

static napi_value CreateInt32(napi_env env, int32_t val) {
    napi_value result;
    napi_create_int32(env, val, &result);
    return result;
}

static std::string GetStringArg(napi_env env, napi_value arg, const std::string& defaultVal = "") {
    if (arg == nullptr) return defaultVal;
    
    napi_valuetype type;
    napi_typeof(env, arg, &type);
    if (type != napi_string) return defaultVal;
    
    size_t len;
    napi_status status = napi_get_value_string_utf8(env, arg, nullptr, 0, &len);
    if (status != napi_ok || len == 0) return defaultVal;
    
    std::string result(len, '\0');
    napi_get_value_string_utf8(env, arg, &result[0], len + 1, &len);
    return result;
}

static napi_value Learn(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Expected at least 2 arguments: placeId, wifiSsid");
        return nullptr;
    }
    
    std::string placeId = GetStringArg(env, args[0]);
    std::string wifiSsid = GetStringArg(env, args[1]);
    std::string btDevice = argc >= 3 ? GetStringArg(env, args[2]) : "";
    std::string cellId = argc >= 4 ? GetStringArg(env, args[3]) : "";
    
    bool learned = g_learner.learn(placeId, wifiSsid, btDevice, cellId);
    
    return CreateBool(env, learned);
}

static napi_value MatchesWifi(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Expected 2 arguments: placeId, wifiSsid");
        return nullptr;
    }
    
    std::string placeId = GetStringArg(env, args[0]);
    std::string wifiSsid = GetStringArg(env, args[1]);
    
    bool matches = g_learner.matchesWifi(placeId, wifiSsid);
    
    return CreateBool(env, matches);
}

static napi_value MatchesCellId(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Expected 2 arguments: placeId, cellId");
        return nullptr;
    }
    
    std::string placeId = GetStringArg(env, args[0]);
    std::string cellId = GetStringArg(env, args[1]);
    
    bool matches = g_learner.matchesCellId(placeId, cellId);
    
    return CreateBool(env, matches);
}

static napi_value StringVectorToArray(napi_env env, const std::vector<std::string>& vec) {
    napi_value arr;
    napi_create_array_with_length(env, vec.size(), &arr);
    
    for (size_t i = 0; i < vec.size(); i++) {
        napi_set_element(env, arr, i, CreateString(env, vec[i]));
    }
    
    return arr;
}

static napi_value FindPlacesByWifi(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: wifiSsid");
        return nullptr;
    }
    
    std::string wifiSsid = GetStringArg(env, args[0]);
    std::vector<std::string> places = g_learner.findPlacesByWifi(wifiSsid);
    
    return StringVectorToArray(env, places);
}

static napi_value FindPlacesByCellId(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: cellId");
        return nullptr;
    }
    
    std::string cellId = GetStringArg(env, args[0]);
    std::vector<std::string> places = g_learner.findPlacesByCellId(cellId);
    
    return StringVectorToArray(env, places);
}

static napi_value GetSummary(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: placeId");
        return nullptr;
    }
    
    std::string placeId = GetStringArg(env, args[0]);
    SignalSummary summary = g_learner.getSummary(placeId);
    
    napi_value obj;
    napi_create_object(env, &obj);
    
    napi_set_named_property(env, obj, "wifiList", StringVectorToArray(env, summary.wifiList));
    napi_set_named_property(env, obj, "btList", StringVectorToArray(env, summary.btList));
    napi_set_named_property(env, obj, "visitCount", CreateInt32(env, summary.visitCount));
    
    return obj;
}

static napi_value Clear(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        g_learner.clearAll();
    } else {
        std::string placeId = GetStringArg(env, args[0]);
        g_learner.clear(placeId);
    }
    
    return nullptr;
}

EXTERN_C_START

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"learn", nullptr, Learn, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"matchesWifi", nullptr, MatchesWifi, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"matchesCellId", nullptr, MatchesCellId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"findPlacesByWifi", nullptr, FindPlacesByWifi, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"findPlacesByCellId", nullptr, FindPlacesByCellId, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSummary", nullptr, GetSummary, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clear", nullptr, Clear, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module place_signal_learner_module = {
    .nm_version = 1,
    .nm_flags = NAPI_MODULE_VERSION,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "place_signal_learner",
    .nm_priv = nullptr,
    .reserved = {0},
};

EXTERN_C_END

extern "C" __attribute__((constructor)) void RegisterPlaceSignalLearnerModule(void) {
    napi_module_register(&place_signal_learner_module);
}
