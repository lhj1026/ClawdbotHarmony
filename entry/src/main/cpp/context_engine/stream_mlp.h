/**
 * stream_mlp.h — Stream Deep RL 在线强化学习引擎
 *
 * Per-Arm StreamMLP: 34→128→64→1 with:
 *   - 34-dim input: 28 static context (7-tuple encoded) + 6 scenario context
 *   - Sparse Initialization (90% zero)
 *   - Layer Normalization (non-learnable)
 *   - ObGD (Overshooting-Bounded Gradient Descent)
 *   - Welford observation/reward normalization
 *
 * Feature vector layout (v2 — 7-Tuple Physical State):
 *   [0-1]   hour sin/cos (2)
 *   [2-3]   dayType one-hot: weekend, holiday (2) — workday = both 0
 *   [4-12]  location one-hot (9): home,work,commute,restaurant,gym,transit_hub,shopping,outdoor,cafe
 *   [13-18] motion one-hot (6): stationary,walking,running,cycling,driving,transit
 *   [19-23] phone one-hot (5): in_use,on_desk,in_pocket,charging,unknown
 *   [24-25] light: ordinal (1) + dark_flag (1)
 *   [26-27] sound: ordinal (1) + has_voice (1)
 *   Scenario Context (6 dims):
 *   [28]    has_active_scenario
 *   [29]    chain_position (step/total, 0~1)
 *   [30]    scenario_category_hash (0~1)
 *   [31]    is_routine (from StateTransitionTracker)
 *   [32]    time_in_state_norm (capped 0~1)
 *   [33]    battery_norm
 *
 * Reference: Elsayed et al. 2024 "Streaming Deep Reinforcement Learning Finally Works"
 */
#pragma once

#include <array>
#include <string>
#include <unordered_map>
#include <mutex>
#include <cmath>
#include <random>
#include <cstring>

namespace context_engine {

// Forward declaration
using ContextMap = std::unordered_map<std::string, std::string>;

// ============================================================
// Constants
// ============================================================

constexpr int STREAM_FEAT_DIM = 34;   // 28 static (7-tuple encoded) + 6 scenario context
constexpr int STREAM_H1 = 128;        // proportionally scaled
constexpr int STREAM_H2 = 64;
constexpr double STREAM_LR = 0.01;
constexpr double STREAM_KAPPA = 2.0;
constexpr double STREAM_WEIGHT_DECAY = 1e-4;
constexpr double STREAM_LEAKY_ALPHA = 0.01;
constexpr double SPARSE_RATIO = 0.9;
constexpr int STREAM_MIN_SAMPLES = 5;
constexpr int STREAM_RAMP_SAMPLES = 20;

// ============================================================
// Running statistics (Welford online algorithm)
// ============================================================

struct RunningStats {
    double mean[STREAM_FEAT_DIM];
    double m2[STREAM_FEAT_DIM];   // sum of squared deviations
    int count;

    RunningStats();

    /** Update running stats with new observation */
    void update(const double* x);

    /** Normalize input: (x - mean) / sqrt(var + eps) */
    void normalize(const double* x, double* out) const;
};

// ============================================================
// Dense layer with sparse init and LayerNorm
// ============================================================

template<int IN, int OUT>
struct DenseLayer {
    double W[OUT][IN];
    double b[OUT];

    /** Sparse Initialization: 90% zero, 10% LeCun */
    void sparseInit(std::mt19937& rng) {
        double limit = 1.0 / std::sqrt(static_cast<double>(IN));
        std::uniform_real_distribution<double> dist(-limit, limit);
        std::uniform_real_distribution<double> maskDist(0.0, 1.0);

        for (int o = 0; o < OUT; ++o) {
            for (int i = 0; i < IN; ++i) {
                W[o][i] = (maskDist(rng) >= SPARSE_RATIO) ? dist(rng) : 0.0;
            }
            b[o] = 0.0;
        }
    }

    /** Forward pass: out = W * in + b */
    void forward(const double* in, double* out) const {
        for (int o = 0; o < OUT; ++o) {
            double sum = b[o];
            for (int i = 0; i < IN; ++i) {
                sum += W[o][i] * in[i];
            }
            out[o] = sum;
        }
    }

    /** Layer Normalization (non-learnable): normalize across the output dimension */
    static void layerNorm(double* x, int dim) {
        double mean = 0.0;
        for (int i = 0; i < dim; ++i) mean += x[i];
        mean /= dim;

        double var = 0.0;
        for (int i = 0; i < dim; ++i) {
            double d = x[i] - mean;
            var += d * d;
        }
        var /= dim;

        double invStd = 1.0 / std::sqrt(var + 1e-5);
        for (int i = 0; i < dim; ++i) {
            x[i] = (x[i] - mean) * invStd;
        }
    }

    /** LeakyReLU activation in-place */
    static void leakyRelu(double* x, int dim) {
        for (int i = 0; i < dim; ++i) {
            if (x[i] < 0.0) x[i] *= STREAM_LEAKY_ALPHA;
        }
    }
};

// ============================================================
// StreamMLP: single arm's neural network
// ============================================================

class StreamMLP {
public:
    StreamMLP();

    /** Forward pass: context features → predicted reward */
    double predict(const double* features);

    /** Single-sample online update with ObGD */
    void update(const double* features, double reward);

    /** Serialization */
    std::string exportJson() const;
    void importJson(const std::string& json);

    int samples() const { return sampleCount_; }
    double avgReward() const { return rewardMean_; }

private:
    DenseLayer<STREAM_FEAT_DIM, STREAM_H1> layer1_;
    DenseLayer<STREAM_H1, STREAM_H2> layer2_;
    DenseLayer<STREAM_H2, 1> output_;

    RunningStats inputStats_;
    double rewardMean_;
    double rewardM2_;
    int rewardCount_;
    int sampleCount_;
};

// ============================================================
// StreamRLEngine: per-arm manager
// ============================================================

class StreamRLEngine {
public:
    /** Score an arm given context features */
    double scoreArm(const std::string& actionId, const double* features);

    /** Train arm with observed reward */
    void trainArm(const std::string& actionId, const double* features, double reward);

    /** Build 25-dim feature vector from ContextMap (16 static + 9 transition) */
    static void buildFeatures(const ContextMap& ctx, double* out);

    /** Get sample count for cold-start logic */
    int getArmSamples(const std::string& actionId) const;

    /** Get summary stats as JSON: arms array with id/samples/avgReward/lastPrediction */
    std::string getSummaryJson() const;

    /** Serialization */
    std::string exportJson() const;
    void importJson(const std::string& json);

private:
    std::unordered_map<std::string, StreamMLP> arms_;
    mutable std::mutex mu_;
};

}  // namespace context_engine
