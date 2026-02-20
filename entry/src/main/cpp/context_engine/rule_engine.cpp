/**
 * rule_engine.cpp — 规则引擎核心
 */
#include "context_engine.h"
#include <algorithm>
#include <chrono>
#include <sstream>

namespace context_engine {

RuleEngine::RuleEngine() : mab_(0.1) {}
RuleEngine::~RuleEngine() = default;

bool RuleEngine::loadRules(const std::vector<Rule>& rules) {
    std::lock_guard<std::mutex> lock(mu_);
    rules_ = rules;
    compileTree();
    return true;
}

bool RuleEngine::addRule(const Rule& rule) {
    std::lock_guard<std::mutex> lock(mu_);
    // Check for duplicate
    for (auto& r : rules_) {
        if (r.id == rule.id) {
            r = rule;  // update existing
            compileTree();
            return true;
        }
    }
    rules_.push_back(rule);
    compileTree();
    return true;
}

bool RuleEngine::removeRule(const std::string& ruleId) {
    std::lock_guard<std::mutex> lock(mu_);
    auto it = std::remove_if(rules_.begin(), rules_.end(),
        [&](const Rule& r) { return r.id == ruleId; });
    if (it == rules_.end()) return false;
    rules_.erase(it, rules_.end());
    compileTree();
    return true;
}

static int64_t nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

void RuleEngine::evaluateNode(int nodeIdx, const ContextMap& ctx,
                               std::vector<MatchResult>& results) {
    if (nodeIdx < 0 || nodeIdx >= static_cast<int>(tree_.size())) return;
    const auto& node = tree_[nodeIdx];

    if (node.splitKey.empty()) {
        // Leaf node: evaluate all candidate rules
        int64_t now = nowMs();
        for (int rIdx : node.ruleIndices) {
            const auto& rule = rules_[rIdx];
            if (!rule.enabled) continue;

            // Check cooldown
            auto lastIt = lastFired_.find(rule.id);
            if (lastIt != lastFired_.end() && rule.cooldownMs > 0) {
                if (now - lastIt->second < rule.cooldownMs) continue;
            }

            // Soft match all conditions
            double confidence = 1.0;
            for (const auto& cond : rule.conditions) {
                double match = softMatch(cond, ctx);
                confidence *= match;
                if (confidence < 0.01) break;  // early exit
            }

            if (confidence > 0.1) {
                results.push_back({rule.id, confidence, rule.action});
            }
        }
        return;
    }

    // Internal node: follow matching branch
    auto ctxIt = ctx.find(node.splitKey);
    if (ctxIt != ctx.end()) {
        for (const auto& [value, childIdx] : node.branches) {
            if (ctxIt->second == value) {
                evaluateNode(childIdx, ctx, results);
                return;
            }
        }
    }

    // No match or missing key → follow default branch
    if (node.defaultChild >= 0) {
        evaluateNode(node.defaultChild, ctx, results);
    }
}

std::vector<MatchResult> RuleEngine::evaluate(const ContextMap& ctx, int maxResults) {
    std::lock_guard<std::mutex> lock(mu_);

    if (tree_.empty()) {
        // No tree compiled, evaluate all rules linearly
        std::vector<MatchResult> results;
        int64_t now = nowMs();
        for (const auto& rule : rules_) {
            if (!rule.enabled) continue;
            auto lastIt = lastFired_.find(rule.id);
            if (lastIt != lastFired_.end() && rule.cooldownMs > 0) {
                if (now - lastIt->second < rule.cooldownMs) continue;
            }
            double confidence = 1.0;
            for (const auto& cond : rule.conditions) {
                confidence *= softMatch(cond, ctx);
                if (confidence < 0.01) break;
            }
            if (confidence > 0.1) {
                results.push_back({rule.id, confidence, rule.action});
            }
        }
        // Sort by confidence × priority
        std::sort(results.begin(), results.end(), [&](const MatchResult& a, const MatchResult& b) {
            auto ra = std::find_if(rules_.begin(), rules_.end(), [&](const Rule& r) { return r.id == a.ruleId; });
            auto rb = std::find_if(rules_.begin(), rules_.end(), [&](const Rule& r) { return r.id == b.ruleId; });
            double pa = (ra != rules_.end()) ? ra->priority : 1.0;
            double pb = (rb != rules_.end()) ? rb->priority : 1.0;
            return a.confidence * pa > b.confidence * pb;
        });
        if (static_cast<int>(results.size()) > maxResults) results.resize(maxResults);
        return results;
    }

    std::vector<MatchResult> results;
    evaluateNode(0, ctx, results);

    // Sort by confidence × priority (descending)
    std::sort(results.begin(), results.end(), [&](const MatchResult& a, const MatchResult& b) {
        auto ra = std::find_if(rules_.begin(), rules_.end(), [&](const Rule& r) { return r.id == a.ruleId; });
        auto rb = std::find_if(rules_.begin(), rules_.end(), [&](const Rule& r) { return r.id == b.ruleId; });
        double pa = (ra != rules_.end()) ? ra->priority : 1.0;
        double pb = (rb != rules_.end()) ? rb->priority : 1.0;
        return a.confidence * pa > b.confidence * pb;
    });

    if (static_cast<int>(results.size()) > maxResults) {
        results.resize(maxResults);
    }

    // Update lastFired timestamps
    int64_t now = nowMs();
    for (const auto& r : results) {
        lastFired_[r.ruleId] = now;
    }

    return results;
}

std::string RuleEngine::exportRulesJson() const {
    std::lock_guard<std::mutex> lock(mu_);
    std::ostringstream ss;
    ss << "[";
    for (size_t i = 0; i < rules_.size(); i++) {
        const auto& r = rules_[i];
        if (i > 0) ss << ",";
        ss << "{\"id\":\"" << r.id << "\",\"name\":\"" << r.name
           << "\",\"enabled\":" << (r.enabled ? "true" : "false")
           << ",\"priority\":" << r.priority
           << ",\"conditions\":[";
        for (size_t j = 0; j < r.conditions.size(); j++) {
            if (j > 0) ss << ",";
            ss << "{\"key\":\"" << r.conditions[j].key
               << "\",\"op\":\"" << r.conditions[j].op
               << "\",\"value\":\"" << r.conditions[j].value << "\"}";
        }
        ss << "],\"action\":{\"id\":\"" << r.action.id
           << "\",\"type\":\"" << r.action.type
           << "\",\"payload\":\"" << r.action.payload << "\"}}";
    }
    ss << "]";
    return ss.str();
}

}  // namespace context_engine
