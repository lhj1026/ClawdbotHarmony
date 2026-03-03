/**
 * linucb.cpp — LinUCB Contextual Bandit
 *
 * Replaces epsilon-greedy MAB with a contextual bandit that uses
 * ridge regression per arm to learn context-dependent reward models.
 *
 * Feature vector (d=8):
 *   [hour_sin, hour_cos, battery/100, isCharging, isWeekend,
 *    motion_stationary, motion_active, motion_vehicle]
 *
 * Algorithm:
 *   A_a = d×d matrix (init I_d), b_a = d-vector (init 0)
 *   theta_a = A_a^{-1} * b_a
 *   UCB_a = theta_a^T * x + alpha * sqrt(x^T * A_a^{-1} * x)
 *   Update: A_a += x*x^T, b_a += reward*x
 */
#include "context_engine.h"
#include <cmath>
#include <algorithm>
#include <sstream>
#include <cstring>

namespace context_engine {

// ============================================================
// Small fixed-size matrix operations (d×d where d=LINUCB_DIM)
// ============================================================

namespace {

using Vec = std::array<double, LINUCB_DIM>;
using Mat = std::array<std::array<double, LINUCB_DIM>, LINUCB_DIM>;

Mat identityMat() {
    Mat m{};
    for (int i = 0; i < LINUCB_DIM; i++)
        m[i][i] = 1.0;
    return m;
}

Vec zeroVec() {
    Vec v{};
    return v;
}

// Matrix-vector multiply: result = M * v
Vec matVecMul(const Mat& M, const Vec& v) {
    Vec result{};
    for (int i = 0; i < LINUCB_DIM; i++) {
        double sum = 0.0;
        for (int j = 0; j < LINUCB_DIM; j++)
            sum += M[i][j] * v[j];
        result[i] = sum;
    }
    return result;
}

// Dot product
double dot(const Vec& a, const Vec& b) {
    double sum = 0.0;
    for (int i = 0; i < LINUCB_DIM; i++)
        sum += a[i] * b[i];
    return sum;
}

// Outer product: result = a * b^T (adds to existing matrix)
void addOuterProduct(Mat& M, const Vec& a, const Vec& b) {
    for (int i = 0; i < LINUCB_DIM; i++)
        for (int j = 0; j < LINUCB_DIM; j++)
            M[i][j] += a[i] * b[j];
}

// Matrix inverse via Gauss-Jordan elimination (in-place on augmented matrix)
// Returns false if singular (should not happen with ridge regression)
bool invertMat(const Mat& src, Mat& inv) {
    constexpr int d = LINUCB_DIM;
    // Augmented matrix [src | I]
    double aug[d][2 * d];
    for (int i = 0; i < d; i++) {
        for (int j = 0; j < d; j++) {
            aug[i][j] = src[i][j];
            aug[i][j + d] = (i == j) ? 1.0 : 0.0;
        }
    }

    for (int col = 0; col < d; col++) {
        // Partial pivoting
        int maxRow = col;
        double maxVal = std::abs(aug[col][col]);
        for (int row = col + 1; row < d; row++) {
            double v = std::abs(aug[row][col]);
            if (v > maxVal) { maxVal = v; maxRow = row; }
        }
        if (maxVal < 1e-12) return false;  // singular
        if (maxRow != col) {
            for (int j = 0; j < 2 * d; j++)
                std::swap(aug[col][j], aug[maxRow][j]);
        }

        // Scale pivot row
        double pivot = aug[col][col];
        for (int j = 0; j < 2 * d; j++)
            aug[col][j] /= pivot;

        // Eliminate column
        for (int row = 0; row < d; row++) {
            if (row == col) continue;
            double factor = aug[row][col];
            for (int j = 0; j < 2 * d; j++)
                aug[row][j] -= factor * aug[col][j];
        }
    }

    // Extract inverse
    for (int i = 0; i < d; i++)
        for (int j = 0; j < d; j++)
            inv[i][j] = aug[i][j + d];

    return true;
}

}  // namespace

// ============================================================
// LinUCB implementation
// ============================================================

LinUCB::LinUCB(double alpha) : alpha_(alpha) {}

Vec LinUCB::buildFeatureVec(const ContextMap& ctx) const {
    Vec x{};

    // [0-1] hour → sin/cos encoding
    double hour = 12.0;
    auto it = ctx.find("hour");
    if (it != ctx.end()) {
        hour = safe_stod(it->second, 12.0);
    }
    x[0] = std::sin(2.0 * M_PI * hour / 24.0);
    x[1] = std::cos(2.0 * M_PI * hour / 24.0);

    // [2] battery / 100
    double battery = 50.0;
    it = ctx.find("batteryLevel");
    if (it != ctx.end()) {
        battery = safe_stod(it->second, 50.0);
    }
    x[2] = battery / 100.0;

    // [3] isCharging
    it = ctx.find("isCharging");
    x[3] = (it != ctx.end() && it->second == "true") ? 1.0 : 0.0;

    // [4-5] dayType one-hot: weekend, holiday (workday = both 0)
    it = ctx.find("ps_dayType");
    if (it != ctx.end()) {
        x[4] = (it->second == "weekend") ? 1.0 : 0.0;
        x[5] = (it->second == "holiday") ? 1.0 : 0.0;
    } else {
        // Fallback to isWeekend
        it = ctx.find("isWeekend");
        x[4] = (it != ctx.end() && it->second == "true") ? 1.0 : 0.0;
        x[5] = 0.0;
    }

    // [6-10] motionState 5-dim one-hot (from ps_motion or motionState)
    std::string motion = "stationary";
    it = ctx.find("ps_motion");
    if (it != ctx.end() && !it->second.empty()) {
        motion = it->second;
    } else {
        it = ctx.find("motionState");
        if (it != ctx.end()) motion = it->second;
    }
    x[6]  = (motion == "stationary") ? 1.0 : 0.0;
    x[7]  = (motion == "walking") ? 1.0 : 0.0;
    x[8]  = (motion == "running") ? 1.0 : 0.0;
    x[9]  = (motion == "cycling") ? 1.0 : 0.0;
    x[10] = (motion == "driving" || motion == "transit") ? 1.0 : 0.0;

    // [11] light ordinal: dark=0, dim=0.33, normal=0.67, bright=1
    it = ctx.find("ps_light");
    if (it != ctx.end()) {
        if (it->second == "dark") x[11] = 0.0;
        else if (it->second == "dim") x[11] = 0.33;
        else if (it->second == "normal") x[11] = 0.67;
        else if (it->second == "bright") x[11] = 1.0;
    } else {
        x[11] = 0.5;
    }

    // [12] sound ordinal: silent=0, quiet=0.25, normal=0.5, noisy=1
    it = ctx.find("ps_sound");
    if (it != ctx.end()) {
        if (it->second == "silent") x[12] = 0.0;
        else if (it->second == "quiet") x[12] = 0.25;
        else if (it->second == "normal") x[12] = 0.5;
        else if (it->second == "noisy") x[12] = 1.0;
    } else {
        x[12] = 0.5;
    }

    // [13] has_scenario
    it = ctx.find("ps_scenario");
    x[13] = (it != ctx.end() && !it->second.empty()) ? 1.0 : 0.0;

    return x;
}

int LinUCB::select(const std::vector<std::string>& actionIds, const ContextMap& ctx) {
    if (actionIds.empty()) return -1;

    std::lock_guard<std::mutex> lock(mu_);

    Vec x = buildFeatureVec(ctx);

    int bestIdx = 0;
    double bestUcb = -1e18;

    for (int i = 0; i < static_cast<int>(actionIds.size()); i++) {
        const auto& id = actionIds[i];
        auto armIt = arms_.find(id);

        // Lazy-init arm if needed
        if (armIt == arms_.end()) {
            LinUCBArm arm;
            arm.A = identityMat();
            arm.b = zeroVec();
            arms_[id] = arm;
            armIt = arms_.find(id);
        }

        const auto& arm = armIt->second;

        // Compute A^{-1}
        Mat Ainv;
        if (!invertMat(arm.A, Ainv)) {
            // Fallback: treat as identity (shouldn't happen with ridge)
            Ainv = identityMat();
        }

        // theta = A^{-1} * b
        Vec theta = matVecMul(Ainv, arm.b);

        // UCB = theta^T * x + alpha * sqrt(x^T * A^{-1} * x)
        double exploit = dot(theta, x);
        Vec Ainv_x = matVecMul(Ainv, x);
        double explore = alpha_ * std::sqrt(std::max(0.0, dot(x, Ainv_x)));

        double ucb = exploit + explore;
        if (ucb > bestUcb) {
            bestUcb = ucb;
            bestIdx = i;
        }
    }

    return bestIdx;
}

void LinUCB::update(const std::string& actionId, double reward, const ContextMap& ctx) {
    std::lock_guard<std::mutex> lock(mu_);

    Vec x = buildFeatureVec(ctx);

    auto armIt = arms_.find(actionId);
    if (armIt == arms_.end()) {
        LinUCBArm arm;
        arm.A = identityMat();
        arm.b = zeroVec();
        arms_[actionId] = arm;
        armIt = arms_.find(actionId);
    }

    auto& arm = armIt->second;

    // A_a += x * x^T
    addOuterProduct(arm.A, x, x);

    // b_a += reward * x
    for (int i = 0; i < LINUCB_DIM; i++)
        arm.b[i] += reward * x[i];
}

std::string LinUCB::exportJson() const {
    std::lock_guard<std::mutex> lock(mu_);

    std::ostringstream ss;
    ss << "{\"alpha\":" << alpha_ << ",\"arms\":{";
    bool firstArm = true;
    for (const auto& [id, arm] : arms_) {
        if (!firstArm) ss << ",";
        firstArm = false;
        ss << "\"" << id << "\":{\"A\":[";
        for (int i = 0; i < LINUCB_DIM; i++) {
            if (i > 0) ss << ",";
            ss << "[";
            for (int j = 0; j < LINUCB_DIM; j++) {
                if (j > 0) ss << ",";
                ss << arm.A[i][j];
            }
            ss << "]";
        }
        ss << "],\"b\":[";
        for (int i = 0; i < LINUCB_DIM; i++) {
            if (i > 0) ss << ",";
            ss << arm.b[i];
        }
        ss << "]}";
    }
    ss << "}}";
    return ss.str();
}

void LinUCB::importJson(const std::string& json) {
    std::lock_guard<std::mutex> lock(mu_);

    // Parse alpha
    auto alphaPos = json.find("\"alpha\"");
    if (alphaPos != std::string::npos) {
        auto colon = json.find(':', alphaPos);
        if (colon != std::string::npos) {
            alpha_ = safe_stod(json.substr(colon + 1), alpha_);
        }
    }

    // Parse arms
    auto armsPos = json.find("\"arms\"");
    if (armsPos == std::string::npos) return;

    auto armsObjStart = json.find('{', armsPos + 6);
    if (armsObjStart == std::string::npos) return;

    // Find matching closing brace for the arms object
    int depth = 1;
    size_t armsObjEnd = armsObjStart + 1;
    while (armsObjEnd < json.size() && depth > 0) {
        if (json[armsObjEnd] == '{') depth++;
        else if (json[armsObjEnd] == '}') depth--;
        armsObjEnd++;
    }
    std::string armsSection = json.substr(armsObjStart, armsObjEnd - armsObjStart);

    arms_.clear();

    // Parse each arm: "armId":{...}
    size_t pos = 1;  // skip opening {
    while (pos < armsSection.size()) {
        // Find arm id
        auto qStart = armsSection.find('"', pos);
        if (qStart == std::string::npos) break;
        auto qEnd = armsSection.find('"', qStart + 1);
        if (qEnd == std::string::npos) break;
        std::string armId = armsSection.substr(qStart + 1, qEnd - qStart - 1);

        // Find the arm's object
        auto objStart = armsSection.find('{', qEnd);
        if (objStart == std::string::npos) break;
        int d2 = 1;
        size_t objEnd = objStart + 1;
        while (objEnd < armsSection.size() && d2 > 0) {
            if (armsSection[objEnd] == '{') d2++;
            else if (armsSection[objEnd] == '}') d2--;
            objEnd++;
        }
        std::string armJson = armsSection.substr(objStart, objEnd - objStart);

        LinUCBArm arm;
        arm.A = identityMat();
        arm.b = zeroVec();

        // Parse A matrix: "A":[[...],[...],...]
        auto aPos = armJson.find("\"A\"");
        if (aPos != std::string::npos) {
            auto arrStart = armJson.find('[', aPos);
            if (arrStart != std::string::npos) {
                size_t p = arrStart + 1;
                for (int row = 0; row < LINUCB_DIM && p < armJson.size(); row++) {
                    auto rowStart = armJson.find('[', p);
                    if (rowStart == std::string::npos) break;
                    auto rowEnd = armJson.find(']', rowStart);
                    if (rowEnd == std::string::npos) break;
                    std::string rowStr = armJson.substr(rowStart + 1, rowEnd - rowStart - 1);
                    // Parse comma-separated doubles
                    std::istringstream iss(rowStr);
                    std::string token;
                    int col = 0;
                    while (std::getline(iss, token, ',') && col < LINUCB_DIM) {
                        arm.A[row][col] = safe_stod(token, arm.A[row][col]);
                        col++;
                    }
                    p = rowEnd + 1;
                }
            }
        }

        // Parse b vector: "b":[...]
        auto bPos = armJson.find("\"b\"");
        if (bPos != std::string::npos) {
            auto arrStart = armJson.find('[', bPos);
            if (arrStart != std::string::npos) {
                auto arrEnd = armJson.find(']', arrStart);
                if (arrEnd != std::string::npos) {
                    std::string bStr = armJson.substr(arrStart + 1, arrEnd - arrStart - 1);
                    std::istringstream iss(bStr);
                    std::string token;
                    int idx = 0;
                    while (std::getline(iss, token, ',') && idx < LINUCB_DIM) {
                        arm.b[idx] = safe_stod(token, arm.b[idx]);
                        idx++;
                    }
                }
            }
        }

        arms_[armId] = arm;
        pos = objEnd;
    }
}

}  // namespace context_engine
