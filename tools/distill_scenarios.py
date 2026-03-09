#!/usr/bin/env python3
"""
distill_scenarios.py — 场景蒸馏训练脚本

从 72 个场景原型生成训练数据，预训练 MLP V2 权重。

流程:
  1. 从 scenario_distiller.h 中提取场景原型（关键状态 + 动作分布）
  2. 生成带变异的训练数据（中间状态、时间偏移、噪声）
  3. 用 SGD 训练 MLP (60→64→64)
  4. 导出 C++ 权重头文件 pretrained_weights_v2.h

用法:
  python3 tools/distill_scenarios.py [--epochs 200] [--lr 0.02] [--output <path>]
"""

import numpy as np
import json
import argparse
import os
import sys
from itertools import product as cartesian_product

# ============================================================
# 常量 (与 state_attributes.h 一致)
# ============================================================

SA_SINGLE_DIM = 19
SA_CHAIN_DIM = 60   # 19*3 + 3
SA_CHAIN_MAX = 6
ACT_COUNT = 64
MLP_HID = 64

# ============================================================
# 枚举映射 (与 state_code.h 一致)
# ============================================================

TIME_MAP = {
    'sleeping': 1, 'dawn': 2, 'morning': 3, 'forenoon': 4,
    'lunch': 5, 'afternoon': 6, 'evening': 7, 'night': 8, 'late_night': 9
}

LOC_MAP = {
    'home': 1, 'work': 2, 'commute': 3, 'restaurant': 4, 'gym': 5,
    'outdoor': 6, 'airport': 7, 'shopping': 8, 'subway': 9,
    'bus_stop': 10, 'ferry': 11, 'train_station': 12, 'cafe': 13,
    'cinema': 14, 'park': 15
}

MOTION_MAP = {'stationary': 1, 'walking': 2, 'running': 3, 'driving': 4}

PHONE_MAP = {
    'in_use': 1, 'holding_lying': 2, 'on_desk': 3, 'face_up': 4,
    'in_pocket': 5, 'face_down': 6, 'charging': 7, 'unknown': 8
}

LIGHT_MAP = {'': 0, 'dark': 1, 'dim': 2, 'normal': 3, 'bright': 4}
SOUND_MAP = {'': 0, 'quiet': 1, 'normal': 2, 'noisy': 3, 'unknown': 4}
DAYTYPE_MAP = {'': 0, 'workday': 1, 'weekend': 2, 'holiday': 3}


# ============================================================
# 属性编码 (与 state_attributes.h 一致)
# ============================================================

LOC_CATEGORY_ATTRS = {
    #              indoor, workRest, private, noise, stayExpect
    1:  (1.0, 0.0, 1.0, 0.1, 1.0),  # home
    2:  (1.0, 1.0, 0.5, 0.3, 1.0),  # work
    3:  (0.5, 0.0, 0.0, 0.6, 0.1),  # commute
    4:  (1.0, 0.0, 0.0, 0.6, 0.6),  # restaurant
    5:  (0.8, 0.0, 0.0, 0.5, 0.6),  # gym
    6:  (0.0, 0.0, 0.0, 0.4, 0.4),  # outdoor
    7:  (0.9, 0.0, 0.0, 0.7, 0.7),  # airport
    8:  (0.9, 0.0, 0.0, 0.6, 0.5),  # shopping
    9:  (0.9, 0.0, 0.0, 0.7, 0.2),  # subway
    10: (0.2, 0.0, 0.0, 0.6, 0.1),  # bus_stop
    11: (0.5, 0.0, 0.0, 0.5, 0.4),  # ferry
    12: (0.8, 0.0, 0.0, 0.7, 0.5),  # train_station
    13: (1.0, 0.5, 0.2, 0.3, 0.7),  # cafe
    14: (1.0, 0.0, 0.0, 0.2, 0.8),  # cinema
    15: (0.0, 0.0, 0.0, 0.2, 0.5),  # park
    0:  (0.5, 0.5, 0.5, 0.5, 0.5),  # unknown
}

MOTION_ATTRS = {
    1: (0.0, 1.0), 2: (0.3, 0.8), 3: (0.7, 0.7), 4: (1.0, 0.6), 0: (0.0, 0.5)
}

PHONE_ATTRS = {
    1: (1.0, 1.0), 2: (0.7, 1.0), 3: (0.1, 0.9), 4: (0.0, 0.8),
    5: (0.0, 0.3), 6: (0.0, 0.5), 7: (0.0, 0.7), 8: (0.0, 0.5), 0: (0.0, 0.5)
}


def encode_state(time_str, loc_str, motion_str, phone_str,
                 light_str='', sound_str='', daytype_str='',
                 inst_familiarity=0.0, inst_ownership=0.0, inst_routine=0.0):
    """Encode a physical state to 19-dim attribute vector."""
    v = np.zeros(SA_SINGLE_DIM, dtype=np.float32)

    # Time: normalize 1-9 → [0, 1]
    t = TIME_MAP.get(time_str, 0)
    v[0] = (t - 1) / 8.0 if t > 0 else 0.5

    # Location category (5d)
    loc = LOC_MAP.get(loc_str, 0)
    la = LOC_CATEGORY_ATTRS.get(loc, LOC_CATEGORY_ATTRS[0])
    v[1:6] = la

    # Location instance (3d)
    v[6] = inst_familiarity
    v[7] = inst_ownership
    v[8] = inst_routine

    # Motion (2d)
    m = MOTION_MAP.get(motion_str, 0)
    v[9:11] = MOTION_ATTRS.get(m, MOTION_ATTRS[0])

    # Phone (2d)
    p = PHONE_MAP.get(phone_str, 0)
    v[11:13] = PHONE_ATTRS.get(p, PHONE_ATTRS[0])

    # Light (1d)
    li = LIGHT_MAP.get(light_str, 0)
    v[13] = li / 4.0 if li > 0 else 0.5

    # Sound (1d)
    so = SOUND_MAP.get(sound_str, 0)
    v[14] = so / 4.0 if so > 0 else 0.5

    # DayType (2d: isWorkday, isSpecial)
    dt = DAYTYPE_MAP.get(daytype_str, 0)
    v[15] = 1.0 if dt == 1 else 0.0
    v[16] = 1.0 if dt == 3 else 0.0

    # Note: SA_SINGLE_DIM = 19, but we only used indices 0-16 (17 dims)
    # The remaining 2 dims (17, 18) are reserved / zero
    # Actually, looking at state_attributes.h more carefully:
    # SA_OFF_DAYTYPE = 15, which is 2 dims → indices 15, 16
    # Total used = 1(time) + 8(loc) + 2(motion) + 2(phone) + 1(light) + 1(sound) + 2(daytype) = 17
    # Indices 17, 18 are padding → leave as 0

    return v


def build_chain_feature(state_vecs):
    """Build 60-dim chain feature from list of 19-dim state vectors.
    Matches ChainFeature::build() in state_attributes.h."""
    feat = np.zeros(SA_CHAIN_DIM, dtype=np.float32)
    if len(state_vecs) == 0:
        return feat

    current = state_vecs[-1]
    first = state_vecs[0]

    # [0..18] current
    feat[0:SA_SINGLE_DIM] = current

    # [19..37] mean pool
    mean = np.mean(state_vecs, axis=0)
    feat[SA_SINGLE_DIM:SA_SINGLE_DIM*2] = mean

    # [38..56] delta (current - first)
    feat[SA_SINGLE_DIM*2:SA_SINGLE_DIM*3] = current - first

    # [57] chain duration norm (synthetic: assign based on chain length)
    chain_len = len(state_vecs)
    if chain_len <= 1:
        feat[57] = 0.0
    elif chain_len <= 2:
        feat[57] = 0.33
    elif chain_len <= 4:
        feat[57] = 0.67
    else:
        feat[57] = 1.0

    # [58] time in current state (synthetic: 0.0 = just arrived)
    feat[58] = 0.0

    # [59] chain length norm
    feat[59] = chain_len / SA_CHAIN_MAX

    return feat


# ============================================================
# 场景定义 (72 场景的关键状态 + 动作分布)
# ============================================================

# ActionCatalog index reference:
#   0=A1亮地铁码  1=A2亮公交码  2=A3亮支付码  3=A4亮门票
#   4=B1查今日    5=B2查明日    6=B3查下午    7=B4设闹钟    8=B5出行提醒
#   9=B6散场提醒  10=B7查行程   11=B8提醒检票  12=B9下班提醒
#   13=C1天气
#   14=D1音乐     15=D2白噪音   16=D3播客     17=D4新闻
#   18=E1回家     19=E2到公司   20=E3到餐厅   21=E4到店铺   22=E5到枢纽
#   23=E6导航景点  24=E7通用导航  25=E8停车
#   26=F1到站时间  27=F2提醒下车  28=F3船班     29=F4座位
#   30=G1久坐     31=G2补水     32=G3拉伸     33=G4步数     34=G5休息
#   35=H1餐饮
#   36=I1社交
#   37=J1关通知   38=J2静音     39=J3注意财物


def make_action_dist(*pairs):
    """Create action distribution from (index, weight) pairs, normalized."""
    dist = np.zeros(ACT_COUNT, dtype=np.float32)
    for idx, w in pairs:
        dist[idx] = w
    s = dist.sum()
    if s > 0:
        dist /= s
    return dist


# Scenario definitions: (id, name, key_states, action_dist)
# key_states = [(time, loc, motion, phone, light, sound, daytype), ...]

SCENARIOS = [
    # ======== 早晨 ========
    ("S01", "workday_morning", [
        ("dawn",    "home", "stationary", "charging", "dark",   "quiet",  "workday"),
        ("morning", "home", "walking",    "in_use",   "dim",    "quiet",  "workday"),
        ("morning", "home", "stationary", "in_use",   "normal", "quiet",  "workday"),
    ], make_action_dist((13,0.4),(4,0.3),(8,0.2),(17,0.1))),

    ("S02", "weekend_sleep_in", [
        ("morning", "home", "stationary", "charging", "dark",  "quiet", "weekend"),
        ("morning", "home", "stationary", "in_use",   "dim",   "quiet", "weekend"),
    ], make_action_dist((37,0.4),(5,0.3),(17,0.3))),

    ("S03", "morning_jog", [
        ("dawn",    "home",    "stationary", "charging",  "dark",   "quiet",  ""),
        ("dawn",    "home",    "walking",    "in_pocket", "dim",    "quiet",  ""),
        ("morning", "outdoor", "running",    "in_pocket", "bright", "normal", ""),
        ("morning", "home",    "stationary", "in_use",    "normal", "quiet",  ""),
    ], make_action_dist((14,0.35),(33,0.3),(32,0.2),(13,0.15))),

    ("S04", "morning_yoga", [
        ("dawn", "home", "stationary", "face_down", "dim", "quiet", ""),
    ], make_action_dist((37,0.4),(15,0.3),(14,0.3))),

    ("S05", "breakfast_prep", [
        ("morning", "home", "walking", "on_desk", "normal", "quiet", ""),
    ], make_action_dist((17,0.5),(13,0.3),(35,0.2))),

    ("S06", "school_drop", [
        ("morning", "home",    "walking",    "in_use",    "normal", "quiet",  "workday"),
        ("morning", "commute", "driving",    "in_pocket", "bright", "normal", "workday"),
    ], make_action_dist((24,0.5),(8,0.3),(14,0.2))),

    # ======== 通勤 ========
    ("S07", "drive_to_work", [
        ("morning", "home",    "stationary", "in_use",    "normal", "quiet",  "workday"),
        ("morning", "commute", "driving",    "in_pocket", "bright", "normal", "workday"),
        ("forenoon","work",    "stationary", "on_desk",   "normal", "quiet",  "workday"),
    ], make_action_dist((19,0.4),(14,0.3),(13,0.15),(4,0.15))),

    ("S08", "transit_to_work", [
        ("morning", "home",   "walking",    "in_use",    "normal", "quiet",  "workday"),
        ("morning", "subway", "stationary", "in_use",    "dim",    "noisy",  "workday"),
        ("forenoon","work",   "stationary", "on_desk",   "normal", "quiet",  "workday"),
    ], make_action_dist((0,0.35),(14,0.25),(17,0.2),(4,0.2))),

    ("S09", "cycle_to_work", [
        ("morning", "home",    "walking",    "in_use",    "normal", "quiet",  "workday"),
        ("morning", "commute", "driving",    "in_pocket", "bright", "normal", "workday"),
        ("forenoon","work",    "stationary", "on_desk",   "normal", "quiet",  "workday"),
    ], make_action_dist((33,0.3),(14,0.3),(19,0.2),(13,0.2))),

    ("S10", "drive_home_evening", [
        ("evening", "work",    "stationary", "in_use",    "normal", "quiet",  "workday"),
        ("evening", "commute", "driving",    "in_pocket", "dim",    "normal", "workday"),
        ("evening", "home",    "stationary", "in_use",    "normal", "quiet",  "workday"),
    ], make_action_dist((18,0.4),(14,0.35),(12,0.15),(4,0.1))),

    ("S11", "transit_home_evening", [
        ("evening", "work",   "stationary", "in_use",    "normal", "quiet",  "workday"),
        ("evening", "subway", "stationary", "in_use",    "dim",    "noisy",  "workday"),
        ("evening", "home",   "stationary", "in_use",    "normal", "quiet",  "workday"),
    ], make_action_dist((0,0.3),(14,0.25),(16,0.2),(27,0.15),(18,0.1))),

    ("S12", "overtime_late", [
        ("night",   "work",    "stationary", "in_use",    "normal", "quiet",  "workday"),
        ("night",   "commute", "driving",    "in_pocket", "dark",   "quiet",  "workday"),
        ("night",   "home",    "stationary", "in_use",    "dim",    "quiet",  "workday"),
    ], make_action_dist((18,0.4),(12,0.3),(37,0.2),(14,0.1))),

    # ======== 工作 ========
    ("S13", "work_start", [
        ("forenoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
    ], make_action_dist((4,0.5),(37,0.3),(13,0.2))),

    ("S14", "focus_work", [
        ("forenoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
    ], make_action_dist((37,0.5),(30,0.3),(31,0.2))),

    ("S15", "meeting", [
        ("forenoon", "work", "stationary", "face_down", "normal", "noisy", "workday"),
    ], make_action_dist((38,0.5),(37,0.5))),

    ("S16", "lunch_out", [
        ("lunch", "work",       "walking",    "in_pocket", "normal", "quiet",  "workday"),
        ("lunch", "restaurant", "stationary", "on_desk",   "normal", "noisy",  "workday"),
        ("lunch", "work",       "stationary", "on_desk",   "normal", "quiet",  "workday"),
    ], make_action_dist((2,0.3),(35,0.25),(20,0.25),(38,0.2))),

    ("S17", "office_lunch", [
        ("lunch", "work", "stationary", "in_use", "normal", "quiet", "workday"),
    ], make_action_dist((17,0.4),(34,0.3),(31,0.3))),

    ("S18", "afternoon_break", [
        ("afternoon", "work", "walking",    "in_pocket", "normal", "quiet", "workday"),
        ("afternoon", "work", "stationary", "in_use",    "normal", "quiet", "workday"),
    ], make_action_dist((30,0.3),(32,0.3),(17,0.2),(31,0.2))),

    ("S19", "prepare_leave", [
        ("evening", "work", "stationary", "in_use", "normal", "quiet", "workday"),
    ], make_action_dist((12,0.4),(18,0.3),(13,0.3))),

    ("S20", "overtime", [
        ("evening", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
    ], make_action_dist((37,0.3),(30,0.25),(31,0.25),(34,0.2))),

    # ======== 居家 ========
    ("S21", "home_relax", [
        ("evening", "home", "stationary", "in_use", "normal", "quiet", "workday"),
    ], make_action_dist((14,0.4),(17,0.3),(13,0.3))),

    ("S22", "cooking", [
        ("evening", "home", "walking", "on_desk", "normal", "normal", ""),
    ], make_action_dist((35,0.4),(14,0.3),(17,0.3))),

    ("S23", "home_dinner", [
        ("evening", "home", "stationary", "face_down", "normal", "quiet", ""),
    ], make_action_dist((37,0.3),(17,0.35),(14,0.35))),

    ("S24", "watching_tv", [
        ("night", "home", "stationary", "on_desk", "dim", "normal", ""),
    ], make_action_dist((37,0.5),(34,0.5))),

    ("S25", "reading", [
        ("night", "home", "stationary", "face_up", "dim", "quiet", ""),
    ], make_action_dist((37,0.5),(15,0.3),(34,0.2))),

    ("S26", "gaming", [
        ("night", "home", "stationary", "in_use", "dim", "quiet", ""),
    ], make_action_dist((37,0.5),(34,0.3),(31,0.2))),

    ("S27", "home_lunch", [
        ("lunch", "home", "stationary", "in_use", "normal", "quiet", ""),
    ], make_action_dist((17,0.4),(35,0.3),(34,0.3))),

    ("S28", "nap", [
        ("lunch", "home", "stationary", "face_down", "dim", "quiet", ""),
    ], make_action_dist((37,0.5),(7,0.3),(15,0.2))),

    ("S29", "housework", [
        ("afternoon", "home", "walking", "in_pocket", "normal", "normal", "weekend"),
    ], make_action_dist((14,0.5),(16,0.3),(33,0.2))),

    ("S30", "babysitting", [
        ("afternoon", "home", "walking", "in_pocket", "normal", "noisy", "weekend"),
    ], make_action_dist((37,0.5),(34,0.3),(31,0.2))),

    ("S31", "wfh", [
        ("forenoon", "home", "stationary", "in_use", "normal", "quiet", "workday"),
    ], make_action_dist((37,0.3),(4,0.3),(30,0.2),(31,0.2))),

    ("S32", "weekend_home", [
        ("forenoon", "home", "stationary", "in_use", "normal", "quiet", "weekend"),
    ], make_action_dist((17,0.3),(14,0.3),(13,0.2),(34,0.2))),

    # ======== 睡眠 ========
    ("S33", "bedtime", [
        ("night",      "home", "stationary", "in_use",   "dim",  "quiet", ""),
        ("late_night", "home", "stationary", "charging", "dark", "quiet", ""),
    ], make_action_dist((37,0.4),(7,0.3),(15,0.3))),

    ("S34", "afternoon_nap", [
        ("lunch", "home", "stationary", "face_down", "dim", "quiet", ""),
    ], make_action_dist((37,0.4),(7,0.3),(15,0.3))),

    ("S35", "early_wake", [
        ("dawn", "home", "stationary", "face_up", "dark", "quiet", ""),
    ], make_action_dist((37,0.6),(15,0.4))),

    ("S36", "insomnia", [
        ("sleeping", "home", "stationary", "in_use", "dark", "quiet", ""),
    ], make_action_dist((15,0.5),(37,0.3),(34,0.2))),

    ("S37", "bathroom_night", [
        ("sleeping", "home", "walking", "face_up", "dark", "quiet", ""),
        ("sleeping", "home", "stationary", "charging", "dark", "quiet", ""),
    ], make_action_dist((37,0.7),(15,0.3))),

    # ======== 运动 ========
    ("S38", "gym_arrive", [
        ("evening", "gym", "stationary", "in_pocket", "bright", "noisy", ""),
    ], make_action_dist((14,0.4),(37,0.3),(33,0.3))),

    ("S39", "gym_workout", [
        ("evening", "gym", "walking", "in_pocket", "bright", "noisy", ""),
    ], make_action_dist((14,0.4),(37,0.3),(30,0.3))),

    ("S40", "gym_finish", [
        ("evening", "gym", "stationary", "in_use", "bright", "noisy", ""),
    ], make_action_dist((33,0.5),(32,0.3),(31,0.2))),

    ("S41", "outdoor_run", [
        ("morning", "outdoor", "running", "in_pocket", "bright", "normal", ""),
    ], make_action_dist((14,0.3),(33,0.3),(32,0.2),(31,0.2))),

    ("S42", "outdoor_walk", [
        ("afternoon", "outdoor", "walking", "in_pocket", "bright", "normal", ""),
    ], make_action_dist((16,0.3),(33,0.3),(14,0.2),(13,0.2))),

    ("S43", "cycling", [
        ("afternoon", "commute", "driving", "in_pocket", "bright", "normal", ""),
    ], make_action_dist((33,0.3),(14,0.3),(24,0.2),(13,0.2))),

    # ======== 餐饮 ========
    ("S44", "lunch_restaurant", [
        ("lunch", "restaurant", "stationary", "on_desk", "normal", "noisy", "workday"),
    ], make_action_dist((2,0.4),(38,0.3),(35,0.3))),

    ("S45", "dinner_restaurant", [
        ("evening", "restaurant", "stationary", "on_desk", "normal", "noisy", ""),
    ], make_action_dist((2,0.4),(38,0.3),(35,0.3))),

    ("S46", "friends_dinner", [
        ("evening", "restaurant", "stationary", "face_down", "normal", "noisy", ""),
    ], make_action_dist((38,0.4),(37,0.3),(2,0.3))),

    ("S47", "cafe", [
        ("afternoon", "cafe", "stationary", "in_use", "normal", "quiet", ""),
    ], make_action_dist((14,0.3),(15,0.3),(31,0.2),(30,0.2))),

    ("S48", "food_delivery", [
        ("lunch", "work", "stationary", "in_use", "normal", "quiet", "workday"),
    ], make_action_dist((35,0.6),(4,0.2),(31,0.2))),

    # ======== 购物 ========
    ("S49", "grocery", [
        ("afternoon", "shopping", "walking", "in_use", "bright", "normal", ""),
    ], make_action_dist((2,0.5),(39,0.3),(33,0.2))),

    ("S50", "mall", [
        ("afternoon", "shopping", "walking", "in_use", "bright", "noisy", ""),
    ], make_action_dist((2,0.4),(39,0.3),(33,0.3))),

    ("S51", "convenience", [
        ("evening", "shopping", "walking", "in_use", "bright", "quiet", ""),
    ], make_action_dist((2,0.7),(39,0.3))),

    # ======== 出行 ========
    ("S52", "to_airport", [
        ("morning", "home",    "walking",    "in_use",    "normal", "quiet",  ""),
        ("morning", "commute", "driving",    "in_pocket", "bright", "normal", ""),
        ("morning", "airport", "walking",    "in_use",    "bright", "noisy",  ""),
    ], make_action_dist((10,0.3),(22,0.3),(24,0.2),(14,0.2))),

    ("S53", "airport_wait", [
        ("morning", "airport", "stationary", "in_use", "bright", "noisy", ""),
    ], make_action_dist((10,0.4),(17,0.3),(14,0.2),(37,0.1))),

    ("S54", "boarding_soon", [
        ("morning", "airport", "walking", "in_use", "bright", "noisy", ""),
    ], make_action_dist((3,0.4),(11,0.3),(10,0.3))),

    ("S55", "urgent_boarding", [
        ("morning", "airport", "running", "in_use", "bright", "noisy", ""),
    ], make_action_dist((3,0.5),(11,0.3),(24,0.2))),

    ("S56", "inflight", [
        ("morning", "airport", "stationary", "in_use", "dim", "noisy", ""),
    ], make_action_dist((37,0.5),(17,0.3),(14,0.2))),

    ("S57", "landed", [
        ("afternoon", "airport", "walking", "in_use", "bright", "noisy", ""),
    ], make_action_dist((24,0.3),(10,0.3),(13,0.2),(36,0.2))),

    ("S58", "train_travel", [
        ("morning", "train_station", "walking",    "in_use",    "bright", "noisy",  ""),
        ("morning", "train_station", "stationary", "in_use",    "dim",    "normal", ""),
        ("afternoon","train_station","walking",    "in_use",    "bright", "noisy",  ""),
    ], make_action_dist((0,0.3),(10,0.3),(14,0.2),(27,0.2))),

    ("S59", "ridehail", [
        ("evening", "outdoor",  "stationary", "in_use",    "dim",    "normal", ""),
        ("evening", "commute",  "driving",    "in_pocket", "dim",    "quiet",  ""),
    ], make_action_dist((24,0.4),(14,0.3),(18,0.3))),

    # ======== 社交 ========
    ("S60", "friends_visit", [
        ("evening", "home", "stationary", "face_down", "normal", "noisy", ""),
    ], make_action_dist((37,0.3),(14,0.4),(36,0.3))),

    ("S61", "social_out", [
        ("evening", "restaurant", "stationary", "face_down", "normal", "noisy", "weekend"),
    ], make_action_dist((38,0.4),(37,0.3),(36,0.3))),

    ("S62", "event_attend", [
        ("afternoon", "cinema", "stationary", "face_down", "dim", "normal", ""),
    ], make_action_dist((38,0.4),(37,0.4),(36,0.2))),

    # ======== 健康 ========
    ("S63", "sedentary", [
        ("forenoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
    ], make_action_dist((30,0.5),(32,0.3),(31,0.2))),

    ("S64", "hydration", [
        ("afternoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
    ], make_action_dist((31,0.5),(30,0.3),(34,0.2))),

    ("S65", "eye_care", [
        ("night", "home", "stationary", "in_use", "dim", "quiet", ""),
    ], make_action_dist((34,0.5),(30,0.3),(15,0.2))),

    ("S66", "standup", [
        ("afternoon", "work", "stationary", "on_desk", "normal", "quiet", "workday"),
    ], make_action_dist((30,0.4),(32,0.3),(33,0.3))),

    ("S67", "late_sleep_warn", [
        ("late_night", "home", "stationary", "in_use", "dim", "quiet", ""),
    ], make_action_dist((34,0.4),(37,0.3),(15,0.3))),

    # ======== 设备 ========
    ("S68", "low_battery", [
        ("afternoon", "outdoor", "walking", "in_use", "bright", "normal", ""),
    ], make_action_dist((37,0.5),(24,0.3),(39,0.2))),

    ("S69", "critical_battery", [
        ("evening", "outdoor", "walking", "in_use", "dim", "normal", ""),
    ], make_action_dist((37,0.6),(18,0.2),(24,0.2))),

    ("S70", "charge_done", [
        ("night", "home", "stationary", "charging", "dim", "quiet", ""),
    ], make_action_dist((37,0.5),(4,0.3),(13,0.2))),

    ("S71", "car_bluetooth", [
        ("morning", "commute", "driving", "in_pocket", "normal", "quiet", ""),
    ], make_action_dist((14,0.3),(24,0.3),(19,0.2),(4,0.2))),

    ("S72", "meeting_soon", [
        ("forenoon", "work", "stationary", "in_use", "normal", "quiet", "workday"),
    ], make_action_dist((4,0.3),(38,0.3),(37,0.2),(30,0.2))),
]


# ============================================================
# 数据增强：生成变异训练样本
# ============================================================

# 时间邻近关系
TIME_NEIGHBORS = {
    'sleeping': ['dawn'],
    'dawn': ['sleeping', 'morning'],
    'morning': ['dawn', 'forenoon'],
    'forenoon': ['morning', 'lunch'],
    'lunch': ['forenoon', 'afternoon'],
    'afternoon': ['lunch', 'evening'],
    'evening': ['afternoon', 'night'],
    'night': ['evening', 'late_night'],
    'late_night': ['night', 'sleeping'],
}

# 可能的中间状态 (位置转换时的过渡)
TRANSITION_STATES = {
    ('home', 'work'):       [("commute", "walking"), ("commute", "driving"), ("subway", "stationary")],
    ('home', 'outdoor'):    [("commute", "walking")],
    ('home', 'gym'):        [("commute", "driving"), ("commute", "walking")],
    ('home', 'restaurant'): [("commute", "walking"), ("commute", "driving")],
    ('home', 'subway'):     [("commute", "walking")],
    ('home', 'airport'):    [("commute", "driving")],
    ('work', 'home'):       [("commute", "walking"), ("commute", "driving"), ("subway", "stationary")],
    ('work', 'restaurant'): [("commute", "walking")],
    ('work', 'subway'):     [("commute", "walking")],
    ('outdoor', 'home'):    [("commute", "walking")],
    ('gym', 'home'):        [("commute", "walking"), ("commute", "driving")],
    ('airport', 'home'):    [("commute", "driving")],
    ('restaurant', 'work'): [("commute", "walking")],
    ('restaurant', 'home'): [("commute", "driving"), ("commute", "walking")],
}


def add_noise(vec, noise_level=0.05):
    """Add small Gaussian noise to state vector."""
    noise = np.random.randn(SA_SINGLE_DIM).astype(np.float32) * noise_level
    noisy = np.clip(vec + noise, 0.0, 1.0)
    return noisy


def generate_training_data(scenarios, augment_factor=10):
    """Generate (feature, target) pairs from scenario definitions."""
    features = []
    targets = []

    for sid, name, key_states, action_dist in scenarios:
        # 1. 原始场景链（直接用关键状态）
        state_vecs = [encode_state(*s) for s in key_states]
        feat = build_chain_feature(state_vecs)
        features.append(feat)
        targets.append(action_dist)

        # 2. 带噪声的变异
        for _ in range(augment_factor // 2):
            noisy_vecs = [add_noise(v) for v in state_vecs]
            feat = build_chain_feature(noisy_vecs)
            features.append(feat)
            targets.append(action_dist)

        # 3. 带中间状态的变异
        for _ in range(augment_factor // 2):
            augmented_chain = []
            for si, state in enumerate(key_states):
                augmented_chain.append(encode_state(*state))

                # 在连续状态之间插入中间状态
                if si < len(key_states) - 1:
                    loc_from = state[1]
                    loc_to = key_states[si + 1][1]
                    trans_key = (loc_from, loc_to)

                    if trans_key in TRANSITION_STATES and np.random.random() < 0.6:
                        trans = TRANSITION_STATES[trans_key]
                        chosen = trans[np.random.randint(len(trans))]
                        # 中间状态的时间用当前或下一个
                        mid_time = state[0] if np.random.random() < 0.5 else key_states[si+1][0]
                        mid_phone = state[3] if np.random.random() < 0.5 else key_states[si+1][3]
                        mid_light = state[4] if np.random.random() < 0.5 else key_states[si+1][4]
                        mid_sound = state[5] if np.random.random() < 0.5 else key_states[si+1][5]
                        mid_daytype = state[6]
                        mid_vec = encode_state(mid_time, chosen[0], chosen[1], mid_phone,
                                               mid_light, mid_sound, mid_daytype)
                        augmented_chain.append(add_noise(mid_vec, 0.03))

            # 截断到最大链长
            if len(augmented_chain) > SA_CHAIN_MAX:
                # 保留首尾，均匀采样中间
                indices = [0] + sorted(np.random.choice(
                    range(1, len(augmented_chain)-1),
                    min(SA_CHAIN_MAX-2, len(augmented_chain)-2),
                    replace=False
                ).tolist()) + [len(augmented_chain)-1]
                augmented_chain = [augmented_chain[i] for i in indices]

            feat = build_chain_feature(augmented_chain)
            features.append(feat)
            targets.append(action_dist)

        # 4. 只用最后 N 个状态（模拟部分链）
        if len(key_states) >= 2:
            for start in range(1, len(key_states)):
                partial = [encode_state(*s) for s in key_states[start:]]
                feat = build_chain_feature(partial)
                features.append(feat)
                targets.append(action_dist)

        # 5. 时间邻近变异
        for _ in range(augment_factor // 4):
            varied_states = []
            for s in key_states:
                time_str = s[0]
                if time_str and np.random.random() < 0.3 and time_str in TIME_NEIGHBORS:
                    neighbors = TIME_NEIGHBORS[time_str]
                    time_str = neighbors[np.random.randint(len(neighbors))]
                varied_states.append(encode_state(time_str, *s[1:]))
            feat = build_chain_feature(varied_states)
            features.append(feat)
            targets.append(action_dist)

    return np.array(features), np.array(targets)


# ============================================================
# MLP 训练 (SGD with cross-entropy)
# ============================================================

def softmax(logits):
    """Numerically stable softmax."""
    e = np.exp(logits - logits.max(axis=-1, keepdims=True))
    return e / e.sum(axis=-1, keepdims=True)


def relu(x):
    return np.maximum(0, x)


def cross_entropy(pred, target):
    """Cross-entropy loss."""
    return -np.sum(target * np.log(pred + 1e-8)) / len(pred)


def train_mlp(features, targets, hidden=MLP_HID, epochs=200, lr=0.02,
              batch_size=32, decay=0.98, verbose=True):
    """Train MLP (IN→HID→OUT) with mini-batch SGD."""
    IN = features.shape[1]
    OUT = targets.shape[1]
    N = features.shape[0]

    # Xavier initialization
    W1 = np.random.randn(hidden, IN).astype(np.float32) * np.sqrt(2.0 / IN)
    b1 = np.zeros(hidden, dtype=np.float32)
    W2 = np.random.randn(OUT, hidden).astype(np.float32) * np.sqrt(2.0 / hidden)
    b2 = np.zeros(OUT, dtype=np.float32)

    for epoch in range(epochs):
        # Shuffle
        perm = np.random.permutation(N)
        total_loss = 0.0

        for i in range(0, N, batch_size):
            batch_idx = perm[i:i+batch_size]
            X = features[batch_idx]  # (B, IN)
            Y = targets[batch_idx]   # (B, OUT)
            B = len(batch_idx)

            # Forward
            h_pre = X @ W1.T + b1  # (B, HID)
            h = relu(h_pre)
            logits = h @ W2.T + b2  # (B, OUT)
            pred = softmax(logits)

            total_loss += cross_entropy(pred, Y) * B

            # Backward
            dLogits = (pred - Y) / B  # (B, OUT)
            dW2 = dLogits.T @ h       # (OUT, HID)
            db2 = dLogits.sum(axis=0)  # (OUT,)

            dH = dLogits @ W2          # (B, HID)
            dH[h_pre <= 0] = 0         # ReLU backward

            dW1 = dH.T @ X            # (HID, IN)
            db1 = dH.sum(axis=0)       # (HID,)

            # Update
            W1 -= lr * dW1
            b1 -= lr * db1
            W2 -= lr * dW2
            b2 -= lr * db2

        avg_loss = total_loss / N
        lr *= decay

        if verbose and (epoch % 20 == 0 or epoch == epochs - 1):
            # Compute accuracy: top-1 match
            h = relu(features @ W1.T + b1)
            pred = softmax(h @ W2.T + b2)
            pred_top = np.argmax(pred, axis=1)
            true_top = np.argmax(targets, axis=1)
            acc = np.mean(pred_top == true_top)
            print(f"  Epoch {epoch:4d} | loss={avg_loss:.4f} | top1_acc={acc:.3f} | lr={lr:.5f}")

    return W1, b1, W2, b2


# ============================================================
# 导出 C++ 头文件
# ============================================================

def export_weights(W1, b1, W2, b2, output_path):
    """Export trained weights as C++ header file."""
    IN = W1.shape[1]
    HID = W1.shape[0]
    OUT = W2.shape[0]

    with open(output_path, 'w') as f:
        f.write("/**\n")
        f.write(" * pretrained_weights_v2.h — Auto-generated by distill_scenarios.py\n")
        f.write(f" *\n")
        f.write(f" * MLP architecture: {IN} → {HID} → {OUT}\n")
        f.write(f" * Training data: 72 scenarios × augmented variants\n")
        f.write(" * DO NOT EDIT — regenerate with: python3 tools/distill_scenarios.py\n")
        f.write(" */\n")
        f.write("#pragma once\n\n")
        f.write("#include <cstdint>\n\n")
        f.write("namespace context_engine {\n\n")

        def write_array(name, arr, comment=""):
            flat = arr.flatten()
            if comment:
                f.write(f"// {comment}\n")
            f.write(f"alignas(16) static const float {name}[{len(flat)}] = {{\n")
            for i in range(0, len(flat), 8):
                chunk = flat[i:i+8]
                f.write("    " + ", ".join(f"{v: .6f}f" for v in chunk) + ",\n")
            f.write("};\n\n")

        write_array(f"DISTILLED_W1", W1, f"W1: [{HID} x {IN}]")
        write_array(f"DISTILLED_B1", b1, f"b1: [{HID}]")
        write_array(f"DISTILLED_W2", W2, f"W2: [{OUT} x {HID}]")
        write_array(f"DISTILLED_B2", b2, f"b2: [{OUT}]")

        f.write("} // namespace context_engine\n")

    print(f"\nWeights exported to: {output_path}")
    print(f"  W1: {W1.shape} ({W1.nbytes} bytes)")
    print(f"  b1: {b1.shape} ({b1.nbytes} bytes)")
    print(f"  W2: {W2.shape} ({W2.nbytes} bytes)")
    print(f"  b2: {b2.shape} ({b2.nbytes} bytes)")
    total = W1.nbytes + b1.nbytes + W2.nbytes + b2.nbytes
    print(f"  Total: {total} bytes ({total/1024:.1f} KB)")


# ============================================================
# Main
# ============================================================

def main():
    parser = argparse.ArgumentParser(description='Scenario Distillation Training')
    parser.add_argument('--epochs', type=int, default=300, help='Training epochs')
    parser.add_argument('--lr', type=float, default=0.02, help='Initial learning rate')
    parser.add_argument('--augment', type=int, default=20, help='Augmentation factor per scenario')
    parser.add_argument('--batch-size', type=int, default=32, help='Mini-batch size')
    parser.add_argument('--output', type=str, default=None, help='Output header path')
    parser.add_argument('--seed', type=int, default=42, help='Random seed')
    args = parser.parse_args()

    np.random.seed(args.seed)

    if args.output is None:
        # Default: next to action_recommender.h
        script_dir = os.path.dirname(os.path.abspath(__file__))
        args.output = os.path.join(script_dir, '..',
            'entry/src/main/cpp/context_engine/pretrained_weights_v2.h')

    print(f"=== Scenario Distillation Training ===")
    print(f"Scenarios: {len(SCENARIOS)}")
    print(f"Augmentation factor: {args.augment}")

    # Generate training data
    print("\nGenerating training data...")
    features, targets = generate_training_data(SCENARIOS, augment_factor=args.augment)
    print(f"  Training samples: {len(features)}")
    print(f"  Feature dim: {features.shape[1]}")
    print(f"  Target dim: {targets.shape[1]}")

    # Train
    print(f"\nTraining MLP ({SA_CHAIN_DIM}→{MLP_HID}→{ACT_COUNT})...")
    W1, b1, W2, b2 = train_mlp(
        features, targets,
        hidden=MLP_HID,
        epochs=args.epochs,
        lr=args.lr,
        batch_size=args.batch_size,
        verbose=True,
    )

    # Final evaluation
    h = relu(features @ W1.T + b1)
    pred = softmax(h @ W2.T + b2)
    pred_top = np.argmax(pred, axis=1)
    true_top = np.argmax(targets, axis=1)

    # Top-3 accuracy
    pred_top3 = np.argsort(pred, axis=1)[:, -3:]
    top3_hit = np.array([true_top[i] in pred_top3[i] for i in range(len(true_top))])
    print(f"\nFinal metrics:")
    print(f"  Top-1 accuracy: {np.mean(pred_top == true_top):.3f}")
    print(f"  Top-3 accuracy: {np.mean(top3_hit):.3f}")
    print(f"  Mean cross-entropy: {cross_entropy(pred, targets):.4f}")

    # Per-scenario evaluation
    print(f"\nPer-scenario top-1 accuracy:")
    idx = 0
    scenario_results = []
    for sid, name, key_states, action_dist in SCENARIOS:
        n_samples = 1 + (args.augment // 2) * 2 + max(0, len(key_states) - 1) + args.augment // 4
        batch_pred = pred_top[idx:idx+n_samples]
        batch_true = true_top[idx:idx+n_samples]
        acc = np.mean(batch_pred == batch_true) if len(batch_pred) > 0 else 0
        scenario_results.append((sid, name, acc))
        idx += n_samples

    # Show worst scenarios
    scenario_results.sort(key=lambda x: x[2])
    for sid, name, acc in scenario_results[:5]:
        print(f"  {sid} {name:25s} acc={acc:.3f} {'(!)' if acc < 0.5 else ''}")
    print("  ...")
    for sid, name, acc in scenario_results[-3:]:
        print(f"  {sid} {name:25s} acc={acc:.3f}")

    # Export
    export_weights(W1, b1, W2, b2, args.output)
    print("\nDone!")


if __name__ == '__main__':
    main()
