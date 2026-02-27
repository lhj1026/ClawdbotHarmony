/**
 * sampling_strategy_napi.cpp — 多级采集策略 NAPI 绑定
 */
#include <napi/native_api.h>
#include "sampling_strategy.h"
#include <string>

using namespace sampling_strategy;

static SamplingStrategy g_strategy;

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

static napi_value CreateSensorIntervals(napi_env env, const SensorIntervals& intervals) {
    napi_value obj;
    napi_create_object(env, &obj);
    
    napi_set_named_property(env, obj, "gpsIntervalMs", CreateInt64(env, intervals.gpsIntervalMs));
    napi_set_named_property(env, obj, "wifiIntervalMs", CreateInt64(env, intervals.wifiIntervalMs));
    napi_set_named_property(env, obj, "accelIntervalNs", CreateInt64(env, intervals.accelIntervalNs));
    
    return obj;
}

static napi_value GetIntervalsForState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: motionState");
        return nullptr;
    }
    
    int32_t stateInt;
    napi_get_value_int32(env, args[0], &stateInt);
    
    motion_detector::MotionState state = static_cast<motion_detector::MotionState>(stateInt);
    SensorIntervals intervals = g_strategy.getIntervalsForState(state);
    
    return CreateSensorIntervals(env, intervals);
}

static napi_value UpdateForState(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: motionState");
        return nullptr;
    }
    
    int32_t stateInt;
    napi_get_value_int32(env, args[0], &stateInt);
    
    motion_detector::MotionState state = static_cast<motion_detector::MotionState>(stateInt);
    bool changed = g_strategy.updateForState(state);
    
    return CreateBool(env, changed);
}

static napi_value GetCurrentIntervals(napi_env env, napi_callback_info info) {
    SensorIntervals intervals = g_strategy.getCurrentIntervals();
    return CreateSensorIntervals(env, intervals);
}

static napi_value GetAllIntervals(napi_env env, napi_callback_info info) {
    napi_value obj;
    napi_create_object(env, &obj);
    
    const DefaultConfig& config = g_strategy.getConfig();
    
    napi_set_named_property(env, obj, "stationary", CreateSensorIntervals(env, config.stationary));
    napi_set_named_property(env, obj, "walking", CreateSensorIntervals(env, config.walking));
    napi_set_named_property(env, obj, "running", CreateSensorIntervals(env, config.running));
    napi_set_named_property(env, obj, "driving", CreateSensorIntervals(env, config.driving));
    napi_set_named_property(env, obj, "unknown", CreateSensorIntervals(env, config.unknown));
    
    return obj;
}

EXTERN_C_START

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"getIntervalsForState", nullptr, GetIntervalsForState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"updateForState", nullptr, UpdateForState, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getCurrentIntervals", nullptr, GetCurrentIntervals, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getAllIntervals", nullptr, GetAllIntervals, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module sampling_strategy_module = {
    .nm_version = 1,
    .nm_flags = NAPI_MODULE_VERSION,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "sampling_strategy",
    .nm_priv = nullptr,
    .reserved = {0},
};

EXTERN_C_END

extern "C" __attribute__((constructor)) void RegisterSamplingStrategyModule(void) {
    napi_module_register(&sampling_strategy_module);
}
