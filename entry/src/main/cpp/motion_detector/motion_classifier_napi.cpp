/**
 * motion_classifier_napi.cpp — Motion Classifier NAPI wrapper
 *
 * 向 ArkTS 暴露 Z 轴特征提取和地点推断接口
 */
#include "motion_classifier.h"
#include "napi/native_api.h"
#include <memory>
#include <vector>

namespace motion_detector {

// ============================================================
// NAPI 辅助函数
// ============================================================

/** 将 JS Number 转换为 double */
static double jsNumberToDouble(napi_env env, napi_value val, double defaultVal = 0.0) {
    double result = defaultVal;
    napi_status status = napi_get_value_double(env, val, &result);
    if (status != napi_ok) {
        return defaultVal;
    }
    return result;
}

/** 将 JS String 转换为 C++ string */
static std::string jsStringToCpp(napi_env env, napi_value val) {
    size_t length = 0;
    napi_status status = napi_get_value_string_utf8(env, val, nullptr, 0, &length);
    if (status != napi_ok) {
        return "";
    }
    
    std::string result(length, '\0');
    status = napi_get_value_string_utf8(env, val, &result[0], length + 1, &length);
    if (status != napi_ok) {
        return "";
    }
    return result;
}

/** 将 C++ string 转换为 JS String */
static napi_value cppStringToJs(napi_env env, const std::string& str) {
    napi_value jsStr;
    napi_create_string_utf8(env, str.c_str(), str.length(), &jsStr);
    return jsStr;
}

/** 获取 JS Object 的字符串字段 */
static std::string getObjectString(napi_env env, napi_value obj, const char* key) {
    napi_value val;
    if (napi_get_named_property(env, obj, key, &val) != napi_ok) {
        return "";
    }
    return jsStringToCpp(env, val);
}

/** 获取 JS Object 的数值字段 */
static double getObjectNumber(napi_env env, napi_value obj, const char* key, double def = 0.0) {
    napi_value val;
    if (napi_get_named_property(env, obj, key, &val) != napi_ok) {
        return def;
    }
    return jsNumberToDouble(env, val, def);
}

/** 创建 JS Object 并设置字符串字段 */
static void setObjectString(napi_env env, napi_value obj, const char* key, const std::string& val) {
    napi_value jsVal = cppStringToJs(env, val);
    napi_set_named_property(env, obj, key, jsVal);
}

/** 创建 JS Object 并设置数值字段 */
static void setObjectNumber(napi_env env, napi_value obj, const char* key, double val) {
    napi_value jsVal;
    napi_create_double(env, val, &jsVal);
    napi_set_named_property(env, obj, key, jsVal);
}

/** 创建 JS Object 并设置布尔字段 */
static void setObjectBoolean(napi_env env, napi_value obj, const char* key, bool val) {
    napi_value jsVal;
    napi_get_boolean(env, val, &jsVal);
    napi_set_named_property(env, obj, key, jsVal);
}

// ============================================================
// Z 轴特征提取器 - NAPI 包装
// ============================================================

struct ZAxisExtractorWrapper {
    std::unique_ptr<ZAxisFeatureExtractor> extractor;
    
    ZAxisExtractorWrapper() : extractor(std::make_unique<ZAxisFeatureExtractor>()) {}
};

/** Z 轴提取器构造函数 */
static napi_value createZAxisExtractor(napi_env env, napi_callback_info info) {
    auto wrapper = std::make_unique<ZAxisExtractorWrapper>();
    
    napi_value result;
    void* extractorPtr = wrapper.release();
    napi_create_external(env, extractorPtr,
        [](napi_env /*env*/, void* ptr, void* /*hint*/) {
            delete static_cast<ZAxisExtractorWrapper*>(ptr);
        }, nullptr, &result);
    
    return result;
}

/** 添加 Z 轴样本 */
static napi_value addZAxisSample(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 3) {
        napi_throw_type_error(env, nullptr, "需要3个参数：extractor, z, timestamp");
        return nullptr;
    }
    
    void* extractorPtr;
    napi_get_value_external(env, argv[0], &extractorPtr);
    auto wrapper = static_cast<ZAxisExtractorWrapper*>(extractorPtr);
    
    double z = jsNumberToDouble(env, argv[1]);
    int64_t timestamp = static_cast<int64_t>(jsNumberToDouble(env, argv[2]));
    
    wrapper->extractor->addSample(z, timestamp);
    
    return nullptr;
}

/** 计算 Z 轴特征 */
static napi_value computeZAxisFeatures(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "需要1个参数：extractor");
        return nullptr;
    }
    
    void* extractorPtr;
    napi_get_value_external(env, argv[0], &extractorPtr);
    auto wrapper = static_cast<ZAxisExtractorWrapper*>(extractorPtr);
    
    ZAxisFeatures features = wrapper->extractor->computeFeatures();
    
    // 创建结果对象
    napi_value result;
    napi_create_object(env, &result);
    
    setObjectNumber(env, result, "amplitude", features.amplitude);
    setObjectNumber(env, result, "frequency", features.frequency);
    setObjectNumber(env, result, "variance", features.variance);
    setObjectBoolean(env, result, "isValid", features.isValid);
    
    return result;
}

/** 根据 Z 轴特征分类 */
static napi_value classifyByZAxis(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "需要1个参数：features");
        return nullptr;
    }
    
    ZAxisFeatures features;
    features.amplitude = getObjectNumber(env, argv[0], "amplitude");
    features.frequency = getObjectNumber(env, argv[0], "frequency");
    features.variance = getObjectNumber(env, argv[0], "variance");
    features.isValid = true;  // 假设已验证
    
    EnhancedMotionState state = ZAxisFeatureExtractor::classifyByZAxis(features);
    std::string stateStr = enhancedStateToString(state);
    
    return cppStringToJs(env, stateStr);
}

// ============================================================
// 地点推断 - NAPI 包装
// ============================================================

/** 判断是否是交通枢纽 */
static napi_value isTransitHub(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 1) {
        napi_throw_type_error(env, nullptr, "需要1个参数：geofenceId");
        return nullptr;
    }
    
    std::string geofenceId = jsStringToCpp(env, argv[0]);
    bool result = TransitInference::isTransitHub(geofenceId);
    
    napi_value jsResult;
    napi_get_boolean(env, result, &jsResult);
    return jsResult;
}

/** 推断驾驶 vs 乘车 */
static napi_value inferDrivingVsTransit(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, nullptr, nullptr);
    
    if (argc < 2) {
        napi_throw_type_error(env, nullptr, "需要2个参数：motionState, context");
        return nullptr;
    }
    
    // 解析运动状态
    std::string motionStr = jsStringToCpp(env, argv[0]);
    EnhancedMotionState motion = stringToEnhancedState(motionStr);
    
    // 解析地点上下文
    TransitInferenceContext context;
    context.prevGeofence = getObjectString(env, argv[1], "prevGeofence");
    context.currentGeofence = getObjectString(env, argv[1], "currentGeofence");
    context.geofenceDepartureTime = static_cast<int64_t>(
        getObjectNumber(env, argv[1], "geofenceDepartureTime"));
    context.gpsSpeed = getObjectNumber(env, argv[1], "gpsSpeed");
    
    // 执行推断
    EnhancedMotionState result = TransitInference::inferDrivingVsTransit(motion, context);
    std::string resultStr = enhancedStateToString(result);
    
    return cppStringToJs(env, resultStr);
}

// ============================================================
// NAPI 模块初始化
// ============================================================

static napi_value init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"createZAxisExtractor",    nullptr, createZAxisExtractor,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"addZAxisSample",          nullptr, addZAxisSample,          nullptr, nullptr, nullptr, napi_default, nullptr},
        {"computeZAxisFeatures",    nullptr, computeZAxisFeatures,    nullptr, nullptr, nullptr, napi_default, nullptr},
        {"classifyByZAxis",         nullptr, classifyByZAxis,         nullptr, nullptr, nullptr, napi_default, nullptr},
        {"isTransitHub",            nullptr, isTransitHub,            nullptr, nullptr, nullptr, napi_default, nullptr},
        {"inferDrivingVsTransit",   nullptr, inferDrivingVsTransit,   nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    
    return exports;
}

NAPI_MODULE(motion_classifier, init)

}  // namespace motion_detector
