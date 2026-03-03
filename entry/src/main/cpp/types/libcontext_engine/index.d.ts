/**
 * Native context_engine module — 情景智能规则引擎
 *
 * C++ NAPI: decision tree + soft matching
 */

/**
 * Load rules from JSON string. Replaces all existing rules and recompiles decision tree.
 * @param rulesJson - JSON array of Rule objects
 * @returns true if loaded successfully
 */
export const loadRules: (rulesJson: string) => boolean;

/** Add or update a single rule (JSON string). Recompiles tree. */
export const addRule: (ruleJson: string) => boolean;

/** Remove a rule by ID. Recompiles tree. */
export const removeRule: (ruleId: string) => boolean;

/**
 * Evaluate current context against all rules.
 * @param contextJson - JSON object with key-value pairs
 * @param maxResults - Max number of results (default 5)
 * @returns JSON array of MatchResult
 */
export const evaluate: (contextJson: string, maxResults?: number) => string;

/** Get current rule count */
export const getRuleCount: () => number;

/** Export all rules as JSON string */
export const exportRules: () => string;

/** Push a context event into the event buffer */
export const pushEvent: (eventJson: string) => void;

/** Configure rate limits */
export const setLimits: (limitsJson: string) => void;

/** Get state transition info as JSON string (for UI path bar) */
export const getTransitionInfo: () => string;

/** Export state transition tracker state as JSON string (for persistence) */
export const exportTransitionState: () => string;

/** Import state transition tracker state from JSON string */
export const importTransitionState: (json: string) => void;
