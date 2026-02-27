/**
 * motion_detector_napi.cpp — 运动状态检测 NAPI 绑定
 */
#include <napi/native_api.h>
#include "motion_detector.h"
#include <vector>
#include <string>

using namespace motion_detector;

static MotionDetector g_detector;

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

static napi_value Detect(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_error(env, nullptr, "Expected 2 arguments: accel, gpsSpeed");
        return nullptr;
    }
    
    AccelerometerData accel;
    accel.x = GetDoubleProp(env, args[0], "x", 0);
    accel.y = GetDoubleProp(env, args[0], "y", 0);
    accel.z = GetDoubleProp(env, args[0], "z", 0);
    accel.timestamp = GetInt64Prop(env, args[0], "timestamp", 0);
    
    double gpsSpeed;
    napi_get_value_double(env, args[1], &gpsSpeed);
    
    MotionResult result = g_detector.detect(accel, gpsSpeed);
    
    napi_value obj;
    napi_create_object(env, &obj);
    
    napi_set_named_property(env, obj, "state", CreateString(env, MotionDetector::stateToString(result.state)));
    napi_set_named_property(env, obj, "magnitude", CreateDouble(env, result.magnitude));
    napi_set_named_property(env, obj, "gpsSpeed", CreateDouble(env, result.gpsSpeed));
    napi_set_named_property(env, obj, "confidence", CreateDouble(env, result.confidence));
    napi_set_named_property(env, obj, "stateChanged", CreateBool(env, result.stateChanged));
    
    return obj;
}

static napi_value StateToString(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: state");
        return nullptr;
    }
    
    int32_t stateInt;
    napi_get_value_int32(env, args[0], &stateInt);
    
    MotionState state = static_cast<MotionState>(stateInt);
    return CreateString(env, MotionDetector::stateToString(state));
}

static napi_value StringToState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: stateStr");
        return nullptr;
    }
    
    size_t len;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    std::string str(len, '\0');
    napi_get_value_string_utf8(env, args[0], &str[0], len + 1, &len);
    
    MotionState state = MotionDetector::stringToState(str);
    
    napi_value result;
    napi_create_int32(env, static_cast<int32_t>(state), &result);
    return result;
}

static napi_value GetLastState(napi_env env, napi_callback_info info) {
    MotionState state = g_detector.getLastState();
    
    napi_value result;
    napi_create_int32(env, static_cast<int32_t>(state), &result);
    return result;
}

static napi_value Reset(napi_env env, napi_callback_info info) {
    g_detector.reset();
    return nullptr;
}

EXTERN_C_START

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"detect", nullptr, Detect, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stateToString", nullptr, StateToString, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stringToState", nullptr, StringToState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getLastState", nullptr, GetLastState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"reset", nullptr, Reset, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module motion_detector_module = {
    .nm_version = 1,
    .nm_flags = NAPI_MODULE_VERSION,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "motion_detector",
    .nm_priv = nullptr,
    .reserved = {0},
};

EXTERN_C_END

extern "C" __attribute__((constructor)) void RegisterMotionDetectorModule(void) {
    napi_module_register(&motion_detector_module);
}
