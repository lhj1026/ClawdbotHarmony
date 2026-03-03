/**
 * state_code.h — 7元组物理状态编码/解码
 *
 * StateCode 格式：7位字符串 [T][L][M][P][Li][S][D]
 *
 *   T  时间    1-9  (1=sleeping … 9=late_night)
 *   L  位置    A-P  (A=home … P=unknown)
 *   M  运动    1-4  (1=stationary … 4=driving)
 *   P  手机    1-8  (1=in_use … 8=unknown)
 *   Li 光线    0-4  (0=未指定, 1=dark … 4=bright)
 *   S  声音    0-4  (0=未指定, 1=quiet … 3=noisy, 4=unknown)
 *   D  日期    0-3  (0=未指定, 1=workday, 2=weekend, 3=holiday)
 *
 * 示例：
 *   3M11332  →  morning × 咖啡馆 × stationary × in_use × normal × noisy × weekend
 *   7A11001  →  evening × 家 × stationary × in_use × 未指定 × 未指定 × workday
 */
#pragma once

#include <string>
#include <string_view>
#include <unordered_map>
#include <optional>
#include <array>
#include <cstdint>

namespace context_engine {

// ============================================================
// 维度枚举
// ============================================================

enum class TimeSlot : char {
    Unknown   = '0',
    Sleeping  = '1',   // 0-5时
    Dawn      = '2',   // 5-7时
    Morning   = '3',   // 7-9时
    Forenoon  = '4',   // 9-12时
    Lunch     = '5',   // 12-14时
    Afternoon = '6',   // 14-17时
    Evening   = '7',   // 17-20时
    Night     = '8',   // 20-23时
    LateNight = '9',   // 23-24时
};

enum class Location : char {
    Home         = 'A',
    Work         = 'B',
    Commute      = 'C',
    Restaurant   = 'D',
    Gym          = 'E',
    Outdoor      = 'F',
    Airport      = 'G',
    Shopping     = 'H',
    Subway       = 'I',
    BusStop      = 'J',
    Ferry        = 'K',
    TrainStation = 'L',
    Cafe         = 'M',
    Cinema       = 'N',
    Park         = 'O',
    Unknown      = 'P',
};

enum class Motion : char {
    Unknown    = '0',
    Stationary = '1',
    Walking    = '2',
    Running    = '3',
    Driving    = '4',
};

enum class PhonePos : char {
    Unknown      = '0',
    InUse        = '1',
    HoldingLying = '2',
    OnDesk       = '3',
    FaceUp       = '4',
    InPocket     = '5',
    FaceDown     = '6',
    Charging     = '7',
    UnknownVal   = '8',
};

enum class Light : char {
    Unspecified = '0',
    Dark        = '1',
    Dim         = '2',
    Normal      = '3',
    Bright      = '4',
};

enum class Sound : char {
    Unspecified = '0',
    Quiet       = '1',
    Normal      = '2',
    Noisy       = '3',
    Unknown     = '4',
};

enum class DayType : char {
    Unspecified = '0',
    Workday     = '1',
    Weekend     = '2',
    Holiday     = '3',
};

// ============================================================
// 物理状态结构体
// ============================================================

struct PhysicalState {
    TimeSlot time     = TimeSlot::Unknown;
    Location location = Location::Unknown;
    Motion   motion   = Motion::Unknown;
    PhonePos phone    = PhonePos::Unknown;
    Light    light    = Light::Unspecified;
    Sound    sound    = Sound::Unspecified;
    DayType  dayType  = DayType::Unspecified;

    bool operator==(const PhysicalState& o) const {
        return time == o.time && location == o.location && motion == o.motion
            && phone == o.phone && light == o.light && sound == o.sound
            && dayType == o.dayType;
    }
};

// ============================================================
// StateCode 编解码
// ============================================================

class StateCode {
public:
    // ── 编码 ────────────────────────────────────────────────

    /** 将 PhysicalState 编码为 7 位字符串，例如 "3M11332" */
    static std::string encode(const PhysicalState& s) {
        return {
            static_cast<char>(s.time),
            static_cast<char>(s.location),
            static_cast<char>(s.motion),
            static_cast<char>(s.phone),
            static_cast<char>(s.light),
            static_cast<char>(s.sound),
            static_cast<char>(s.dayType),
        };
    }

    // ── 解码 ────────────────────────────────────────────────

    /** 将 7 位 StateCode 字符串解码为 PhysicalState；格式不合法返回 nullopt */
    static std::optional<PhysicalState> decode(std::string_view code) {
        if (code.size() != 7) return std::nullopt;
        PhysicalState s;
        if (!setTime(s, code[0]))     return std::nullopt;
        if (!setLocation(s, code[1])) return std::nullopt;
        if (!setMotion(s, code[2]))   return std::nullopt;
        if (!setPhone(s, code[3]))    return std::nullopt;
        if (!setLight(s, code[4]))    return std::nullopt;
        if (!setSound(s, code[5]))    return std::nullopt;
        if (!setDayType(s, code[6]))  return std::nullopt;
        return s;
    }

    // ── 字符串名称解析 ───────────────────────────────────────

    /** 从字符串名称构建 PhysicalState，未知/空值保持 Unknown/Unspecified */
    static PhysicalState fromNames(
        const std::string& time,
        const std::string& location,
        const std::string& motion,
        const std::string& phone,
        const std::string& light    = "",
        const std::string& sound    = "",
        const std::string& dayType  = "")
    {
        PhysicalState s;
        s.time     = timeFromName(time);
        s.location = locationFromName(location);
        s.motion   = motionFromName(motion);
        s.phone    = phoneFromName(phone);
        s.light    = lightFromName(light);
        s.sound    = soundFromName(sound);
        s.dayType  = dayTypeFromName(dayType);
        return s;
    }

    // ── 匹配（0 = 通配符）────────────────────────────────────

    /**
     * 检查 state 是否匹配 pattern（7 位）。
     * '0' 在 pattern 中表示通配（匹配任意值）。
     * 例：pattern="3?11??1" 中 '?' 不合法，应用 '0' 表示通配。
     */
    static bool matches(const PhysicalState& state, std::string_view pattern) {
        if (pattern.size() != 7) return false;
        const std::string code = encode(state);
        for (int i = 0; i < 7; ++i) {
            if (pattern[i] == '0') continue;   // 通配
            if (pattern[i] != code[i]) return false;
        }
        return true;
    }

    // ── 相似度（0.0–1.0）────────────────────────────────────

    /**
     * 计算两个状态的加权相似度。
     * 每个维度完全匹配得满分，不匹配得 0。
     * Unknown/Unspecified 视为半分（0.5）。
     *
     * 维度权重（总和 = 1.0）：
     *   time(25%) location(25%) motion(15%) phone(10%)
     *   light(5%) sound(5%) dayType(15%)
     */
    static float similarity(const PhysicalState& a, const PhysicalState& b) {
        constexpr float W[7] = { 0.25f, 0.25f, 0.15f, 0.10f, 0.05f, 0.05f, 0.15f };
        const std::string ca = encode(a);
        const std::string cb = encode(b);
        float score = 0.0f;
        for (int i = 0; i < 7; ++i) {
            if (ca[i] == cb[i]) {
                score += W[i];
            } else if (ca[i] == '0' || cb[i] == '0') {
                score += W[i] * 0.5f;   // 其中一方未知
            }
        }
        return score;
    }

    // ── 名称映射（可按需扩展）───────────────────────────────

    static TimeSlot timeFromName(const std::string& s) {
        static const std::unordered_map<std::string, TimeSlot> m = {
            {"sleeping",  TimeSlot::Sleeping},  {"dawn",      TimeSlot::Dawn},
            {"morning",   TimeSlot::Morning},   {"forenoon",  TimeSlot::Forenoon},
            {"lunch",     TimeSlot::Lunch},     {"afternoon", TimeSlot::Afternoon},
            {"evening",   TimeSlot::Evening},   {"night",     TimeSlot::Night},
            {"late_night",TimeSlot::LateNight},
        };
        auto it = m.find(s); return it != m.end() ? it->second : TimeSlot::Unknown;
    }

    static Location locationFromName(const std::string& s) {
        static const std::unordered_map<std::string, Location> m = {
            {"home",A("A")}, {"work",A("B")}, {"commute",A("C")}, {"restaurant",A("D")},
            {"gym",A("E")},  {"outdoor",A("F")}, {"airport",A("G")}, {"shopping",A("H")},
            {"subway",A("I")}, {"bus_stop",A("J")}, {"ferry",A("K")},
            {"train_station",A("L")}, {"cafe",A("M")}, {"cinema",A("N")},
            {"park",A("O")}, {"unknown",A("P")},
        };
        auto it = m.find(s); return it != m.end() ? it->second : Location::Unknown;
    }

    static Motion motionFromName(const std::string& s) {
        static const std::unordered_map<std::string, Motion> m = {
            {"stationary", Motion::Stationary}, {"walking",  Motion::Walking},
            {"running",    Motion::Running},    {"driving",  Motion::Driving},
        };
        auto it = m.find(s); return it != m.end() ? it->second : Motion::Unknown;
    }

    static PhonePos phoneFromName(const std::string& s) {
        static const std::unordered_map<std::string, PhonePos> m = {
            {"in_use",        PhonePos::InUse},        {"holding_lying", PhonePos::HoldingLying},
            {"on_desk",       PhonePos::OnDesk},       {"face_up",       PhonePos::FaceUp},
            {"in_pocket",     PhonePos::InPocket},     {"face_down",     PhonePos::FaceDown},
            {"charging",      PhonePos::Charging},     {"unknown",       PhonePos::UnknownVal},
        };
        auto it = m.find(s); return it != m.end() ? it->second : PhonePos::Unknown;
    }

    static Light lightFromName(const std::string& s) {
        static const std::unordered_map<std::string, Light> m = {
            {"dark", Light::Dark}, {"dim", Light::Dim},
            {"normal", Light::Normal}, {"bright", Light::Bright},
        };
        auto it = m.find(s); return it != m.end() ? it->second : Light::Unspecified;
    }

    static Sound soundFromName(const std::string& s) {
        static const std::unordered_map<std::string, Sound> m = {
            {"quiet", Sound::Quiet}, {"normal", Sound::Normal},
            {"noisy", Sound::Noisy}, {"unknown", Sound::Unknown},
        };
        auto it = m.find(s); return it != m.end() ? it->second : Sound::Unspecified;
    }

    static DayType dayTypeFromName(const std::string& s) {
        static const std::unordered_map<std::string, DayType> m = {
            {"workday", DayType::Workday}, {"weekend", DayType::Weekend},
            {"holiday", DayType::Holiday},
        };
        auto it = m.find(s); return it != m.end() ? it->second : DayType::Unspecified;
    }

    // ── 逆映射：枚举 → 字符串名称 ───────────────────────────

    static const char* timeName(TimeSlot t) {
        switch (t) {
            case TimeSlot::Sleeping:  return "sleeping";
            case TimeSlot::Dawn:      return "dawn";
            case TimeSlot::Morning:   return "morning";
            case TimeSlot::Forenoon:  return "forenoon";
            case TimeSlot::Lunch:     return "lunch";
            case TimeSlot::Afternoon: return "afternoon";
            case TimeSlot::Evening:   return "evening";
            case TimeSlot::Night:     return "night";
            case TimeSlot::LateNight: return "late_night";
            default:                  return "unknown";
        }
    }

    static const char* locationName(Location l) {
        switch (l) {
            case Location::Home:         return "home";
            case Location::Work:         return "work";
            case Location::Commute:      return "commute";
            case Location::Restaurant:   return "restaurant";
            case Location::Gym:          return "gym";
            case Location::Outdoor:      return "outdoor";
            case Location::Airport:      return "airport";
            case Location::Shopping:     return "shopping";
            case Location::Subway:       return "subway";
            case Location::BusStop:      return "bus_stop";
            case Location::Ferry:        return "ferry";
            case Location::TrainStation: return "train_station";
            case Location::Cafe:         return "cafe";
            case Location::Cinema:       return "cinema";
            case Location::Park:         return "park";
            default:                     return "unknown";
        }
    }

    static const char* motionName(Motion m) {
        switch (m) {
            case Motion::Stationary: return "stationary";
            case Motion::Walking:    return "walking";
            case Motion::Running:    return "running";
            case Motion::Driving:    return "driving";
            default:                 return "unknown";
        }
    }

    static const char* phoneName(PhonePos p) {
        switch (p) {
            case PhonePos::InUse:        return "in_use";
            case PhonePos::HoldingLying: return "holding_lying";
            case PhonePos::OnDesk:       return "on_desk";
            case PhonePos::FaceUp:       return "face_up";
            case PhonePos::InPocket:     return "in_pocket";
            case PhonePos::FaceDown:     return "face_down";
            case PhonePos::Charging:     return "charging";
            default:                     return "unknown";
        }
    }

    static const char* lightName(Light l) {
        switch (l) {
            case Light::Dark:   return "dark";
            case Light::Dim:    return "dim";
            case Light::Normal: return "normal";
            case Light::Bright: return "bright";
            default:            return "";
        }
    }

    static const char* soundName(Sound s) {
        switch (s) {
            case Sound::Quiet:  return "quiet";
            case Sound::Normal: return "normal";
            case Sound::Noisy:  return "noisy";
            case Sound::Unknown: return "unknown";
            default:            return "";
        }
    }

    static const char* dayTypeName(DayType d) {
        switch (d) {
            case DayType::Workday: return "workday";
            case DayType::Weekend: return "weekend";
            case DayType::Holiday: return "holiday";
            default:               return "";
        }
    }

private:
    // 小工具：把单字符字面量转成对应枚举值
    static Location A(const char* c) { return static_cast<Location>(c[0]); }

    static bool setTime(PhysicalState& s, char c) {
        if (c == '0') { s.time = TimeSlot::Unknown; return true; }
        if (c >= '1' && c <= '9') { s.time = static_cast<TimeSlot>(c); return true; }
        return false;
    }
    static bool setLocation(PhysicalState& s, char c) {
        if (c >= 'A' && c <= 'P') { s.location = static_cast<Location>(c); return true; }
        if (c == '0') { s.location = Location::Unknown; return true; }
        return false;
    }
    static bool setMotion(PhysicalState& s, char c) {
        if (c == '0') { s.motion = Motion::Unknown; return true; }
        if (c >= '1' && c <= '4') { s.motion = static_cast<Motion>(c); return true; }
        return false;
    }
    static bool setPhone(PhysicalState& s, char c) {
        if (c == '0') { s.phone = PhonePos::Unknown; return true; }
        if (c >= '1' && c <= '8') { s.phone = static_cast<PhonePos>(c); return true; }
        return false;
    }
    static bool setLight(PhysicalState& s, char c) {
        if (c >= '0' && c <= '4') { s.light = static_cast<Light>(c); return true; }
        return false;
    }
    static bool setSound(PhysicalState& s, char c) {
        if (c >= '0' && c <= '4') { s.sound = static_cast<Sound>(c); return true; }
        return false;
    }
    static bool setDayType(PhysicalState& s, char c) {
        if (c >= '0' && c <= '3') { s.dayType = static_cast<DayType>(c); return true; }
        return false;
    }
};

// ============================================================
// Tile Coding（瓦片编码，用于 RL 特征向量）
// ============================================================

/**
 * TileCoder：将 PhysicalState 编码为稀疏二进制特征向量。
 *
 * 设计了 5 套 tiling，每套粒度不同：
 *
 *   T0（细粒度）: time(9) × location(16) × motion(4) × phone(8) × dayType(3)
 *   T1（时间粗粒度）: timeGroup(4) × location(16) × dayType(3)  [早/午/晚/夜]
 *   T2（位置场景）: locationGroup(5) × motion(4) × phone(8)     [家/工作/交通/娱乐/运动]
 *   T3（活动组合）: motion(4) × phoneGroup(4) × timeGroup(4)    [使用/静放/口袋/充电]
 *   T4（环境感知）: light(5) × sound(5) × locationGroup(5)
 *
 * 每套 tiling 产生一个 one-hot 子向量，总向量是所有子向量的拼接（稀疏，共 5 个 1）。
 * 总维度 = T0_size + T1_size + T2_size + T3_size + T4_size
 */
class TileCoder {
public:
    // 各套 tiling 的维度
    static constexpr int T0_DIM = 9 * 16 * 4 * 8 * 3;   // 13824
    static constexpr int T1_DIM = 4 * 16 * 3;             // 192
    static constexpr int T2_DIM = 5 * 4 * 8;              // 160
    static constexpr int T3_DIM = 4 * 4 * 4;              // 64
    static constexpr int T4_DIM = 5 * 5 * 5;              // 125
    static constexpr int TOTAL_DIM = T0_DIM + T1_DIM + T2_DIM + T3_DIM + T4_DIM; // 14365

    /**
     * 返回激活的 tile 索引列表（共 5 个，对应 5 套 tiling）。
     * 稀疏表示：只存非零位置，不展开全部 14365 维。
     */
    static std::array<int, 5> activeIndices(const PhysicalState& s) {
        const int t   = timeIndex(s.time);       // 0-8
        const int tg  = timeGroup(s.time);       // 0-3
        const int l   = locationIndex(s.location); // 0-15
        const int lg  = locationGroup(s.location); // 0-4
        const int m   = motionIndex(s.motion);   // 0-3
        const int p   = phoneIndex(s.phone);     // 0-7
        const int pg  = phoneGroup(s.phone);     // 0-3
        const int li  = lightIndex(s.light);     // 0-4
        const int so  = soundIndex(s.sound);     // 0-4
        const int d   = dayTypeIndex(s.dayType); // 0-2

        // T0: 细粒度全组合
        int i0 = ((t * 16 + l) * 4 + m) * 8 * 3 + p * 3 + d;

        // T1: 时间粗 × 位置 × 日期
        int i1 = T0_DIM + (tg * 16 + l) * 3 + d;

        // T2: 位置场景 × 运动 × 手机
        int i2 = T0_DIM + T1_DIM + (lg * 4 + m) * 8 + p;

        // T3: 运动 × 手机粗 × 时间粗
        int i3 = T0_DIM + T1_DIM + T2_DIM + (m * 4 + pg) * 4 + tg;

        // T4: 光线 × 声音 × 位置场景
        int i4 = T0_DIM + T1_DIM + T2_DIM + T3_DIM + (li * 5 + so) * 5 + lg;

        return { i0, i1, i2, i3, i4 };
    }

    /**
     * 计算两个状态的 tile 重叠数（0-5）。
     * 重叠数越多，两个状态越相似。
     * 可用于 kNN 检索或简单的置信度加权。
     */
    static int tileOverlap(const PhysicalState& a, const PhysicalState& b) {
        const auto ia = activeIndices(a);
        const auto ib = activeIndices(b);
        int count = 0;
        for (int i = 0; i < 5; ++i)
            if (ia[i] == ib[i]) ++count;
        return count;
    }

    static constexpr int totalDim() { return TOTAL_DIM; }

private:
    // ── 维度索引辅助 ────────────────────────────────────────

    static int timeIndex(TimeSlot t) {
        int v = static_cast<int>(static_cast<char>(t) - '1');
        return (v >= 0 && v < 9) ? v : 0;
    }

    /** 时间粗分组：0=凌晨/清晨(sleeping/dawn)  1=上午(morning/forenoon)
     *              2=午后(lunch/afternoon)        3=傍晚/夜间(evening/night/late_night) */
    static int timeGroup(TimeSlot t) {
        switch (t) {
            case TimeSlot::Sleeping: case TimeSlot::Dawn:                      return 0;
            case TimeSlot::Morning:  case TimeSlot::Forenoon:                  return 1;
            case TimeSlot::Lunch:    case TimeSlot::Afternoon:                 return 2;
            case TimeSlot::Evening:  case TimeSlot::Night: case TimeSlot::LateNight: return 3;
            default: return 0;
        }
    }

    static int locationIndex(Location l) {
        int v = static_cast<int>(static_cast<char>(l) - 'A');
        return (v >= 0 && v < 16) ? v : 15; // 'P'=15=unknown
    }

    /** 位置场景粗分组：0=家/室内  1=工作  2=交通  3=娱乐休闲  4=运动/户外 */
    static int locationGroup(Location l) {
        switch (l) {
            case Location::Home:                                                 return 0;
            case Location::Work:                                                 return 1;
            case Location::Commute: case Location::Subway: case Location::BusStop:
            case Location::Ferry:   case Location::TrainStation: case Location::Airport: return 2;
            case Location::Restaurant: case Location::Shopping: case Location::Cafe:
            case Location::Cinema:                                               return 3;
            case Location::Gym:  case Location::Outdoor: case Location::Park:   return 4;
            default: return 0;
        }
    }

    static int motionIndex(Motion m) {
        int v = static_cast<int>(static_cast<char>(m) - '1');
        return (v >= 0 && v < 4) ? v : 0;
    }

    static int phoneIndex(PhonePos p) {
        int v = static_cast<int>(static_cast<char>(p) - '1');
        return (v >= 0 && v < 8) ? v : 7;
    }

    /** 手机粗分组：0=主动使用(in_use/holding_lying)  1=静放(on_desk/face_up/face_down)
     *              2=口袋/携带(in_pocket)               3=充电/未知 */
    static int phoneGroup(PhonePos p) {
        switch (p) {
            case PhonePos::InUse: case PhonePos::HoldingLying: return 0;
            case PhonePos::OnDesk: case PhonePos::FaceUp: case PhonePos::FaceDown: return 1;
            case PhonePos::InPocket:                           return 2;
            default:                                           return 3;
        }
    }

    static int lightIndex(Light l) {
        int v = static_cast<int>(static_cast<char>(l) - '0');
        return (v >= 0 && v < 5) ? v : 0;
    }

    static int soundIndex(Sound s) {
        int v = static_cast<int>(static_cast<char>(s) - '0');
        return (v >= 0 && v < 5) ? v : 0;
    }

    static int dayTypeIndex(DayType d) {
        int v = static_cast<int>(static_cast<char>(d) - '0');
        return (v >= 1 && v <= 3) ? v - 1 : 0;
    }
};

} // namespace context_engine
