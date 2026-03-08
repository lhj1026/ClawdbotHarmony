/**
 * state_attributes.h — Semantic Attribute Encoding for Physical State
 *
 * Instead of one-hot encoding (sparse, 92 dims), each dimension is mapped
 * to a compact semantic attribute vector (dense, 19 dims total).
 *
 * This design is extension-friendly: adding a new Location (or any enum value)
 * only requires adding one row to the lookup table — model structure and weights
 * remain unchanged because the model learns attribute→action mappings.
 *
 * Location uses dual-layer encoding:
 *   Category attributes (5d): static, derived from place category (home/work/cafe/...)
 *   Instance attributes (3d): dynamic, derived from user's personal history with this place
 *
 * Data pipeline:
 *   GPS/WiFi → GeofenceManager → category → categoryAttributes() [5d static]
 *   GeofenceManager.learnedSignals → instanceAttributes() [3d dynamic]
 *   Combined: 8d location vector per state
 *
 * Single state encoding (19 dims):
 *   Time:     1d  normalized [0,1]
 *   Location: 8d  [indoor, workRest, private, noise, stayExpect,
 *                   familiarity, ownership, routineLevel]
 *   Motion:   2d  [speed, regularity]
 *   Phone:    2d  [active, reachable]
 *   Light:    1d  normalized [0,1]
 *   Sound:    1d  normalized [0,1]
 *   DayType:  2d  [isWorkday, isSpecial]
 *                                              total = 19
 *
 * State chain encoding (60 dims):
 *   [current(19) + mean_pool(19) + delta(19) + time_features(3)]
 *   where delta = current - first_in_chain (direction of change)
 *   time_features = [total_chain_duration_norm, time_in_current_norm, chain_length_norm]
 */
#pragma once

#include "state_code.h"
#include <array>
#include <cmath>
#include <algorithm>
#include <chrono>

namespace context_engine {

// ============================================================
// Constants
// ============================================================

constexpr int SA_SINGLE_DIM  = 19;   // dims per single state
constexpr int SA_CHAIN_DIM   = 60;   // full chain feature vector (19*3 + 3)
constexpr int SA_CHAIN_MAX   = 6;    // max states in chain
constexpr int ACT_COUNT      = 64;   // 动作总槽数（40已定义 + 24预留）

// Offsets within single state vector
constexpr int SA_OFF_TIME    = 0;    // 1d
constexpr int SA_OFF_LOC     = 1;    // 8d  [5 category + 3 instance]
constexpr int SA_OFF_MOTION  = 9;    // 2d
constexpr int SA_OFF_PHONE   = 11;   // 2d
constexpr int SA_OFF_LIGHT   = 13;   // 1d
constexpr int SA_OFF_SOUND   = 14;   // 1d
constexpr int SA_OFF_DAYTYPE = 15;   // 2d
constexpr int SA_OFF_LOC_INST = 6;   // 3d instance attrs within location block

// ============================================================
// Location Category Attributes: [indoor, workRest, private, noise, stayExpect]
//   indoor:      1.0=fully indoor, 0.0=outdoor
//   workRest:    1.0=work/productive, 0.0=rest/leisure
//   private:     1.0=private space, 0.0=public
//   noise:       0.0=quiet, 1.0=noisy
//   stayExpect:  0.0=passing through, 1.0=long stay
//
// Location Instance Attributes: [familiarity, ownership, routineLevel]
//   familiarity:  0.0=never been, 1.0=very familiar (from visitCount)
//   ownership:    0.0=public/other's, 1.0=my own place (from category)
//   routineLevel: 0.0=irregular visits, 1.0=daily routine (from visit pattern)
//
// Data pipeline:
//   Category attrs: GeofenceManager → geofence.category → lookup table (static)
//   Instance attrs: GeofenceManager → learnedSignals → computed (dynamic)
//     familiarity  = min(visitCount / 50, 1.0)
//     ownership    = ownershipByCategory(category)  // home=1.0, work=0.8, ...
//     routineLevel = min(weeklyVisits / 7.0, 1.0)   // how regularly user visits
// ============================================================

struct LocAttr {
    float indoor, workRest, isPrivate, noise, stayExpect;
};

/** Instance-level attributes computed from user's personal geofence history */
struct LocInstanceAttr {
    float familiarity  = 0.0f;  // 0=new place, 1=very familiar
    float ownership    = 0.0f;  // 0=public, 1=my own
    float routineLevel = 0.0f;  // 0=irregular, 1=daily routine
};

/** Default ownership score by geofence category */
inline float ownershipByCategory(const char* category) {
    // category strings from ArkTS GeofenceCategory
    if (!category) return 0.0f;
    // Compare first char for fast dispatch
    switch (category[0]) {
        case 'h': return 1.0f;   // "home"
        case 'w': return 0.8f;   // "work"
        case 'g': return 0.3f;   // "gym"
        case 'r': return 0.1f;   // "restaurant"
        case 's': return 0.1f;   // "shopping"
        case 't': return 0.0f;   // "transit"
        case 'c': return 0.2f;   // "custom"
        default:  return 0.0f;
    }
};

inline LocAttr locationAttributes(Location loc) {
    switch (loc) {
        //                    indoor  work   priv   noise  stay
        case Location::Home:         return {1.0f, 0.0f, 1.0f, 0.1f, 1.0f};
        case Location::Work:         return {1.0f, 1.0f, 0.5f, 0.3f, 1.0f};
        case Location::Commute:      return {0.5f, 0.0f, 0.0f, 0.6f, 0.1f};
        case Location::Restaurant:   return {1.0f, 0.0f, 0.0f, 0.6f, 0.6f};
        case Location::Gym:          return {0.8f, 0.0f, 0.0f, 0.5f, 0.6f};
        case Location::Outdoor:      return {0.0f, 0.0f, 0.0f, 0.4f, 0.4f};
        case Location::Airport:      return {0.9f, 0.0f, 0.0f, 0.7f, 0.7f};
        case Location::Shopping:     return {0.9f, 0.0f, 0.0f, 0.6f, 0.5f};
        case Location::Subway:       return {0.9f, 0.0f, 0.0f, 0.7f, 0.2f};
        case Location::BusStop:      return {0.2f, 0.0f, 0.0f, 0.6f, 0.1f};
        case Location::Ferry:        return {0.5f, 0.0f, 0.0f, 0.5f, 0.4f};
        case Location::TrainStation: return {0.8f, 0.0f, 0.0f, 0.7f, 0.5f};
        case Location::Cafe:         return {1.0f, 0.5f, 0.2f, 0.3f, 0.7f};
        case Location::Cinema:       return {1.0f, 0.0f, 0.0f, 0.2f, 0.8f};
        case Location::Park:         return {0.0f, 0.0f, 0.0f, 0.2f, 0.5f};
        default:                     return {0.5f, 0.5f, 0.5f, 0.5f, 0.5f}; // Unknown
    }
}

// ============================================================
// Motion Attributes: [speed, regularity]
//   speed:       0.0=still, 1.0=fast
//   regularity:  0.0=irregular, 1.0=steady
// ============================================================

struct MotionAttr { float speed, regularity; };

inline MotionAttr motionAttributes(Motion m) {
    switch (m) {
        case Motion::Stationary: return {0.0f, 1.0f};
        case Motion::Walking:    return {0.3f, 0.8f};
        case Motion::Running:    return {0.7f, 0.7f};
        case Motion::Driving:    return {1.0f, 0.6f};
        default:                 return {0.0f, 0.5f}; // Unknown
    }
}

// ============================================================
// Phone Attributes: [active, reachable]
//   active:      0.0=idle, 1.0=actively using
//   reachable:   0.0=can't see/reach, 1.0=readily accessible
// ============================================================

struct PhoneAttr { float active, reachable; };

inline PhoneAttr phoneAttributes(PhonePos p) {
    switch (p) {
        case PhonePos::InUse:        return {1.0f, 1.0f};
        case PhonePos::HoldingLying: return {0.7f, 1.0f};
        case PhonePos::OnDesk:       return {0.1f, 0.9f};
        case PhonePos::FaceUp:       return {0.0f, 0.8f};
        case PhonePos::InPocket:     return {0.0f, 0.3f};
        case PhonePos::FaceDown:     return {0.0f, 0.5f};
        case PhonePos::Charging:     return {0.0f, 0.7f};
        default:                     return {0.0f, 0.5f}; // Unknown
    }
}

// ============================================================
// Single State Encoder
// ============================================================

struct StateVector {
    float v[SA_SINGLE_DIM] = {};

    /**
     * Encode a PhysicalState into 19-dim dense attribute vector.
     * @param s         Physical state 7-tuple
     * @param instAttr  Instance-level location attributes (from geofence history)
     */
    static StateVector encode(const PhysicalState& s,
                              const LocInstanceAttr& instAttr = {}) {
        StateVector sv;

        // Time: normalize 1-9 → [0, 1]
        {
            int t = static_cast<int>(static_cast<char>(s.time) - '1');
            sv.v[SA_OFF_TIME] = (t >= 0 && t < 9) ? t / 8.0f : 0.5f;
        }

        // Location: 5d category attributes
        {
            LocAttr la = locationAttributes(s.location);
            sv.v[SA_OFF_LOC + 0] = la.indoor;
            sv.v[SA_OFF_LOC + 1] = la.workRest;
            sv.v[SA_OFF_LOC + 2] = la.isPrivate;
            sv.v[SA_OFF_LOC + 3] = la.noise;
            sv.v[SA_OFF_LOC + 4] = la.stayExpect;
        }

        // Location: 3d instance attributes (from ArkTS geofence data)
        {
            sv.v[SA_OFF_LOC + 5] = instAttr.familiarity;
            sv.v[SA_OFF_LOC + 6] = instAttr.ownership;
            sv.v[SA_OFF_LOC + 7] = instAttr.routineLevel;
        }

        // Motion: 2d attributes
        {
            MotionAttr ma = motionAttributes(s.motion);
            sv.v[SA_OFF_MOTION + 0] = ma.speed;
            sv.v[SA_OFF_MOTION + 1] = ma.regularity;
        }

        // Phone: 2d attributes
        {
            PhoneAttr pa = phoneAttributes(s.phone);
            sv.v[SA_OFF_PHONE + 0] = pa.active;
            sv.v[SA_OFF_PHONE + 1] = pa.reachable;
        }

        // Light: normalize 0-4 → [0, 1]
        {
            int li = static_cast<int>(static_cast<char>(s.light) - '0');
            sv.v[SA_OFF_LIGHT] = (li >= 0 && li <= 4) ? li / 4.0f : 0.5f;
        }

        // Sound: normalize 0-4 → [0, 1]
        {
            int so = static_cast<int>(static_cast<char>(s.sound) - '0');
            sv.v[SA_OFF_SOUND] = (so >= 0 && so <= 4) ? so / 4.0f : 0.5f;
        }

        // DayType: [isWorkday, isSpecial]
        {
            char d = static_cast<char>(s.dayType);
            sv.v[SA_OFF_DAYTYPE + 0] = (d == '1') ? 1.0f : 0.0f;  // workday
            sv.v[SA_OFF_DAYTYPE + 1] = (d == '3') ? 1.0f : 0.0f;  // holiday
        }

        return sv;
    }
};

// ============================================================
// State Chain Buffer (ring buffer with timestamps)
// ============================================================

struct StateChain {
    static constexpr int MAX = SA_CHAIN_MAX;

    struct Entry {
        PhysicalState state;
        StateVector   vec;
        double        timestamp = 0.0;  // seconds since epoch
    };

    Entry entries[MAX];
    int   head  = 0;
    int   count = 0;

    /** Push a new state into the chain */
    void push(const PhysicalState& s, const LocInstanceAttr& instAttr = {}) {
        auto& e = entries[head];
        e.state = s;
        e.vec = StateVector::encode(s, instAttr);
        auto tp = std::chrono::system_clock::now().time_since_epoch();
        e.timestamp = std::chrono::duration<double>(tp).count();
        head = (head + 1) % MAX;
        if (count < MAX) ++count;
    }

    /** Get entry at index (0 = oldest in buffer, count-1 = newest) */
    const Entry& at(int idx) const {
        int start = (head - count + MAX) % MAX;
        return entries[(start + idx) % MAX];
    }

    /** Current (newest) entry */
    const Entry& current() const { return at(count - 1); }

    /** First (oldest) entry in chain */
    const Entry& first() const { return at(0); }

    /** Time in current state (seconds), based on when same state started */
    double timeInCurrentSec() const {
        if (count == 0) return 0.0;
        return current().timestamp - current().timestamp; // will be refined below
    }
};

// ============================================================
// Chain Feature Builder: StateChain → 51-dim feature vector
// ============================================================

struct ChainFeature {
    float x[SA_CHAIN_DIM] = {};

    /**
     * Build full 60-dim feature from state chain:
     *   [0..18]  current state vector (19d)
     *   [19..37] mean pool of all states in chain (19d)
     *   [38..56] delta: current - first (direction of change) (19d)
     *   [57]     total chain duration (normalized)
     *   [58]     time in current state (normalized)
     *   [59]     chain length (normalized)
     */
    static ChainFeature build(const StateChain& chain) {
        ChainFeature f;
        if (chain.count == 0) return f;

        const auto& curr = chain.current();
        const auto& first = chain.first();

        // [0..15] Current state
        for (int i = 0; i < SA_SINGLE_DIM; ++i) {
            f.x[i] = curr.vec.v[i];
        }

        // [16..31] Mean pool
        for (int i = 0; i < SA_SINGLE_DIM; ++i) {
            float sum = 0.0f;
            for (int j = 0; j < chain.count; ++j) {
                sum += chain.at(j).vec.v[i];
            }
            f.x[SA_SINGLE_DIM + i] = sum / chain.count;
        }

        // [32..47] Delta (current - first)
        for (int i = 0; i < SA_SINGLE_DIM; ++i) {
            f.x[SA_SINGLE_DIM * 2 + i] = curr.vec.v[i] - first.vec.v[i];
        }

        // [57] Total chain duration normalized
        //   0.0 = <5min, 0.33 = 5-30min, 0.67 = 30-120min, 1.0 = >2h
        {
            double totalSec = curr.timestamp - first.timestamp;
            if (totalSec < 300)       f.x[SA_SINGLE_DIM * 3 + 0] = 0.0f;
            else if (totalSec < 1800) f.x[SA_SINGLE_DIM * 3 + 0] = 0.33f;
            else if (totalSec < 7200) f.x[SA_SINGLE_DIM * 3 + 0] = 0.67f;
            else                      f.x[SA_SINGLE_DIM * 3 + 0] = 1.0f;
        }

        // [58] Time in current state normalized
        //   Look backwards to find when current state started (same state code)
        {
            double elapsed = 0.0;
            if (chain.count >= 2) {
                // Find last state change
                for (int j = chain.count - 2; j >= 0; --j) {
                    if (!(chain.at(j).state == curr.state)) {
                        elapsed = curr.timestamp - chain.at(j + 1).timestamp;
                        break;
                    }
                    if (j == 0) {
                        elapsed = curr.timestamp - first.timestamp;
                    }
                }
            }
            if (elapsed < 300)       f.x[SA_SINGLE_DIM * 3 + 1] = 0.0f;
            else if (elapsed < 1800) f.x[SA_SINGLE_DIM * 3 + 1] = 0.33f;
            else if (elapsed < 7200) f.x[SA_SINGLE_DIM * 3 + 1] = 0.67f;
            else                     f.x[SA_SINGLE_DIM * 3 + 1] = 1.0f;
        }

        // [59] Chain length normalized (1/6=single, 1.0=full chain)
        f.x[SA_SINGLE_DIM * 3 + 2] = static_cast<float>(chain.count) / SA_CHAIN_MAX;

        return f;
    }

    /**
     * Build from single state (no history) — fallback
     * Current fills [0..18], mean = current, delta = zero
     */
    static ChainFeature fromSingle(const PhysicalState& s,
                                    const LocInstanceAttr& instAttr = {}) {
        ChainFeature f;
        StateVector sv = StateVector::encode(s, instAttr);
        // Current
        for (int i = 0; i < SA_SINGLE_DIM; ++i) f.x[i] = sv.v[i];
        // Mean = current
        for (int i = 0; i < SA_SINGLE_DIM; ++i) f.x[SA_SINGLE_DIM + i] = sv.v[i];
        // Delta = zero (already initialized)
        // Time features = zero/minimal
        f.x[SA_SINGLE_DIM * 3 + 2] = 1.0f / SA_CHAIN_MAX;
        return f;
    }
};

} // namespace context_engine
