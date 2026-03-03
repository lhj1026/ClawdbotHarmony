/**
 * stream_mlp.cpp — Stream Deep RL implementation
 *
 * Forward/backward propagation, ObGD, LayerNorm, Welford normalization,
 * JSON serialization.
 */
#include "stream_mlp.h"
#include "context_engine.h"  // for safe_stod, ContextMap

#include <sstream>
#include <algorithm>
#include <cstring>
#include <cmath>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

namespace context_engine {

// ============================================================
// RunningStats
// ============================================================

RunningStats::RunningStats() : count(0) {
    std::memset(mean, 0, sizeof(mean));
    std::memset(m2, 0, sizeof(m2));
}

void RunningStats::update(const double* x) {
    count++;
    for (int i = 0; i < STREAM_FEAT_DIM; ++i) {
        double delta = x[i] - mean[i];
        mean[i] += delta / count;
        double delta2 = x[i] - mean[i];
        m2[i] += delta * delta2;
    }
}

void RunningStats::normalize(const double* x, double* out) const {
    if (count < 2) {
        std::memcpy(out, x, sizeof(double) * STREAM_FEAT_DIM);
        return;
    }
    for (int i = 0; i < STREAM_FEAT_DIM; ++i) {
        double var = m2[i] / count;
        double std = std::sqrt(var + 1e-8);
        out[i] = (x[i] - mean[i]) / std;
    }
}

// ============================================================
// StreamMLP
// ============================================================

StreamMLP::StreamMLP()
    : rewardMean_(0.0), rewardM2_(0.0), rewardCount_(0), sampleCount_(0) {
    std::mt19937 rng(std::random_device{}());
    layer1_.sparseInit(rng);
    layer2_.sparseInit(rng);
    output_.sparseInit(rng);
}

double StreamMLP::predict(const double* features) {
    // Normalize input
    double normed[STREAM_FEAT_DIM];
    inputStats_.normalize(features, normed);

    // Layer 1: Linear → LayerNorm → LeakyReLU
    double h1[STREAM_H1];
    layer1_.forward(normed, h1);
    DenseLayer<STREAM_FEAT_DIM, STREAM_H1>::layerNorm(h1, STREAM_H1);
    DenseLayer<STREAM_FEAT_DIM, STREAM_H1>::leakyRelu(h1, STREAM_H1);

    // Layer 2: Linear → LayerNorm → LeakyReLU
    double h2[STREAM_H2];
    layer2_.forward(h1, h2);
    DenseLayer<STREAM_H1, STREAM_H2>::layerNorm(h2, STREAM_H2);
    DenseLayer<STREAM_H1, STREAM_H2>::leakyRelu(h2, STREAM_H2);

    // Output: Linear → scalar
    double out[1];
    output_.forward(h2, out);

    return out[0];
}

void StreamMLP::update(const double* features, double reward) {
    sampleCount_++;

    // Update input running stats
    inputStats_.update(features);

    // Normalize reward (Welford)
    rewardCount_++;
    double rDelta = reward - rewardMean_;
    rewardMean_ += rDelta / rewardCount_;
    double rDelta2 = reward - rewardMean_;
    rewardM2_ += rDelta * rDelta2;

    double normReward = reward;
    if (rewardCount_ >= 2) {
        double rVar = rewardM2_ / rewardCount_;
        double rStd = std::sqrt(rVar + 1e-8);
        normReward = (reward - rewardMean_) / rStd;
    }

    // ---- Forward pass (caching intermediate values) ----
    double normed[STREAM_FEAT_DIM];
    inputStats_.normalize(features, normed);

    // Layer 1
    double z1[STREAM_H1];  // pre-activation (before LN)
    layer1_.forward(normed, z1);
    double z1_ln[STREAM_H1];
    std::memcpy(z1_ln, z1, sizeof(z1));
    DenseLayer<STREAM_FEAT_DIM, STREAM_H1>::layerNorm(z1_ln, STREAM_H1);
    double h1[STREAM_H1];
    std::memcpy(h1, z1_ln, sizeof(z1_ln));
    DenseLayer<STREAM_FEAT_DIM, STREAM_H1>::leakyRelu(h1, STREAM_H1);

    // Layer 2
    double z2[STREAM_H2];
    layer2_.forward(h1, z2);
    double z2_ln[STREAM_H2];
    std::memcpy(z2_ln, z2, sizeof(z2));
    DenseLayer<STREAM_H1, STREAM_H2>::layerNorm(z2_ln, STREAM_H2);
    double h2[STREAM_H2];
    std::memcpy(h2, z2_ln, sizeof(z2_ln));
    DenseLayer<STREAM_H1, STREAM_H2>::leakyRelu(h2, STREAM_H2);

    // Output
    double pred[1];
    output_.forward(h2, pred);

    // ---- Backward pass ----
    double delta = pred[0] - normReward;  // MSE gradient: 2*(pred-target), factor 2 absorbed into LR

    // Compute total gradient L1 norm for ObGD
    // We accumulate |grad| as we go, then apply ObGD step-size
    double gradL1 = 0.0;

    // --- Output layer gradients ---
    // dL/dW_out[0][j] = delta * h2[j]
    // dL/db_out[0] = delta
    double dOut_dH2[STREAM_H2];
    for (int j = 0; j < STREAM_H2; ++j) {
        gradL1 += std::abs(delta * h2[j]);
        dOut_dH2[j] = delta * output_.W[0][j];
    }
    gradL1 += std::abs(delta);  // bias gradient

    // --- Layer 2 gradients ---
    // Backprop through LeakyReLU
    double dH2[STREAM_H2];
    for (int j = 0; j < STREAM_H2; ++j) {
        dH2[j] = dOut_dH2[j] * ((z2_ln[j] >= 0.0) ? 1.0 : STREAM_LEAKY_ALPHA);
    }
    // Skip exact LayerNorm backward (approximate: pass through)
    // This is a common simplification for non-learnable LN

    // dL/dW2[o][i] = dH2[o] * h1[i]
    double dL2_dH1[STREAM_H1];
    std::memset(dL2_dH1, 0, sizeof(dL2_dH1));
    for (int o = 0; o < STREAM_H2; ++o) {
        for (int i = 0; i < STREAM_H1; ++i) {
            gradL1 += std::abs(dH2[o] * h1[i]);
            dL2_dH1[i] += dH2[o] * layer2_.W[o][i];
        }
        gradL1 += std::abs(dH2[o]);
    }

    // --- Layer 1 gradients ---
    double dH1[STREAM_H1];
    for (int j = 0; j < STREAM_H1; ++j) {
        dH1[j] = dL2_dH1[j] * ((z1_ln[j] >= 0.0) ? 1.0 : STREAM_LEAKY_ALPHA);
    }

    for (int o = 0; o < STREAM_H1; ++o) {
        for (int i = 0; i < STREAM_FEAT_DIM; ++i) {
            gradL1 += std::abs(dH1[o] * normed[i]);
        }
        gradL1 += std::abs(dH1[o]);
    }

    // ---- ObGD step-size ----
    double product = STREAM_KAPPA * std::abs(delta) * gradL1;
    double effectiveLR = (product > 1.0) ? STREAM_LR / product : STREAM_LR;

    // ---- Apply gradients ----

    // Output layer
    for (int j = 0; j < STREAM_H2; ++j) {
        output_.W[0][j] -= effectiveLR * (delta * h2[j]) + STREAM_WEIGHT_DECAY * output_.W[0][j];
    }
    output_.b[0] -= effectiveLR * delta;

    // Layer 2
    for (int o = 0; o < STREAM_H2; ++o) {
        for (int i = 0; i < STREAM_H1; ++i) {
            layer2_.W[o][i] -= effectiveLR * (dH2[o] * h1[i]) + STREAM_WEIGHT_DECAY * layer2_.W[o][i];
        }
        layer2_.b[o] -= effectiveLR * dH2[o];
    }

    // Layer 1
    for (int o = 0; o < STREAM_H1; ++o) {
        for (int i = 0; i < STREAM_FEAT_DIM; ++i) {
            layer1_.W[o][i] -= effectiveLR * (dH1[o] * normed[i]) + STREAM_WEIGHT_DECAY * layer1_.W[o][i];
        }
        layer1_.b[o] -= effectiveLR * dH1[o];
    }
}

// ============================================================
// StreamMLP JSON serialization
// ============================================================

std::string StreamMLP::exportJson() const {
    std::ostringstream ss;
    ss << "{\"sampleCount\":" << sampleCount_
       << ",\"rewardMean\":" << rewardMean_
       << ",\"rewardM2\":" << rewardM2_
       << ",\"rewardCount\":" << rewardCount_
       << ",\"featDim\":" << STREAM_FEAT_DIM;

    // Input stats
    ss << ",\"inputMean\":[";
    for (int i = 0; i < STREAM_FEAT_DIM; ++i) {
        if (i > 0) ss << ",";
        ss << inputStats_.mean[i];
    }
    ss << "],\"inputM2\":[";
    for (int i = 0; i < STREAM_FEAT_DIM; ++i) {
        if (i > 0) ss << ",";
        ss << inputStats_.m2[i];
    }
    ss << "],\"inputCount\":" << inputStats_.count;

    // Layer 1 weights
    ss << ",\"W1\":[";
    for (int o = 0; o < STREAM_H1; ++o) {
        if (o > 0) ss << ",";
        ss << "[";
        for (int i = 0; i < STREAM_FEAT_DIM; ++i) {
            if (i > 0) ss << ",";
            ss << layer1_.W[o][i];
        }
        ss << "]";
    }
    ss << "],\"b1\":[";
    for (int o = 0; o < STREAM_H1; ++o) {
        if (o > 0) ss << ",";
        ss << layer1_.b[o];
    }

    // Layer 2 weights
    ss << "],\"W2\":[";
    for (int o = 0; o < STREAM_H2; ++o) {
        if (o > 0) ss << ",";
        ss << "[";
        for (int i = 0; i < STREAM_H1; ++i) {
            if (i > 0) ss << ",";
            ss << layer2_.W[o][i];
        }
        ss << "]";
    }
    ss << "],\"b2\":[";
    for (int o = 0; o < STREAM_H2; ++o) {
        if (o > 0) ss << ",";
        ss << layer2_.b[o];
    }

    // Output weights
    ss << "],\"W3\":[";
    for (int i = 0; i < STREAM_H2; ++i) {
        if (i > 0) ss << ",";
        ss << output_.W[0][i];
    }
    ss << "],\"b3\":" << output_.b[0];

    ss << "}";
    return ss.str();
}

// Minimal JSON array parser: extract doubles from "[1.0,2.0,...]"
static bool parseDoubleArray(const std::string& json, size_t startPos, double* out, int count) {
    auto arrStart = json.find('[', startPos);
    if (arrStart == std::string::npos) return false;
    size_t pos = arrStart + 1;
    for (int i = 0; i < count; ++i) {
        while (pos < json.size() && (json[pos] == ' ' || json[pos] == ',')) pos++;
        if (pos >= json.size()) return false;
        char* end = nullptr;
        out[i] = strtod(json.c_str() + pos, &end);
        if (end == json.c_str() + pos) return false;
        pos = end - json.c_str();
    }
    return true;
}

// Find position after "key": in JSON
static size_t findKey(const std::string& json, const std::string& key) {
    std::string needle = "\"" + key + "\"";
    auto pos = json.find(needle);
    if (pos == std::string::npos) return std::string::npos;
    pos = json.find(':', pos + needle.size());
    if (pos == std::string::npos) return std::string::npos;
    return pos + 1;
}

static double parseNum(const std::string& json, const std::string& key, double def) {
    auto pos = findKey(json, key);
    if (pos == std::string::npos) return def;
    while (pos < json.size() && json[pos] == ' ') pos++;
    char* end = nullptr;
    double v = strtod(json.c_str() + pos, &end);
    if (end == json.c_str() + pos) return def;
    return v;
}

// Parse 2D weight array: [[1,2],[3,4],...] for [OUT][IN]
static bool parse2DWeights(const std::string& json, size_t startPos, double* out, int rows, int cols) {
    auto outerArr = json.find('[', startPos);
    if (outerArr == std::string::npos) return false;
    size_t pos = outerArr + 1;
    for (int r = 0; r < rows; ++r) {
        auto innerArr = json.find('[', pos);
        if (innerArr == std::string::npos) return false;
        size_t ipos = innerArr + 1;
        for (int c = 0; c < cols; ++c) {
            while (ipos < json.size() && (json[ipos] == ' ' || json[ipos] == ',')) ipos++;
            char* end = nullptr;
            out[r * cols + c] = strtod(json.c_str() + ipos, &end);
            if (end == json.c_str() + ipos) return false;
            ipos = end - json.c_str();
        }
        auto innerEnd = json.find(']', ipos);
        if (innerEnd == std::string::npos) return false;
        pos = innerEnd + 1;
    }
    return true;
}

void StreamMLP::importJson(const std::string& json) {
    // Check dimension compatibility
    int dim = static_cast<int>(parseNum(json, "featDim", 0));
    if (dim != 0 && dim != STREAM_FEAT_DIM) {
        // Dimension mismatch — skip import, keep fresh init
        return;
    }

    sampleCount_ = static_cast<int>(parseNum(json, "sampleCount", 0));
    rewardMean_ = parseNum(json, "rewardMean", 0.0);
    rewardM2_ = parseNum(json, "rewardM2", 0.0);
    rewardCount_ = static_cast<int>(parseNum(json, "rewardCount", 0));
    inputStats_.count = static_cast<int>(parseNum(json, "inputCount", 0));

    // Input stats
    auto pos = findKey(json, "inputMean");
    if (pos != std::string::npos) {
        parseDoubleArray(json, pos, inputStats_.mean, STREAM_FEAT_DIM);
    }
    pos = findKey(json, "inputM2");
    if (pos != std::string::npos) {
        parseDoubleArray(json, pos, inputStats_.m2, STREAM_FEAT_DIM);
    }

    // Layer 1
    pos = findKey(json, "W1");
    if (pos != std::string::npos) {
        parse2DWeights(json, pos, &layer1_.W[0][0], STREAM_H1, STREAM_FEAT_DIM);
    }
    pos = findKey(json, "b1");
    if (pos != std::string::npos) {
        parseDoubleArray(json, pos, layer1_.b, STREAM_H1);
    }

    // Layer 2
    pos = findKey(json, "W2");
    if (pos != std::string::npos) {
        parse2DWeights(json, pos, &layer2_.W[0][0], STREAM_H2, STREAM_H1);
    }
    pos = findKey(json, "b2");
    if (pos != std::string::npos) {
        parseDoubleArray(json, pos, layer2_.b, STREAM_H2);
    }

    // Output
    pos = findKey(json, "W3");
    if (pos != std::string::npos) {
        parseDoubleArray(json, pos, output_.W[0], STREAM_H2);
    }
    output_.b[0] = parseNum(json, "b3", 0.0);
}

// ============================================================
// StreamRLEngine
// ============================================================

double StreamRLEngine::scoreArm(const std::string& actionId, const double* features) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = arms_.find(actionId);
    if (it == arms_.end()) {
        // New arm — create with sparse init, predict returns ~0
        auto& mlp = arms_[actionId];
        return mlp.predict(features);
    }
    return it->second.predict(features);
}

void StreamRLEngine::trainArm(const std::string& actionId, const double* features, double reward) {
    std::lock_guard<std::mutex> lock(mu_);
    arms_[actionId].update(features, reward);
}

void StreamRLEngine::buildFeatures(const ContextMap& ctx, double* out) {
    std::memset(out, 0, sizeof(double) * STREAM_FEAT_DIM);

    // ==================== 7-Tuple Encoded (28 dims) ====================

    // [0-1] hour sin/cos
    double hour = 12.0;
    auto it = ctx.find("hour");
    if (it != ctx.end()) hour = safe_stod(it->second, 12.0);
    out[0] = std::sin(2.0 * M_PI * hour / 24.0);
    out[1] = std::cos(2.0 * M_PI * hour / 24.0);

    // [2-3] dayType one-hot: weekend, holiday (workday = both 0)
    it = ctx.find("ps_dayType");
    if (it != ctx.end()) {
        out[2] = (it->second == "weekend") ? 1.0 : 0.0;
        out[3] = (it->second == "holiday") ? 1.0 : 0.0;
    } else {
        it = ctx.find("isWeekend");
        out[2] = (it != ctx.end() && it->second == "true") ? 1.0 : 0.0;
        out[3] = 0.0;
    }

    // [4-12] location one-hot (9): home,work,commute,restaurant,gym,transit_hub,shopping,outdoor,cafe
    it = ctx.find("ps_location");
    if (it != ctx.end()) {
        const auto& loc = it->second;
        out[4]  = (loc == "home") ? 1.0 : 0.0;
        out[5]  = (loc == "work") ? 1.0 : 0.0;
        out[6]  = (loc == "commute") ? 1.0 : 0.0;
        out[7]  = (loc == "restaurant") ? 1.0 : 0.0;
        out[8]  = (loc == "gym") ? 1.0 : 0.0;
        out[9]  = (loc == "transit_hub") ? 1.0 : 0.0;
        out[10] = (loc == "shopping") ? 1.0 : 0.0;
        out[11] = (loc == "outdoor") ? 1.0 : 0.0;
        out[12] = (loc == "cafe") ? 1.0 : 0.0;
    } else {
        // Fallback: try to infer from geofence/wifiGeofence
        it = ctx.find("wifiGeofence");
        if (it != ctx.end()) {
            const auto& wg = it->second;
            out[4]  = (wg == "home") ? 1.0 : 0.0;
            out[5]  = (wg == "work") ? 1.0 : 0.0;
            out[7]  = (wg == "restaurant") ? 1.0 : 0.0;
            out[8]  = (wg == "gym") ? 1.0 : 0.0;
            out[9]  = (wg == "transit") ? 1.0 : 0.0;
            out[10] = (wg == "shopping") ? 1.0 : 0.0;
            out[12] = (wg == "cafe") ? 1.0 : 0.0;
        }
    }

    // [13-18] motion one-hot (6): stationary,walking,running,cycling,driving,transit
    std::string motion = "stationary";
    it = ctx.find("ps_motion");
    if (it != ctx.end() && !it->second.empty()) {
        motion = it->second;
    } else {
        it = ctx.find("motionState");
        if (it != ctx.end()) motion = it->second;
    }
    out[13] = (motion == "stationary") ? 1.0 : 0.0;
    out[14] = (motion == "walking") ? 1.0 : 0.0;
    out[15] = (motion == "running") ? 1.0 : 0.0;
    out[16] = (motion == "cycling") ? 1.0 : 0.0;
    out[17] = (motion == "driving") ? 1.0 : 0.0;
    out[18] = (motion == "transit") ? 1.0 : 0.0;

    // [19-23] phone one-hot (5): in_use,on_desk,in_pocket,charging,unknown
    it = ctx.find("ps_phone");
    if (it != ctx.end()) {
        const auto& ph = it->second;
        out[19] = (ph == "in_use") ? 1.0 : 0.0;
        out[20] = (ph == "on_desk") ? 1.0 : 0.0;
        out[21] = (ph == "in_pocket") ? 1.0 : 0.0;
        out[22] = (ph == "charging") ? 1.0 : 0.0;
        out[23] = (ph == "unknown") ? 1.0 : 0.0;
    } else {
        // Fallback from isCharging
        it = ctx.find("isCharging");
        if (it != ctx.end() && it->second == "true") out[22] = 1.0;
    }

    // [24-25] light: ordinal + dark_flag
    it = ctx.find("ps_light");
    if (it != ctx.end()) {
        const auto& lt = it->second;
        if (lt == "dark")        { out[24] = 0.0;  out[25] = 1.0; }
        else if (lt == "dim")    { out[24] = 0.33; out[25] = 0.0; }
        else if (lt == "normal") { out[24] = 0.67; out[25] = 0.0; }
        else if (lt == "bright") { out[24] = 1.0;  out[25] = 0.0; }
    } else {
        out[24] = 0.5; // default
    }

    // [26-27] sound: ordinal + has_voice
    it = ctx.find("ps_sound");
    if (it != ctx.end()) {
        const auto& snd = it->second;
        if (snd == "silent")      out[26] = 0.0;
        else if (snd == "quiet")  out[26] = 0.25;
        else if (snd == "normal") out[26] = 0.5;
        else if (snd == "noisy")  out[26] = 1.0;
    } else {
        out[26] = 0.5;
    }
    // has_voice: not directly available yet, default 0
    out[27] = 0.0;

    // ==================== Scenario Context (6 dims) ====================

    // [28] has_active_scenario
    it = ctx.find("ps_scenario");
    out[28] = (it != ctx.end() && !it->second.empty()) ? 1.0 : 0.0;

    // [29] chain_position (step/total → 0~1)
    it = ctx.find("ps_chainPosition");
    if (it != ctx.end()) {
        auto slashPos = it->second.find('/');
        if (slashPos != std::string::npos) {
            double step = safe_stod(it->second.substr(0, slashPos), 0.0);
            double total = safe_stod(it->second.substr(slashPos + 1), 1.0);
            out[29] = (total > 0) ? step / total : 0.0;
        }
    }

    // [30] scenario_category_hash (category → ordinal 0~1)
    it = ctx.find("ps_scenarioCategory");
    if (it != ctx.end()) {
        const auto& cat = it->second;
        if (cat == "morning")       out[30] = 0.05;
        else if (cat == "commute")  out[30] = 0.15;
        else if (cat == "work")     out[30] = 0.25;
        else if (cat == "home")     out[30] = 0.35;
        else if (cat == "sleep")    out[30] = 0.45;
        else if (cat == "exercise") out[30] = 0.55;
        else if (cat == "dining")   out[30] = 0.65;
        else if (cat == "shopping") out[30] = 0.70;
        else if (cat == "travel")   out[30] = 0.80;
        else if (cat == "social")   out[30] = 0.85;
        else if (cat == "health")   out[30] = 0.90;
        else if (cat == "device")   out[30] = 0.95;
    }

    // [31] is_routine (from StateTransitionTracker)
    it = ctx.find("is_routine_transition");
    if (it != ctx.end()) out[31] = safe_stod(it->second, 0.0);

    // [32] time_in_state_norm: min(dur/240, 1.0)
    it = ctx.find("time_in_current_state_min");
    if (it != ctx.end()) out[32] = safe_stod(it->second, 0.0);

    // [33] battery_norm
    it = ctx.find("batteryLevel");
    out[33] = (it != ctx.end()) ? safe_stod(it->second, 50.0) / 100.0 : 0.5;
}

int StreamRLEngine::getArmSamples(const std::string& actionId) const {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = arms_.find(actionId);
    return (it != arms_.end()) ? it->second.samples() : 0;
}

std::string StreamRLEngine::getSummaryJson() const {
    std::lock_guard<std::mutex> lock(mu_);
    std::ostringstream ss;
    int totalArms = static_cast<int>(arms_.size());
    int totalSamples = 0;
    for (const auto& [id, mlp] : arms_) {
        totalSamples += mlp.samples();
    }
    ss << "{\"totalArms\":" << totalArms
       << ",\"totalSamples\":" << totalSamples
       << ",\"arms\":[";
    bool first = true;
    for (const auto& [id, mlp] : arms_) {
        if (!first) ss << ",";
        first = false;
        ss << "{\"id\":\"" << id << "\""
           << ",\"samples\":" << mlp.samples()
           << ",\"avgReward\":" << mlp.avgReward()
           << "}";
    }
    ss << "]}";
    return ss.str();
}

std::string StreamRLEngine::exportJson() const {
    std::lock_guard<std::mutex> lock(mu_);
    std::ostringstream ss;
    ss << "{\"arms\":{";
    bool first = true;
    for (const auto& [id, mlp] : arms_) {
        if (!first) ss << ",";
        first = false;
        ss << "\"" << id << "\":" << mlp.exportJson();
    }
    ss << "}}";
    return ss.str();
}

void StreamRLEngine::importJson(const std::string& json) {
    std::lock_guard<std::mutex> lock(mu_);
    arms_.clear();

    // Find "arms":{ ... }
    auto armsPos = json.find("\"arms\"");
    if (armsPos == std::string::npos) return;
    auto bracePos = json.find('{', armsPos + 6);
    if (bracePos == std::string::npos) return;

    size_t pos = bracePos + 1;
    while (pos < json.size()) {
        // Find next arm key: "armId"
        auto keyStart = json.find('"', pos);
        if (keyStart == std::string::npos) break;
        auto keyEnd = json.find('"', keyStart + 1);
        if (keyEnd == std::string::npos) break;
        std::string armId = json.substr(keyStart + 1, keyEnd - keyStart - 1);

        // Find the arm's JSON object
        auto objStart = json.find('{', keyEnd + 1);
        if (objStart == std::string::npos) break;
        int depth = 1;
        size_t objEnd = objStart + 1;
        while (objEnd < json.size() && depth > 0) {
            if (json[objEnd] == '{') depth++;
            else if (json[objEnd] == '}') depth--;
            objEnd++;
        }
        std::string armJson = json.substr(objStart, objEnd - objStart);

        StreamMLP mlp;
        mlp.importJson(armJson);
        arms_[armId] = std::move(mlp);

        pos = objEnd;
        // Skip comma or end
        while (pos < json.size() && (json[pos] == ',' || json[pos] == ' ')) pos++;
        if (pos < json.size() && json[pos] == '}') break;
    }
}

}  // namespace context_engine
