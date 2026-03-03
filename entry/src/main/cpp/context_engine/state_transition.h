/**
 * state_transition.h — State Transition Tracking for Context Intelligence
 *
 * Tracks state transitions (geofence changes, motion state changes) to provide
 * 9 additional features for the Stream MLP (indices 16-24).
 *
 * Key capabilities:
 *   - Detect state changes (geofence and motion)
 *   - Track transition history for routine detection
 *   - Classify transition direction (work↔rest)
 *   - Generate transition JSON for UI path bars
 *   - Persistence via export/import JSON
 */
#pragma once

#include <string>
#include <vector>
#include <unordered_map>
#include <cstdint>

namespace context_engine {

// Forward declaration
using ContextMap = std::unordered_map<std::string, std::string>;

// ============================================================
// State snapshot and transition info
// ============================================================

struct StateSnapshot {
    std::string geofence;         // geofence ID or empty
    std::string geofenceLabel;    // human-readable name
    std::string geofenceIcon;     // emoji icon
    std::string motionState;      // stationary/walking/running/driving
    int64_t timestamp;            // ms since epoch

    StateSnapshot() : timestamp(0) {}
};

struct TransitionInfo {
    StateSnapshot prev;
    StateSnapshot current;
    double durationMin;           // transition duration in minutes
    double timeInCurrentMin;      // time spent in current state
    int transitionsLastHour;      // state changes in last 60 min
    bool isRoutine;               // seen this route 3+ times at this hour
    int direction;                // -1=work→rest, 0=same, +1=rest→work
    std::string patternLabel;     // e.g. "常规通勤 · 周一早晨"

    TransitionInfo()
        : durationMin(0), timeInCurrentMin(0), transitionsLastHour(0),
          isRoutine(false), direction(0) {}
};

// ============================================================
// StateTransitionTracker
// ============================================================

class StateTransitionTracker {
public:
    /**
     * Update tracker with current context. Returns true if a state change was detected.
     * Reads "geofence", "motionState" from ctx.
     */
    bool update(const ContextMap& ctx);

    /**
     * Inject 9 transition feature keys into ctx for buildFeatures() to consume:
     *   prev_geofence, geofence_changed, prev_motionState_stationary,
     *   prev_motionState_moving, transition_duration_min, time_in_current_state_min,
     *   transitions_last_hour, is_routine_transition, transition_direction
     */
    void injectFeatures(ContextMap& ctx) const;

    /** Get current transition info struct */
    TransitionInfo getTransitionInfo() const;

    /** Get transition info as JSON string for NAPI → UI rendering */
    std::string getTransitionJson() const;

    /** Export full state as JSON for persistence */
    std::string exportJson() const;

    /** Import state from JSON (restore after app restart) */
    void importJson(const std::string& json);

private:
    StateSnapshot current_;
    StateSnapshot previous_;
    std::vector<int64_t> transitionTimestamps_;  // for transitions_last_hour
    bool hasTransition_ = false;

    // Routine detection: "fromGeo|toGeo|hourBucket" → count
    std::unordered_map<std::string, int> routeCounts_;
    static constexpr int ROUTINE_THRESHOLD = 3;

    /** Check if geofence or motionState changed vs current_ */
    bool detectStateChange(const ContextMap& ctx) const;

    /** Classify direction: -1=work→rest, 0=same/unknown, +1=rest→work */
    int classifyDirection(const std::string& fromGeo, const std::string& toGeo) const;

    /** Get category for a geofence: "rest", "work", or "" */
    static std::string geoCategory(const std::string& geo);

    /** Get emoji icon for a geofence category */
    static std::string geofenceIcon(const std::string& geo);

    /** Get human-readable label for a geofence */
    static std::string geofenceLabel(const std::string& geo);

    /** Get current time in ms since epoch */
    static int64_t nowMs();

    /** Prune old timestamps from transitionTimestamps_ */
    void pruneOldTimestamps(int64_t cutoff);
};

}  // namespace context_engine
