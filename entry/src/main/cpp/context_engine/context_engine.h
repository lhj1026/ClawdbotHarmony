/**
 * context_engine.h — 情景智能规则引擎核心头文件
 *
 * MVP scope:
 *   - Flat rules → compiled decision tree
 *   - Soft matching (0~1 confidence per condition)
 *   - Multi-Armed Bandit (epsilon-greedy) for action selection
 *   - Event buffer for recent context
 */
#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <optional>
#include <cstdint>
#include <memory>
#include <mutex>

namespace context_engine {

// ============================================================
// Data types
// ============================================================

/** A single condition in a rule: key op value */
struct Condition {
    std::string key;       // e.g. "timeOfDay", "motionState", "geofence"
    std::string op;        // "eq", "neq", "gt", "lt", "gte", "lte", "in", "range"
    std::string value;     // single value or JSON array for "in", "lo,hi" for "range"
};

/** An action to recommend when a rule fires */
struct Action {
    std::string id;        // unique action id
    std::string type;      // "suggestion", "automation", "notification"
    std::string payload;   // JSON string — content depends on type
};

/** A flat rule: conditions → action with priority & cooldown */
struct Rule {
    std::string id;
    std::string name;
    std::vector<Condition> conditions;
    Action action;
    double priority;           // higher = more important (default 1.0)
    int64_t cooldownMs;        // minimum interval between firings (default 0)
    bool enabled;
};

/** Evaluation result for a single rule */
struct MatchResult {
    std::string ruleId;
    double confidence;         // 0~1 combined confidence
    Action action;
};

/** Context snapshot — key-value pairs from sensors */
using ContextMap = std::unordered_map<std::string, std::string>;

// ============================================================
// Decision tree (compiled from flat rules)
// ============================================================

struct TreeNode {
    // Internal node: split on a key
    std::string splitKey;                          // "" for leaf
    std::vector<std::pair<std::string, int>> branches;  // value → child index
    int defaultChild;                              // fallback child index (-1 if leaf)

    // Leaf node: candidate rules to evaluate
    std::vector<int> ruleIndices;                  // indices into RuleEngine::rules_
};

// ============================================================
// Multi-Armed Bandit (epsilon-greedy)
// ============================================================

struct ArmStats {
    int pulls;
    double totalReward;
    double avgReward() const { return pulls > 0 ? totalReward / pulls : 0.0; }
};

class MAB {
public:
    explicit MAB(double epsilon = 0.1);

    /** Select an action from candidates. Returns index into candidates. */
    int select(const std::vector<std::string>& actionIds);

    /** Update reward for an action */
    void update(const std::string& actionId, double reward);

    /** Get stats for serialization */
    std::unordered_map<std::string, ArmStats> getStats() const;

    /** Load stats from serialized data */
    void loadStats(const std::unordered_map<std::string, ArmStats>& stats);

private:
    double epsilon_;
    std::unordered_map<std::string, ArmStats> arms_;
    mutable std::mutex mu_;
};

// ============================================================
// Soft matching
// ============================================================

/** Evaluate a single condition against context, returning 0~1 confidence */
double softMatch(const Condition& cond, const ContextMap& ctx);

// ============================================================
// Rule Engine (main interface)
// ============================================================

class RuleEngine {
public:
    RuleEngine();
    ~RuleEngine();

    /** Load rules (replaces all existing rules). Auto-compiles decision tree. */
    bool loadRules(const std::vector<Rule>& rules);

    /** Add a single rule. Re-compiles tree. */
    bool addRule(const Rule& rule);

    /** Remove a rule by id. Re-compiles tree. */
    bool removeRule(const std::string& ruleId);

    /** Evaluate context against all rules. Returns matches sorted by confidence × priority. */
    std::vector<MatchResult> evaluate(const ContextMap& ctx, int maxResults = 5);

    /** Get the MAB for external reward updates */
    MAB& mab() { return mab_; }

    /** Get rule count */
    size_t ruleCount() const { return rules_.size(); }

    /** Export rules as JSON string */
    std::string exportRulesJson() const;

private:
    void compileTree();
    void evaluateNode(int nodeIdx, const ContextMap& ctx,
                      std::vector<MatchResult>& results);

    std::vector<Rule> rules_;
    std::vector<TreeNode> tree_;
    MAB mab_;
    std::unordered_map<std::string, int64_t> lastFired_;  // ruleId → timestamp
    mutable std::mutex mu_;
};

}  // namespace context_engine
