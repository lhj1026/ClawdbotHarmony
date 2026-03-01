/**
 * data_tray_napi.cpp — 传感器数据托盘 NAPI 绑定
 */
#include <napi/native_api.h>
#include "data_tray.h"
#include <vector>
#include <string>

using namespace data_tray;

// ============================================================
// Helper functions
// ============================================================

static int64_t GetInt64Prop(napi_env env, napi_value obj, const char* key, int64_t defaultVal = 0) {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;

    int64_t val;
    status = napi_get_value_int64(env, prop, &val);
    return (status == napi_ok) ? val : defaultVal;
}

static double GetDoubleProp(napi_env env, napi_value obj, const char* key, double defaultVal = 0.0) {
    napi_value prop;
    napi_status status = napi_get_named_property(env, obj, key, &prop);
    if (status != napi_ok) return defaultVal;

    double val;
    status = napi_get_value_double(env, prop, &val);
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
    status = napi_get_value_string_utf8(env, prop, &result[0], len + 1, &len);
    return (status == napi_ok) ? result : defaultVal;
}

static napi_value CreateString(napi_env env, const std::string& str) {
    napi_value result;
    napi_create_string_utf8(env, str.c_str(), str.length(), &result);
    return result;
}

static napi_value CreateInt64(napi_env env, int64_t val) {
    napi_value result;
    napi_create_int64(env, val, &result);
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

// ============================================================
// NAPI bindings
// ============================================================

/**
 * dataTray.put(key, value, quality?, source?)
 */
static napi_value Put(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value args[4];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_error(env, nullptr, "Expected at least 2 arguments: key, value");
        return nullptr;
    }

    // 直接从参数取值，不是从对象属性取
    size_t len;
    std::string key, value, source;
    
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &len);
    key.resize(len);
    napi_get_value_string_utf8(env, args[0], &key[0], len + 1, &len);
    
    napi_get_value_string_utf8(env, args[1], nullptr, 0, &len);
    value.resize(len);
    napi_get_value_string_utf8(env, args[1], &value[0], len + 1, &len);
    
    double quality = 1.0;
    if (argc >= 3) {
        napi_get_value_double(env, args[2], &quality);
    }
    
    if (argc >= 4) {
        napi_get_value_string_utf8(env, args[3], nullptr, 0, &len);
        source.resize(len);
        napi_get_value_string_utf8(env, args[3], &source[0], len + 1, &len);
    }

    SensorDataTray::getInstance().put(key, value, quality, source);

    return nullptr;
}

/**
 * dataTray.get(key) → { value, quality, fresh, ageMs }
 */
static napi_value Get(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 1) {
        napi_throw_error(env, nullptr, "Expected 1 argument: key");
        return nullptr;
    }

    size_t keyLen;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &keyLen);
    std::string key(keyLen, '\0');
    napi_get_value_string_utf8(env, args[0], &key[0], keyLen + 1, &keyLen);
    
    TrayReadResult result = SensorDataTray::getInstance().get(key);

    napi_value obj;
    napi_create_object(env, &obj);

    // value: string | null
    if (result.value.has_value()) {
        napi_set_named_property(env, obj, "value", CreateString(env, result.value.value()));
    } else {
        napi_value nullVal;
        napi_get_null(env, &nullVal);
        napi_set_named_property(env, obj, "value", nullVal);
    }

    napi_set_named_property(env, obj, "quality", CreateDouble(env, result.quality));
    napi_set_named_property(env, obj, "fresh", CreateBool(env, result.fresh));
    napi_set_named_property(env, obj, "ageMs", CreateInt64(env, result.ageMs));

    return obj;
}

/**
 * dataTray.getSnapshot() → ContextSnapshot object
 */
static napi_value GetSnapshot(napi_env env, napi_callback_info info) {
    ContextSnapshot snap = SensorDataTray::getInstance().getSnapshot();

    napi_value obj;
    napi_create_object(env, &obj);

    napi_set_named_property(env, obj, "timeOfDay", CreateString(env, snap.timeOfDay));
    napi_set_named_property(env, obj, "hour", CreateString(env, snap.hour));
    napi_set_named_property(env, obj, "dayOfWeek", CreateString(env, snap.dayOfWeek));
    napi_set_named_property(env, obj, "isWeekend", CreateString(env, snap.isWeekend));
    napi_set_named_property(env, obj, "motionState", CreateString(env, snap.motionState));
    napi_set_named_property(env, obj, "batteryLevel", CreateString(env, snap.batteryLevel));
    napi_set_named_property(env, obj, "isCharging", CreateString(env, snap.isCharging));
    napi_set_named_property(env, obj, "networkType", CreateString(env, snap.networkType));

    // Optional fields
    if (snap.geofence.has_value()) {
        napi_set_named_property(env, obj, "geofence", CreateString(env, snap.geofence.value()));
    }
    if (snap.wifiSsid.has_value()) {
        napi_set_named_property(env, obj, "wifiSsid", CreateString(env, snap.wifiSsid.value()));
    }
    if (snap.wifiLostWork.has_value()) {
        napi_set_named_property(env, obj, "wifiLostWork", CreateString(env, snap.wifiLostWork.value()));
    }
    if (snap.latitude.has_value()) {
        napi_set_named_property(env, obj, "latitude", CreateString(env, snap.latitude.value()));
    }
    if (snap.longitude.has_value()) {
        napi_set_named_property(env, obj, "longitude", CreateString(env, snap.longitude.value()));
    }
    if (snap.stepCount.has_value()) {
        napi_set_named_property(env, obj, "stepCount", CreateString(env, snap.stepCount.value()));
    }
    if (snap.flightCountdownMin.has_value()) {
        napi_set_named_property(env, obj, "flightCountdownMin", CreateString(env, snap.flightCountdownMin.value()));
    }
    if (snap.flightArrivalMin.has_value()) {
        napi_set_named_property(env, obj, "flightArrivalMin", CreateString(env, snap.flightArrivalMin.value()));
    }
    if (snap.flightNumber.has_value()) {
        napi_set_named_property(env, obj, "flightNumber", CreateString(env, snap.flightNumber.value()));
    }
    if (snap.hasUpcomingFlight.has_value()) {
        napi_set_named_property(env, obj, "hasUpcomingFlight", CreateString(env, snap.hasUpcomingFlight.value()));
    }

    return obj;
}

/**
 * dataTray.setTTL(key, ttlMs)
 */
static napi_value SetTTL(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value args[2];
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);

    if (argc < 2) {
        napi_throw_error(env, nullptr, "Expected 2 arguments: key, ttlMs");
        return nullptr;
    }

    size_t keyLen;
    napi_get_value_string_utf8(env, args[0], nullptr, 0, &keyLen);
    std::string key(keyLen, '\0');
    napi_get_value_string_utf8(env, args[0], &key[0], keyLen + 1, &keyLen);
    
    int64_t ttlMs;
    napi_get_value_int64(env, args[1], &ttlMs);

    SensorDataTray::getInstance().setTTL(key, ttlMs);

    return nullptr;
}

/**
 * dataTray.getStatus() → TrayStatus[]
 */
static napi_value GetStatus(napi_env env, napi_callback_info info) {
    std::vector<TrayStatus> statusList = SensorDataTray::getInstance().getStatus();

    napi_value arr;
    napi_create_array_with_length(env, statusList.size(), &arr);

    for (size_t i = 0; i < statusList.size(); i++) {
        const TrayStatus& s = statusList[i];

        napi_value obj;
        napi_create_object(env, &obj);

        napi_set_named_property(env, obj, "key", CreateString(env, s.key));
        napi_set_named_property(env, obj, "value", CreateString(env, s.value));
        napi_set_named_property(env, obj, "ageMs", CreateInt64(env, s.ageMs));
        napi_set_named_property(env, obj, "ttlMs", CreateInt64(env, s.ttlMs));
        napi_set_named_property(env, obj, "fresh", CreateBool(env, s.fresh));
        napi_set_named_property(env, obj, "effectiveQuality", CreateDouble(env, s.effectiveQuality));
        napi_set_named_property(env, obj, "source", CreateString(env, s.source));

        napi_set_element(env, arr, i, obj);
    }

    return arr;
}

/**
 * dataTray.clear()
 */
static napi_value Clear(napi_env env, napi_callback_info info) {
    SensorDataTray::getInstance().clear();
    return nullptr;
}

/**
 * dataTray.size() → number
 */
static napi_value Size(napi_env env, napi_callback_info info) {
    size_t sz = SensorDataTray::getInstance().size();
    napi_value result;
    napi_create_int64(env, static_cast<int64_t>(sz), &result);
    return result;
}

// ============================================================
// Module registration
// ============================================================

EXTERN_C_START

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"put", nullptr, Put, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"get", nullptr, Get, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getSnapshot", nullptr, GetSnapshot, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"setTTL", nullptr, SetTTL, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"getStatus", nullptr, GetStatus, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"clear", nullptr, Clear, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"size", nullptr, Size, nullptr, nullptr, nullptr, napi_default, nullptr},
    };

    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module data_tray_module = {
    .nm_version = 1,
    .nm_flags = NAPI_MODULE_VERSION,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "data_tray",
    .nm_priv = nullptr,
    .reserved = {0},
};


EXTERN_C_END

extern "C" __attribute__((constructor)) void RegisterDataTrayModule(void) {
    napi_module_register(&data_tray_module);
}
