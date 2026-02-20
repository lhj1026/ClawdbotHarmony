/**
 * decision_tree.cpp — 自动编译决策树
 *
 * 将 flat rules 编译为决策树:
 *   1. 统计每个 key 的出现频率
 *   2. 按 cost-aware ordering 选择 split key (便宜的特征优先)
 *   3. 递归构建子树
 *
 * Cost ordering (cheap → expensive):
 *   timeOfDay, dayOfWeek, isWeekend < motionState < batteryLevel < geofence < location
 */
#include "context_engine.h"
#include <algorithm>
#include <unordered_set>

namespace context_engine {

// Feature cost: lower = cheaper to evaluate (prefer splitting on cheap features first)
static int featureCost(const std::string& key) {
    // Time features: pure computation, zero cost
    if (key == "timeOfDay" || key == "dayOfWeek" || key == "isWeekend" ||
        key == "hour" || key == "minute") return 0;
    // Device state: already available
    if (key == "batteryLevel" || key == "isCharging" || key == "networkType") return 1;
    // Motion: sensor, low power
    if (key == "motionState" || key == "stepCount") return 2;
    // Location: GPS, higher power
    if (key == "geofence" || key == "location" || key == "latitude" || key == "longitude") return 3;
    // Unknown features: medium cost
    return 2;
}

/** Pick the best split key for a set of rules.
 *  Heuristic: maximize coverage (rules using this key) ÷ cost */
static std::string pickSplitKey(const std::vector<Rule>& rules,
                                 const std::vector<int>& indices,
                                 const std::unordered_set<std::string>& usedKeys) {
    std::unordered_map<std::string, int> keyCount;
    for (int idx : indices) {
        for (const auto& cond : rules[idx].conditions) {
            if (usedKeys.count(cond.key) == 0) {
                keyCount[cond.key]++;
            }
        }
    }

    if (keyCount.empty()) return "";

    std::string bestKey;
    double bestScore = -1.0;
    for (const auto& [key, count] : keyCount) {
        // Score = coverage / (1 + cost)
        double score = static_cast<double>(count) / (1.0 + featureCost(key));
        if (score > bestScore) {
            bestScore = score;
            bestKey = key;
        }
    }
    return bestKey;
}

void RuleEngine::compileTree() {
    tree_.clear();
    if (rules_.empty()) return;

    // All rule indices
    std::vector<int> allIndices;
    allIndices.reserve(rules_.size());
    for (int i = 0; i < static_cast<int>(rules_.size()); i++) {
        if (rules_[i].enabled) {
            allIndices.push_back(i);
        }
    }

    // BFS-style tree building with a stack
    struct BuildTask {
        std::vector<int> indices;
        std::unordered_set<std::string> usedKeys;
        int parentIdx;
        std::string branchValue;
    };

    // Reserve root node
    tree_.push_back(TreeNode{});

    std::vector<BuildTask> stack;
    stack.push_back({allIndices, {}, -1, ""});

    while (!stack.empty()) {
        auto task = std::move(stack.back());
        stack.pop_back();

        int nodeIdx = (task.parentIdx == -1) ? 0 : static_cast<int>(tree_.size());
        if (task.parentIdx != -1) {
            tree_.push_back(TreeNode{});
        }

        // Find best split key
        std::string splitKey = pickSplitKey(rules_, task.indices, task.usedKeys);

        // Leaf if: no good split, or few rules, or max depth reached
        if (splitKey.empty() || task.indices.size() <= 2 || task.usedKeys.size() >= 5) {
            // Leaf node
            tree_[nodeIdx].splitKey = "";
            tree_[nodeIdx].defaultChild = -1;
            tree_[nodeIdx].ruleIndices = task.indices;
            continue;
        }

        // Internal node: group rules by their condition value for splitKey
        tree_[nodeIdx].splitKey = splitKey;
        tree_[nodeIdx].defaultChild = -1;

        std::unordered_map<std::string, std::vector<int>> groups;
        std::vector<int> noCondition;  // rules that don't use this key

        for (int idx : task.indices) {
            bool found = false;
            for (const auto& cond : rules_[idx].conditions) {
                if (cond.key == splitKey && cond.op == "eq") {
                    groups[cond.value].push_back(idx);
                    found = true;
                    break;
                }
            }
            if (!found) {
                noCondition.push_back(idx);
            }
        }

        auto childUsedKeys = task.usedKeys;
        childUsedKeys.insert(splitKey);

        // Create child nodes for each branch value
        for (auto& [value, ruleIdxs] : groups) {
            // Add noCondition rules to every branch (they match regardless)
            for (int nc : noCondition) ruleIdxs.push_back(nc);
            int childIdx = static_cast<int>(tree_.size());
            tree_[nodeIdx].branches.emplace_back(value, childIdx);
            stack.push_back({std::move(ruleIdxs), childUsedKeys, nodeIdx, value});
        }

        // Default branch for values not seen in any rule
        if (!noCondition.empty()) {
            int defaultIdx = static_cast<int>(tree_.size());
            tree_[nodeIdx].defaultChild = defaultIdx;
            stack.push_back({noCondition, childUsedKeys, nodeIdx, "__default__"});
        }
    }
}

}  // namespace context_engine
