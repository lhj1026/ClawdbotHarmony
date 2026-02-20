/**
 * Native context_engine module — 情景智能规则引擎
 *
 * C++ NAPI: decision tree + soft matching + MAB
 */

/**
 * Load rules from JSON string. Replaces all existing rules and recompiles decision tree.
 * @param rulesJson - JSON array of Rule objects
 * @returns true if loaded successfully
 *
 * Rule format:
 * {
 *   "id": "rule_morning_commute",
 *   "name": "早通勤提醒",
 *   "conditions": [
 *     {"key": "timeOfDay", "op": "eq", "value": "morning"},
 *     {"key": "motionState", "op": "eq", "value": "walking"},
 *     {"key": "dayOfWeek", "op": "in", "value": "1,2,3,4,5"}
 *   ],
 *   "action": {
 *     "id": "suggest_commute",
 *     "type": "suggestion",
 *     "payload": "查看通勤路线和天气"
 *   },
 *   "priority": 1.0,
 *   "cooldownMs": 3600000,
 *   "enabled": true
 * }
 */
export const loadRules: (rulesJson: string) => boolean;

/** Add or update a single rule (JSON string). Recompiles tree. */
export const addRule: (ruleJson: string) => boolean;

/** Remove a rule by ID. Recompiles tree. */
export const removeRule: (ruleId: string) => boolean;

/**
 * Evaluate current context against all rules.
 * @param contextJson - JSON object with key-value pairs, e.g.:
 *   {"timeOfDay":"morning","motionState":"walking","dayOfWeek":"1","geofence":"home"}
 * @param maxResults - Max number of results (default 5)
 * @returns JSON array of MatchResult:
 *   [{"ruleId":"...","confidence":0.85,"action":{"id":"...","type":"...","payload":"..."}}]
 */
export const evaluate: (contextJson: string, maxResults?: number) => string;

/**
 * Update MAB reward for an action (user feedback).
 * @param actionId - The action ID that was shown
 * @param reward - Reward value (0.0 = ignored, 0.5 = dismissed, 1.0 = accepted/used)
 */
export const updateReward: (actionId: string, reward: number) => void;

/**
 * MAB action selection from candidates.
 * @param actionIdsJson - JSON array of action ID strings
 * @returns Index of selected action
 */
export const selectAction: (actionIdsJson: string) => number;

/** Get MAB statistics as JSON string */
export const getStats: () => string;

/** Load MAB statistics from JSON string */
export const loadStats: (statsJson: string) => void;

/** Get current rule count */
export const getRuleCount: () => number;

/** Export all rules as JSON string */
export const exportRules: () => string;
