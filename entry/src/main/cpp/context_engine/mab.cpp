/**
 * mab.cpp — Multi-Armed Bandit (epsilon-greedy)
 *
 * MVP 阶段用 epsilon-greedy，Phase 2 替换为 LinUCB
 */
#include "context_engine.h"
#include <random>
#include <algorithm>

namespace context_engine {

MAB::MAB(double epsilon) : epsilon_(epsilon) {}

int MAB::select(const std::vector<std::string>& actionIds) {
    if (actionIds.empty()) return -1;

    std::lock_guard<std::mutex> lock(mu_);

    // Random generator
    static thread_local std::mt19937 gen(std::random_device{}());
    std::uniform_real_distribution<> dist(0.0, 1.0);

    // Epsilon-greedy: explore with probability epsilon
    if (dist(gen) < epsilon_) {
        std::uniform_int_distribution<> idist(0, static_cast<int>(actionIds.size()) - 1);
        return idist(gen);
    }

    // Exploit: pick the arm with highest average reward
    int bestIdx = 0;
    double bestAvg = -1e9;
    for (int i = 0; i < static_cast<int>(actionIds.size()); i++) {
        auto it = arms_.find(actionIds[i]);
        double avg = (it != arms_.end()) ? it->second.avgReward() : 0.0;
        // Bonus for unpulled arms (optimistic initialization)
        if (it == arms_.end() || it->second.pulls == 0) {
            avg = 1.0;  // optimistic: try untested actions first
        }
        if (avg > bestAvg) {
            bestAvg = avg;
            bestIdx = i;
        }
    }
    return bestIdx;
}

void MAB::update(const std::string& actionId, double reward) {
    std::lock_guard<std::mutex> lock(mu_);
    auto& arm = arms_[actionId];
    arm.pulls++;
    arm.totalReward += reward;
}

std::unordered_map<std::string, ArmStats> MAB::getStats() const {
    std::lock_guard<std::mutex> lock(mu_);
    return arms_;
}

void MAB::loadStats(const std::unordered_map<std::string, ArmStats>& stats) {
    std::lock_guard<std::mutex> lock(mu_);
    arms_ = stats;
}

}  // namespace context_engine
