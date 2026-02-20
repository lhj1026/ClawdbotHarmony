/**
 * rule_engine.cpp — 规则引擎核心
 *
 * Features:
 *   - Decision tree traversal + soft matching
 *   - Event buffer for "recent" and "sequence" (within) conditions
 *   - Enhanced cooldown: per-rule, per-category, global rate limit
 */
#include "context_engine.h"
#include <algorithm>
#include <chrono>
#include <sstream>

namespace context_engine {

// ============================================================
// EventBuffer implementation
// ============================================================

EventBuffer::EventBuffer(size_t maxSize) : maxSize_(maxSize) {}

void EventBuffer::push(const ContextEvent& event) {
    std::lock_guard<std::mutex> lock(mu_);
    expireOld();
    if (events_.size() >= maxSize_) {
        events_.pop_front();
    }
    events_.push_back(event);
}

bool EventBuffer::hasRecent(const std::string& eventType, int64_t withinMs) const {
    std::lock_guard<std::mutex> lock(mu_);
    int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    int64_t cutoff = now - withinMs;

    // Search backward (most recent first) for efficiency
    for (auto it = events_.rbegin(); it != events_.rend(); ++it) {
        if (it->timestampMs < cutoff) break;  // all older events are before cutoff
        if (it->eventType == eventType) return true;
    }
    return false;
}

bool EventBuffer::hasSequence(const std::string& eventA, const std::string& eventB,
                               int64_t withinMs) const {
    std::lock_guard<std::mutex> lock(mu_);
    int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    int64_t cutoff = now - withinMs;

    // Find latest B within window, then check if A happened before it
    int64_t latestB = -1;
    for (auto it = events_.rbegin(); it != events_.rend(); ++it) {
        if (it->timestampMs < cutoff) break;
        if (it->eventType == eventB) {
            latestB = it->timestampMs;
            break;
        }
    }
    if (latestB < 0) return false;

    // Check if A happened before B and within window
    for (auto it = events_.rbegin(); it != events_.rend(); ++it) {
        if (it->timestampMs < cutoff) break;
        if (it->eventType == eventA && it->timestampMs < latestB) {
            return true;
        }
    }
    return false;
}

size_t EventBuffer::size() const {
    std::lock_guard<std::mutex> lock(mu_);
    return events_.size();
}

void EventBuffer::expireOld() {
    // Caller must hold mu_
    int64_t now = std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
    int64_t cutoff = now - MAX_AGE_MS;
    while (!events_.empty() && events_.front().timestampMs < cutoff) {
        events_.pop_front();
    }
}

// ============================================================
// RuleEngine implementation
// ============================================================

RuleEngine::RuleEngine() : mab_(0.1), eventBuffer_(100) {}
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

// Split "event:geofence_enter" → "geofence_enter"
static std::string extractAfterPrefix(const std::string& key, const std::string& prefix) {
    if (key.size() > prefix.size() && key.substr(0, prefix.size()) == prefix) {
        return key.substr(prefix.size());
    }
    return "";
}

// Split "sequence:typeA,typeB" → {"typeA", "typeB"}
static std::pair<std::string, std::string> extractSequencePair(const std::string& key) {
    auto body = extractAfterPrefix(key, "sequence:");
    auto comma = body.find(',');
    if (comma == std::string::npos) return {"", ""};
    return {body.substr(0, comma), body.substr(comma + 1)};
}

void RuleEngine::pushEvent(const ContextEvent& event) {
    eventBuffer_.push(event);
}

void RuleEngine::setLimits(const RateLimits& limits) {
    std::lock_guard<std::mutex> lock(mu_);
    rateLimits_ = limits;
}

double RuleEngine::matchCondition(const Condition& cond, const ContextMap& ctx) {
    // Handle temporal ops via event buffer
    if (cond.op == "recent") {
        auto eventType = extractAfterPrefix(cond.key, "event:");
        if (eventType.empty()) return 0.0;
        int64_t withinMs = 0;
        try { withinMs = std::stoll(cond.value); } catch (...) { return 0.0; }
        return eventBuffer_.hasRecent(eventType, withinMs) ? 1.0 : 0.0;
    }

    if (cond.op == "within") {
        auto [typeA, typeB] = extractSequencePair(cond.key);
        if (typeA.empty() || typeB.empty()) return 0.0;
        int64_t withinMs = 0;
        try { withinMs = std::stoll(cond.value); } catch (...) { return 0.0; }
        return eventBuffer_.hasSequence(typeA, typeB, withinMs) ? 1.0 : 0.0;
    }

    // All other ops → standard soft match
    return softMatch(cond, ctx);
}

bool RuleEngine::isRateLimited(const Action& action, int64_t now) {
    // Category cooldown: if 3+ rules of same action.type fired in window, suppress
    auto catIt = categoryFirings_.find(action.type);
    if (catIt != categoryFirings_.end()) {
        auto& timestamps = catIt->second;
        // Remove old entries outside the window
        int64_t catCutoff = now - rateLimits_.categoryCooldownWindowMs;
        while (!timestamps.empty() && timestamps.front() < catCutoff) {
            timestamps.pop_front();
        }
        if (static_cast<int>(timestamps.size()) >= rateLimits_.categoryCooldownCount) {
            return true;
        }
    }

    // Global rate limit: max N per hour
    int64_t hourCutoff = now - 3600000;
    while (!globalFirings_.empty() && globalFirings_.front() < hourCutoff) {
        globalFirings_.pop_front();
    }
    if (static_cast<int>(globalFirings_.size()) >= rateLimits_.globalMaxPerHour) {
        return true;
    }

    return false;
}

void RuleEngine::recordFiring(const Action& action, int64_t now) {
    categoryFirings_[action.type].push_back(now);
    globalFirings_.push_back(now);
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

            // Check per-rule cooldown
            auto lastIt = lastFired_.find(rule.id);
            if (lastIt != lastFired_.end() && rule.cooldownMs > 0) {
                if (now - lastIt->second < rule.cooldownMs) continue;
            }

            // Check enhanced rate limits
            if (isRateLimited(rule.action, now)) continue;

            // Match all conditions (soft match + temporal)
            double confidence = 1.0;
            for (const auto& cond : rule.conditions) {
                double match = matchCondition(cond, ctx);
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

    // Build priority lookup once: O(n) instead of O(n²) during sort
    std::unordered_map<std::string, double> priorityMap;
    priorityMap.reserve(rules_.size());
    for (const auto& rule : rules_) {
        priorityMap[rule.id] = rule.priority;
    }

    auto sortByScore = [&](std::vector<MatchResult>& results) {
        std::sort(results.begin(), results.end(), [&](const MatchResult& a, const MatchResult& b) {
            double pa = priorityMap.count(a.ruleId) ? priorityMap[a.ruleId] : 1.0;
            double pb = priorityMap.count(b.ruleId) ? priorityMap[b.ruleId] : 1.0;
            return a.confidence * pa > b.confidence * pb;
        });
    };

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
            if (isRateLimited(rule.action, now)) continue;
            double confidence = 1.0;
            for (const auto& cond : rule.conditions) {
                confidence *= matchCondition(cond, ctx);
                if (confidence < 0.01) break;
            }
            if (confidence > 0.1) {
                results.push_back({rule.id, confidence, rule.action});
            }
        }
        sortByScore(results);
        if (static_cast<int>(results.size()) > maxResults) results.resize(maxResults);

        // Record firing for rate limiting
        if (!results.empty()) {
            int64_t fireNow = nowMs();
            lastFired_[results[0].ruleId] = fireNow;
            recordFiring(results[0].action, fireNow);
        }
        return results;
    }

    std::vector<MatchResult> results;
    evaluateNode(0, ctx, results);

    // Deduplicate results (same rule may appear in multiple branches)
    std::unordered_map<std::string, size_t> seen;
    std::vector<MatchResult> deduped;
    deduped.reserve(results.size());
    for (auto& r : results) {
        auto it = seen.find(r.ruleId);
        if (it == seen.end()) {
            seen[r.ruleId] = deduped.size();
            deduped.push_back(std::move(r));
        } else {
            // Keep higher confidence
            if (r.confidence > deduped[it->second].confidence) {
                deduped[it->second] = std::move(r);
            }
        }
    }
    results = std::move(deduped);

    sortByScore(results);

    if (static_cast<int>(results.size()) > maxResults) {
        results.resize(maxResults);
    }

    // Record firing for per-rule cooldown + rate limiting
    if (!results.empty()) {
        int64_t fireNow = nowMs();
        lastFired_[results[0].ruleId] = fireNow;
        recordFiring(results[0].action, fireNow);
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
