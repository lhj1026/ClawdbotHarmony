/**
 * context_engine.h — 情景智能规则引擎核心头文件
 *
 * MVP scope:
 *   - Flat rules → compiled decision tree
 *   - Soft matching (0~1 confidence per condition)
 *   - Multi-Armed Bandit (epsilon-greedy) for action selection
 *   - Event buffer for temporal/sequence conditions
 *   - Enhanced cooldown (per-rule, per-category, global rate limit)
 */
#pragma once

#include <string>
#include <vector>
#include <array>
#include <unordered_map>
#include <optional>
#include <cstdint>
#include <memory>
#include <mutex>
#include <deque>

namespace context_engine {

// ============================================================
// Data types
// ============================================================

/** A single condition in a rule: key op value */
struct Condition {
    std::string key;       // e.g. "timeOfDay", "motionState", "geofence"
                           // For recent: "event:<eventType>" e.g. "event:geofence_enter"
                           // For sequence: "sequence:<typeA>,<typeB>"
    std::string op;        // "eq", "neq", "gt", "lt", "gte", "lte", "in", "range",
                           // "recent" (event happened within N ms),
                           // "within" (sequence A→B within N ms)
    std::string value;     // single value, JSON array for "in", "lo,hi" for "range",
                           // milliseconds string for "recent"/"within"
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
// Event buffer (temporal context)
// ============================================================

/** A context event pushed from ArkTS when something notable happens */
struct ContextEvent {
    ContextMap context;       // snapshot at the time
    int64_t timestampMs;      // when it happened (steady_clock ms)
    std::string eventType;    // e.g. "geofence_enter", "motion_change", "app_open"
};

/** Rate limiting configuration */
struct RateLimits {
    int categoryCooldownCount = 3;          // suppress after N same-type firings
    int64_t categoryCooldownWindowMs = 600000;  // within this window (10 min)
    int globalMaxPerHour = 10;              // max total recommendations per hour
};

/** Thread-safe circular event buffer with auto-expiry */
class EventBuffer {
public:
    explicit EventBuffer(size_t maxSize = 100);

    /** Push a new event. Automatically expires events older than 24 hours. */
    void push(const ContextEvent& event);

    /** Check if an event of given type happened within the last withinMs. */
    bool hasRecent(const std::string& eventType, int64_t withinMs) const;

    /**
     * Check if eventA happened before eventB, both within withinMs of now,
     * and eventA.timestamp < eventB.timestamp.
     */
    bool hasSequence(const std::string& eventA, const std::string& eventB,
                     int64_t withinMs) const;

    size_t size() const;

private:
    void expireOld();

    std::deque<ContextEvent> events_;
    size_t maxSize_;
    static constexpr int64_t MAX_AGE_MS = 86400000;  // 24 hours
    mutable std::mutex mu_;
};

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
// LinUCB Contextual Bandit
// ============================================================

constexpr int LINUCB_DIM = 8;  // feature dimension

/** Per-arm state for LinUCB: A matrix and b vector */
struct LinUCBArm {
    std::array<std::array<double, LINUCB_DIM>, LINUCB_DIM> A;  // d×d matrix
    std::array<double, LINUCB_DIM> b;                           // d-vector
};

class LinUCB {
public:
    explicit LinUCB(double alpha = 1.0);

    /**
     * Build feature vector from context map.
     * Features: [hour_sin, hour_cos, battery/100, isCharging, isWeekend,
     *            motion_stationary, motion_active, motion_vehicle]
     */
    std::array<double, LINUCB_DIM> buildFeatureVec(const ContextMap& ctx) const;

    /** Select best arm using UCB scores. Returns index into actionIds. */
    int select(const std::vector<std::string>& actionIds, const ContextMap& ctx);

    /** Update arm with observed reward and the context that was active. */
    void update(const std::string& actionId, double reward, const ContextMap& ctx);

    /** Export all arm state as JSON (for persistence). */
    std::string exportJson() const;

    /** Import arm state from JSON. */
    void importJson(const std::string& json);

private:
    double alpha_;
    std::unordered_map<std::string, LinUCBArm> arms_;
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

    /** Push a context event into the event buffer (for recent/sequence conditions) */
    void pushEvent(const ContextEvent& event);

    /** Configure rate limits (category cooldown, global rate limit) */
    void setLimits(const RateLimits& limits);

    /** Get the MAB for external reward updates */
    MAB& mab() { return mab_; }

    /** Get the LinUCB bandit for contextual action selection */
    LinUCB& linucb() { return linucb_; }

    /** Get rule count */
    size_t ruleCount() const { return rules_.size(); }

    /** Export rules as JSON string */
    std::string exportRulesJson() const;

private:
    void compileTree();
    void evaluateNode(int nodeIdx, const ContextMap& ctx,
                      std::vector<MatchResult>& results);

    /** Evaluate a single condition, handling "recent"/"within" via event buffer */
    double matchCondition(const Condition& cond, const ContextMap& ctx);

    /** Check enhanced cooldown: category throttle + global rate limit */
    bool isRateLimited(const Action& action, int64_t now);

    /** Record a firing for rate limit tracking */
    void recordFiring(const Action& action, int64_t now);

    std::vector<Rule> rules_;
    std::vector<TreeNode> tree_;
    MAB mab_;
    LinUCB linucb_;
    std::unordered_map<std::string, int64_t> lastFired_;  // ruleId → timestamp
    EventBuffer eventBuffer_;
    RateLimits rateLimits_;

    // Category cooldown: action.type → list of firing timestamps
    std::unordered_map<std::string, std::deque<int64_t>> categoryFirings_;
    // Global rate limit: all firing timestamps in the last hour
    std::deque<int64_t> globalFirings_;

    mutable std::mutex mu_;
};

}  // namespace context_engine
