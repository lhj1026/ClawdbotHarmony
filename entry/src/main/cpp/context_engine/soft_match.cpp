/**
 * soft_match.cpp — 软匹配引擎
 *
 * 每个条件返回 0~1 的置信度:
 *   - eq:    完全匹配=1.0, 缺失=0.5, 不匹配=0.0
 *   - neq:   不匹配=1.0, 匹配=0.0
 *   - gt/lt/gte/lte: 数值比较，超出范围时线性衰减
 *   - in:    值在集合中=1.0
 *   - range: 值在范围内=1.0, 范围外线性衰减
 */
#include "context_engine.h"
#include <cmath>
#include <sstream>
#include <algorithm>

namespace context_engine {

static bool tryParseDouble(const std::string& s, double& out) {
    try {
        size_t pos;
        out = std::stod(s, &pos);
        return pos == s.size();
    } catch (...) {
        return false;
    }
}

static std::vector<std::string> splitCsv(const std::string& s) {
    std::vector<std::string> parts;
    std::istringstream ss(s);
    std::string item;
    while (std::getline(ss, item, ',')) {
        // trim whitespace
        auto start = item.find_first_not_of(" \t");
        auto end = item.find_last_not_of(" \t");
        if (start != std::string::npos) {
            parts.push_back(item.substr(start, end - start + 1));
        }
    }
    return parts;
}

double softMatch(const Condition& cond, const ContextMap& ctx) {
    auto it = ctx.find(cond.key);
    if (it == ctx.end()) {
        // Missing data → 0.5 (uncertain, not penalized)
        return 0.5;
    }

    const std::string& actual = it->second;

    if (cond.op == "eq") {
        return actual == cond.value ? 1.0 : 0.0;
    }

    if (cond.op == "neq") {
        return actual != cond.value ? 1.0 : 0.0;
    }

    if (cond.op == "in") {
        auto options = splitCsv(cond.value);
        for (const auto& opt : options) {
            if (actual == opt) return 1.0;
        }
        return 0.0;
    }

    // Numeric comparisons
    double actualNum, valueNum;
    if (!tryParseDouble(actual, actualNum) || !tryParseDouble(cond.value, valueNum)) {
        // Can't parse as number → hard fail
        return actual == cond.value ? 1.0 : 0.0;
    }

    // Soft decay margin (10% of value or 1.0, whichever is larger)
    double margin = std::max(std::abs(valueNum) * 0.1, 1.0);

    if (cond.op == "gt") {
        if (actualNum > valueNum) return 1.0;
        double diff = valueNum - actualNum;
        return std::max(0.0, 1.0 - diff / margin);
    }
    if (cond.op == "gte") {
        if (actualNum >= valueNum) return 1.0;
        double diff = valueNum - actualNum;
        return std::max(0.0, 1.0 - diff / margin);
    }
    if (cond.op == "lt") {
        if (actualNum < valueNum) return 1.0;
        double diff = actualNum - valueNum;
        return std::max(0.0, 1.0 - diff / margin);
    }
    if (cond.op == "lte") {
        if (actualNum <= valueNum) return 1.0;
        double diff = actualNum - valueNum;
        return std::max(0.0, 1.0 - diff / margin);
    }

    if (cond.op == "range") {
        auto parts = splitCsv(cond.value);
        if (parts.size() != 2) return 0.0;
        double lo, hi;
        if (!tryParseDouble(parts[0], lo) || !tryParseDouble(parts[1], hi)) return 0.0;

        if (actualNum >= lo && actualNum <= hi) return 1.0;
        double dist = actualNum < lo ? (lo - actualNum) : (actualNum - hi);
        double rangeMargin = std::max((hi - lo) * 0.1, 1.0);
        return std::max(0.0, 1.0 - dist / rangeMargin);
    }

    return 0.0;
}

}  // namespace context_engine
