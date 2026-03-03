# ClawdBot 7元组物理状态推荐矩阵

## 概述

本文档定义了 ClawdBot 在不同物理状态组合下的推荐策略矩阵。
系统通过7个维度描述用户当前物理状态，并据此生成情境感知推荐（Contextual Recommendations）。

**主要维度（构成矩阵行）：** 时间 × 位置 × 运动 × 手机 × 日期  
**修饰维度（调整置信度）：** 光线 × 声音

---

## 维度定义

| 维度 | 枚举值 | 中文说明 |
|------|--------|----------|
| **时间 (time)** | sleeping / dawn / morning / forenoon / lunch / afternoon / evening / night / late_night | 0-5时 / 5-7时 / 7-9时 / 9-12时 / 12-14时 / 14-17时 / 17-20时 / 20-23时 / 23-24时 |
| **位置 (location)** | home / work / commute / restaurant / gym / outdoor / airport / shopping / unknown | 家 / 公司 / 通勤中 / 餐厅 / 健身房 / 户外 / 机场 / 购物 / 未知 |
| **运动 (motion)** | stationary / walking / running / driving | 静止 / 步行 / 跑步 / 驾车 |
| **手机 (phone)** | in_use / holding_lying / on_desk / face_up / in_pocket / face_down / charging / unknown | 手握使用 / 手握躺卧 / 平放桌上 / 平放暗室 / 在口袋 / 屏幕朝下 / 充电中 / 未知 |
| **光线 (light)** | dark / dim / normal / bright | 黑暗 / 昏暗 / 正常 / 明亮 |
| **声音 (sound)** | quiet / normal / noisy / unknown | 安静 / 正常 / 嘈杂 / 未知 |
| **日期 (dayType)** | workday / weekend / holiday | 工作日 / 周末 / 节假日 |

---

## 过滤规则（无效组合）

以下组合物理上不可能或极低概率，系统应直接排除：

| 规则编号 | 条件 | 排除原因 |
|----------|------|----------|
| F1 | motion=running → phone ∉ {on_desk, face_up, face_down, charging, holding_lying} | 跑步时手机不会放桌/充电/躺握 |
| F2 | motion=driving → phone ≠ holding_lying | 驾车不可能躺卧持机 |
| F3 | motion=stationary OR driving → location ≠ gym | 健身房必须有运动 |
| F4 | time=sleeping → motion = stationary | 睡眠时不行走/跑步/驾车 |
| F5 | time=sleeping → light ∈ {dark, dim} | 睡眠时环境应为暗 |
| F6 | time=sleeping → location ∈ {home, unknown} | 睡眠只在家或未知 |
| F7 | time=sleeping → phone ≠ in_use | 睡眠中不主动使用手机 |
| F8 | location=commute → motion ∈ {walking, driving} | 通勤中不静止、不跑步 |
| F9 | location=gym → motion ∈ {walking, running} | 健身房不驾车 |
| F10 | location=airport → motion ∈ {stationary, walking} | 机场不跑步、不驾车 |
| F11 | phone=holding_lying → motion = stationary | 躺卧持机只在静止时 |
| F12 | phone=face_up → motion = stationary | 暗室平放只在静止时 |
| F13 | phone=face_down → motion ∉ {running, walking} | 屏幕朝下时不奔跑/步行 |

**低权重规则（保留但推荐置信度整体降低 15%）：**
- LW1: time=dawn AND location=work → 极少数早班人群
- LW2: time=late_night AND location ≠ home → 深夜外出不常见

---

## 主推荐矩阵

> **置信度说明：** 表示在该情境下，用户确实需要该推荐的概率（0-100%）  
> **光线/声音修饰符** 见文末修饰符表，可进一步调整置信度

---

### 🌙 sleeping（0-5时）

| 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注 |
|------|------|------|------|------|-----------------|-----------------|-----------------|------|
| sleeping | home | stationary | charging | workday | 设置明日闹钟(88%) | 查看明日日程(55%) | 查看天气/穿衣(42%) | 睡前充电插上；工作日闹钟最重要 |
| sleeping | home | stationary | holding_lying | workday | 设置明日闹钟(82%) | 休息提醒(52%) | 查看明日日程(40%) | 半睡半醒状态持机 |
| sleeping | home | stationary | face_up | workday | 设置明日闹钟(78%) | 休息提醒(55%) | 查看明日日程(38%) | 暗室静置，可能辗转难眠 |
| sleeping | home | stationary | charging | weekend | 设置闹钟(58%) | 播放白噪音(45%) | 休息提醒(35%) | 周末睡眠；闹钟优先级降低 |
| sleeping | home | stationary | holding_lying | weekend | 播放白噪音(48%) | 设置闹钟(42%) | 休息提醒(40%) | 周末可能更晚起 |

---

### 🌅 dawn（5-7时）

| 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注 |
|------|------|------|------|------|-----------------|-----------------|-----------------|------|
| dawn | home | stationary | charging | workday | 查看今日日程(90%) | 查看天气/穿衣建议(85%) | 设置出行提醒(68%) | 刚起床充电；核心晨起情境 |
| dawn | home | stationary | in_use | workday | 查看今日日程(92%) | 查看天气/穿衣建议(88%) | 查看新闻摘要(58%) | 主动使用手机；信息需求高 |
| dawn | home | stationary | in_use | weekend | 查看天气(72%) | 查看新闻摘要(62%) | 设置提醒(38%) | 周末早起；放松浏览模式 |
| dawn | home | walking | in_pocket | workday | 查看天气(75%) | 查看步数(62%) | 播放音乐(58%) | 室内早操或晨起活动 |
| dawn | commute | driving | in_pocket | workday | 导航到目的地(82%) | 播放音乐(72%) | 查看今日日程(52%) | 极早班驾车通勤 |
| dawn | commute | walking | in_pocket | workday | 播放音乐(78%) | 查看今日日程(62%) | 查看天气(48%) | 极早班步行通勤 |
| dawn | work | stationary | on_desk | workday | 查看今日日程(61%) | 补水提醒(47%) | 查看天气(30%) | ⚠️LW1降权：极少数早班上班族 |
| dawn | outdoor | walking | in_pocket | weekend | 查看天气(80%) | 查看步数(68%) | 播放音乐(62%) | 周末晨练/晨走 |
| dawn | outdoor | running | in_pocket | weekend | 查看步数(85%) | 补水提醒(78%) | 播放音乐(68%) | 周末晨跑 |
| dawn | gym | walking | in_pocket | workday | 查看步数(82%) | 补水提醒(75%) | 拉伸提醒(60%) | 工作日极早健身 |

---

### 🌄 morning（7-9时）

| 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注 |
|------|------|------|------|------|-----------------|-----------------|-----------------|------|
| morning | home | stationary | charging | workday | 查看今日日程(92%) | 查看天气/穿衣建议(88%) | 设置出行提醒(72%) | 起床准备上班；最核心情境 |
| morning | home | stationary | in_use | workday | 查看今日日程(94%) | 查看天气/穿衣建议(90%) | 查看新闻摘要(62%) | 早晨主动使用手机；高信息需求 |
| morning | home | stationary | on_desk | workday | 查看今日日程(88%) | 查看天气/穿衣建议(82%) | 设置出行提醒(68%) | 手机放桌；可能在吃早饭 |
| morning | home | stationary | in_use | weekend | 查看天气(82%) | 查看新闻摘要(72%) | 设置提醒(48%) | 周末早上；轻松浏览 |
| morning | home | stationary | charging | weekend | 查看天气(78%) | 查看新闻摘要(65%) | 播放音乐(50%) | 周末充电晨起 |
| morning | commute | walking | in_pocket | workday | 播放音乐(88%) | 查看今日日程(74%) | 查看天气(52%) | 步行通勤；手机在口袋 |
| morning | commute | driving | in_pocket | workday | 导航到公司(90%) | 播放音乐(78%) | 查看今日日程(58%) | 驾车上班；导航优先 |
| morning | commute | walking | in_use | workday | 查看今日日程(82%) | 查看新闻摘要(80%) | 播放音乐(68%) | 步行通勤中主动使用手机 |
| morning | commute | driving | in_use | workday | 导航到公司(85%) | 播放音乐(72%) | 停车位记录(55%) | ⚠️驾车使用手机，降低非导航推荐 |
| morning | work | stationary | on_desk | workday | 查看今日日程(94%) | 补水提醒(58%) | 查看新闻摘要(48%) | 到公司第一件事；日程查看最强 |
| morning | work | stationary | in_use | workday | 查看今日日程(90%) | 联系人提醒(62%) | 补水提醒(52%) | 工作中主动用手机 |
| morning | restaurant | stationary | in_use | workday | 点餐建议(85%) | 查看今日日程(68%) | 联系人提醒(42%) | 公司附近早餐 |
| morning | restaurant | stationary | on_desk | workday | 点餐建议(80%) | 查看今日日程(62%) | 补水提醒(40%) | 早餐手机放桌 |
| morning | outdoor | walking | in_pocket | weekend | 查看天气(84%) | 查看步数(72%) | 播放音乐(70%) | 周末晨走 |
| morning | outdoor | running | in_pocket | weekend | 查看步数(90%) | 补水提醒(82%) | 播放音乐(76%) | 周末晨跑 |
| morning | outdoor | walking | in_pocket | holiday | 查看天气(82%) | 查看步数(70%) | 播放音乐(68%) | 节假日晨走 |
| morning | gym | walking | in_pocket | workday | 查看步数(82%) | 补水提醒(76%) | 拉伸提醒(62%) | 工作日晨练 |
| morning | gym | running | in_pocket | weekend | 查看步数(92%) | 补水提醒(86%) | 播放音乐(74%) | 周末晨跑健身 |
| morning | airport | walking | in_pocket | workday | 检查行程(94%) | 导航到登机口(88%) | 查看天气(58%) | 赶飞机；行程最优先 |
| morning | airport | stationary | in_use | workday | 检查行程(96%) | 联系人提醒(62%) | 播放音乐(52%) | 机场候机，主动使用 |

---

### ☀️ forenoon（9-12时）

| 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注 |
|------|------|------|------|------|-----------------|-----------------|-----------------|------|
| forenoon | work | stationary | on_desk | workday | 久坐提醒(90%) | 补水提醒(82%) | 查看今日日程(74%) | 上午工作主情境；久坐最重要 |
| forenoon | work | stationary | in_use | workday | 查看今日日程(82%) | 久坐提醒(74%) | 补水提醒(68%) | 工作时主动使用手机 |
| forenoon | work | stationary | face_down | workday | 久坐提醒(88%) | 补水提醒(80%) | 拉伸提醒(68%) | 屏幕朝下，专注工作中 |
| forenoon | work | stationary | on_desk | weekend | 久坐提醒(78%) | 补水提醒(70%) | 查看天气(48%) | 周末加班 |
| forenoon | home | stationary | on_desk | workday | 久坐提醒(82%) | 补水提醒(70%) | 查看今日日程(62%) | 居家办公；久坐提醒重要 |
| forenoon | home | stationary | in_use | workday | 查看今日日程(78%) | 久坐提醒(68%) | 补水提醒(62%) | 居家办公用手机 |
| forenoon | home | stationary | in_use | weekend | 查看天气(74%) | 查看新闻摘要(68%) | 播放音乐(58%) | 周末居家休闲 |
| forenoon | home | stationary | charging | weekend | 查看天气(70%) | 新闻摘要(62%) | 播放音乐(55%) | 周末充电休闲 |
| forenoon | gym | walking | in_pocket | workday | 查看步数(90%) | 补水提醒(84%) | 拉伸提醒(68%) | 工作日健身 |
| forenoon | gym | running | in_pocket | weekend | 查看步数(94%) | 补水提醒(90%) | 播放音乐(74%) | 周末跑步健身 |
| forenoon | gym | walking | in_pocket | holiday | 查看步数(88%) | 补水提醒(82%) | 拉伸提醒(65%) | 节假日健身 |
| forenoon | outdoor | walking | in_pocket | weekend | 查看步数(84%) | 查看天气(70%) | 播放音乐(65%) | 周末户外散步 |
| forenoon | outdoor | running | in_pocket | weekend | 查看步数(92%) | 补水提醒(88%) | 播放音乐(72%) | 周末户外跑步 |
| forenoon | outdoor | walking | in_pocket | holiday | 查看步数(82%) | 查看天气(68%) | 导航(58%) | 节假日户外游览 |
| forenoon | shopping | walking | in_pocket | weekend | 导航到店铺(70%) | 查看步数(58%) | 补水提醒(48%) | 周末购物 |
| forenoon | shopping | walking | in_pocket | holiday | 导航到店铺(74%) | 查看步数(60%) | 补水提醒(50%) | 节假日购物 |
| forenoon | restaurant | stationary | in_use | workday | 点餐建议(88%) | 联系人提醒(52%) | 查看日程(48%) | 早会后或早餐时段 |
| forenoon | commute | walking | in_pocket | workday | 播放音乐(74%) | 查看日程(62%) | 查看步数(52%) | 迟到的步行通勤 |
| forenoon | airport | walking | in_pocket | workday | 检查行程(92%) | 导航到登机口(82%) | 补水提醒(58%) | 上午航班候机 |
| forenoon | airport | stationary | in_use | workday | 检查行程(92%) | 播放音乐(64%) | 联系人提醒(58%) | 机场等候区 |
| forenoon | unknown | stationary | on_desk | workday | 久坐提醒(78%) | 补水提醒(70%) | 查看日程(62%) | 位置未知，可能在工作 |
| forenoon | unknown | walking | in_pocket | weekend | 查看步数(74%) | 查看天气(62%) | 播放音乐(60%) | 周末外出活动 |

---

### 🍱 lunch（12-14时）

| 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注 |
|------|------|------|------|------|-----------------|-----------------|-----------------|------|
| lunch | restaurant | stationary | in_use | workday | 点餐建议(94%) | 联系人提醒(60%) | 查看下午日程(52%) | 午餐就餐；点餐最强信号 |
| lunch | restaurant | stationary | on_desk | workday | 点餐建议(90%) | 休息提醒(65%) | 查看下午日程(50%) | 手机放桌吃饭 |
| lunch | restaurant | stationary | in_use | weekend | 点餐建议(88%) | 联系人提醒(68%) | 导航(48%) | 周末外出午餐 |
| lunch | restaurant | stationary | in_use | holiday | 点餐建议(86%) | 联系人提醒(72%) | 导航(52%) | 节假日午餐聚会 |
| lunch | work | stationary | in_use | workday | 点餐建议(80%) | 休息提醒(72%) | 查看下午日程(68%) | 公司订外卖/看菜单 |
| lunch | work | stationary | on_desk | workday | 久坐提醒(74%) | 休息提醒(70%) | 查看下午日程(62%) | 公司午休 |
| lunch | work | stationary | face_down | workday | 休息提醒(78%) | 补水提醒(65%) | 查看下午日程(58%) | 公司午休关屏 |
| lunch | home | stationary | in_use | workday | 查看下午日程(74%) | 点餐建议(68%) | 休息提醒(60%) | 居家午餐 |
| lunch | home | stationary | in_use | weekend | 查看天气(70%) | 点餐建议(62%) | 新闻摘要(58%) | 周末午餐在家 |
| lunch | home | stationary | holding_lying | weekend | 播放音乐(65%) | 休息提醒(58%) | 查看天气(45%) | 周末午休躺着 |
| lunch | outdoor | walking | in_pocket | workday | 导航到餐厅(78%) | 查看步数(60%) | 查看天气(48%) | 外出觅食途中 |
| lunch | outdoor | walking | in_pocket | weekend | 导航到餐厅(74%) | 查看步数(62%) | 查看天气(52%) | 周末外出找餐厅 |
| lunch | shopping | walking | in_pocket | weekend | 导航到餐厅(72%) | 查看步数(60%) | 补水提醒(50%) | 购物中场找餐厅 |
| lunch | commute | driving | in_pocket | workday | 导航到餐厅(82%) | 停车位记录(65%) | 播放音乐(50%) | 驾车外出午餐 |
| lunch | gym | walking | in_pocket | workday | 查看步数(85%) | 补水提醒(80%) | 点餐建议(48%) | 午间健身 |

---

### 🌤 afternoon（14-17时）

| 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注 |
|------|------|------|------|------|-----------------|-----------------|-----------------|------|
| afternoon | work | stationary | on_desk | workday | 久坐提醒(94%) | 补水提醒(84%) | 查看今日日程(74%) | 下午工作高峰；久坐最核心 |
| afternoon | work | stationary | in_use | workday | 查看今日日程(82%) | 久坐提醒(76%) | 补水提醒(70%) | 工作时用手机 |
| afternoon | work | stationary | face_down | workday | 久坐提醒(90%) | 补水提醒(80%) | 拉伸提醒(68%) | 屏幕朝下专注工作 |
| afternoon | work | stationary | on_desk | weekend | 久坐提醒(80%) | 补水提醒(72%) | 查看天气(50%) | 周末加班 |
| afternoon | home | stationary | on_desk | workday | 久坐提醒(88%) | 补水提醒(74%) | 查看日程(62%) | 居家办公下午 |
| afternoon | home | stationary | in_use | weekend | 查看天气(70%) | 查看步数(60%) | 新闻摘要(58%) | 周末下午居家 |
| afternoon | home | stationary | holding_lying | weekend | 拉伸提醒(72%) | 设置提醒(58%) | 播放音乐(52%) | 周末午休后躺着 |
| afternoon | home | stationary | charging | workday | 久坐提醒(82%) | 补水提醒(70%) | 查看日程(60%) | 居家办公充电 |
| afternoon | gym | running | in_pocket | workday | 查看步数(92%) | 补水提醒(90%) | 播放音乐(78%) | 工作日下午跑步 |
| afternoon | gym | walking | in_pocket | workday | 查看步数(88%) | 补水提醒(84%) | 拉伸提醒(70%) | 工作日下午健身 |
| afternoon | gym | running | in_pocket | weekend | 查看步数(94%) | 补水提醒(90%) | 播放音乐(80%) | 周末下午跑步 |
| afternoon | gym | walking | in_pocket | holiday | 查看步数(88%) | 补水提醒(82%) | 拉伸提醒(68%) | 节假日健身 |
| afternoon | outdoor | walking | in_pocket | workday | 查看步数(80%) | 导航(68%) | 查看天气(58%) | 工作日外出 |
| afternoon | outdoor | walking | in_pocket | weekend | 查看步数(84%) | 查看天气(68%) | 播放音乐(62%) | 周末下午散步 |
| afternoon | outdoor | running | in_pocket | weekend | 查看步数(90%) | 补水提醒(86%) | 播放音乐(74%) | 周末下午跑步 |
| afternoon | outdoor | walking | in_pocket | holiday | 查看步数(82%) | 导航(70%) | 查看天气(65%) | 节假日户外游览 |
| afternoon | shopping | walking | in_pocket | weekend | 导航到店铺(72%) | 查看步数(60%) | 补水提醒(50%) | 周末购物 |
| afternoon | shopping | walking | in_pocket | holiday | 导航到店铺(76%) | 查看步数(62%) | 补水提醒(54%) | 节假日购物 |
| afternoon | commute | driving | in_pocket | workday | 导航到目的地(90%) | 播放音乐(74%) | 停车位记录(64%) | 驾车外出办事 |
| afternoon | commute | walking | in_pocket | workday | 播放音乐(78%) | 查看步数(68%) | 导航(60%) | 步行通勤/外出 |
| afternoon | airport | walking | in_pocket | workday | 检查行程(92%) | 导航到登机口(84%) | 补水提醒(60%) | 下午航班候机 |
| afternoon | airport | stationary | in_use | workday | 检查行程(90%) | 播放音乐(68%) | 查看新闻摘要(58%) | 机场等候区 |
| afternoon | airport | walking | in_pocket | holiday | 检查行程(90%) | 导航到登机口(82%) | 联系人提醒(60%) | 节假日出行 |
| afternoon | restaurant | stationary | in_use | weekend | 点餐建议(84%) | 联系人提醒(64%) | 导航(48%) | 周末下午茶/餐 |
| afternoon | unknown | stationary | on_desk | workday | 久坐提醒(80%) | 补水提醒(72%) | 查看日程(64%) | 位置未知，工作时间 |
| afternoon | unknown | walking | in_pocket | weekend | 查看步数(72%) | 查看天气(62%) | 播放音乐(58%) | 周末外出活动 |

---

### 🌆 evening（17-20时）

| 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注 |
|------|------|------|------|------|-----------------|-----------------|-----------------|------|
| evening | commute | driving | in_pocket | workday | 导航回家(94%) | 播放音乐(80%) | 停车位记录(68%) | 驾车下班回家；最典型通勤 |
| evening | commute | walking | in_pocket | workday | 播放音乐(84%) | 查看步数(70%) | 查看新闻摘要(60%) | 步行下班 |
| evening | commute | driving | charging | workday | 导航回家(90%) | 播放音乐(74%) | 停车位记录(62%) | 驾车充电 |
| evening | home | stationary | in_use | workday | 查看今日日程(74%) | 查看新闻摘要(70%) | 拉伸提醒(60%) | 下班回家 |
| evening | home | stationary | charging | workday | 拉伸提醒(74%) | 查看新闻摘要(68%) | 查看明日日程(62%) | 回家充电放松 |
| evening | home | stationary | in_use | weekend | 查看天气(70%) | 播放音乐(64%) | 查看新闻摘要(60%) | 周末傍晚居家 |
| evening | home | stationary | holding_lying | weekend | 播放音乐(68%) | 拉伸提醒(58%) | 查看新闻摘要(50%) | 周末晚上躺着休息 |
| evening | home | stationary | in_use | holiday | 查看天气(68%) | 播放音乐(62%) | 查看新闻摘要(58%) | 节假日傍晚居家 |
| evening | restaurant | stationary | in_use | workday | 点餐建议(90%) | 联系人提醒(64%) | 查看步数(48%) | 下班晚餐 |
| evening | restaurant | stationary | on_desk | workday | 点餐建议(86%) | 休息提醒(60%) | 查看步数(45%) | 下班晚餐手机放桌 |
| evening | restaurant | stationary | in_use | weekend | 点餐建议(88%) | 联系人提醒(70%) | 导航回家(50%) | 周末晚餐 |
| evening | restaurant | stationary | in_use | holiday | 点餐建议(84%) | 联系人提醒(74%) | 查看步数(52%) | 节假日晚餐 |
| evening | gym | running | in_pocket | workday | 查看步数(92%) | 补水提醒(88%) | 播放音乐(80%) | 下班后健身跑步 |
| evening | gym | walking | in_pocket | workday | 查看步数(88%) | 补水提醒(84%) | 拉伸提醒(70%) | 下班后健身 |
| evening | gym | running | in_pocket | weekend | 查看步数(90%) | 补水提醒(86%) | 播放音乐(76%) | 周末傍晚跑步 |
| evening | outdoor | walking | in_pocket | workday | 查看步数(80%) | 播放音乐(68%) | 查看天气(58%) | 工作日傍晚散步 |
| evening | outdoor | walking | in_pocket | weekend | 查看步数(84%) | 播放音乐(72%) | 查看天气(60%) | 周末傍晚散步 |
| evening | outdoor | walking | in_pocket | holiday | 查看步数(82%) | 播放音乐(74%) | 导航(58%) | 节假日傍晚外出 |
| evening | work | stationary | on_desk | workday | 查看今日日程(80%) | 久坐提醒(72%) | 下班提醒(68%) | 加班；下班提醒有价值 |
| evening | work | stationary | in_use | workday | 查看今日日程(74%) | 联系人提醒(60%) | 下班提醒(58%) | 加班中用手机 |
| evening | shopping | walking | in_pocket | weekend | 导航到店铺(72%) | 查看步数(62%) | 补水提醒(52%) | 周末傍晚购物 |
| evening | shopping | walking | in_pocket | holiday | 导航到店铺(76%) | 查看步数(64%) | 补水提醒(54%) | 节假日购物 |
| evening | airport | walking | in_pocket | workday | 检查行程(92%) | 导航到登机口(84%) | 联系人提醒(62%) | 傍晚航班 |
| evening | airport | stationary | in_use | workday | 检查行程(90%) | 播放音乐(68%) | 联系人提醒(60%) | 傍晚机场候机 |
| evening | unknown | driving | in_pocket | workday | 导航(86%) | 播放音乐(72%) | 停车位记录(60%) | 晚高峰驾车 |
| evening | unknown | walking | in_pocket | workday | 播放音乐(78%) | 查看步数(68%) | 导航(60%) | 下班途中未知位置 |

---

### 🌙 night（20-23时）

| 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注 |
|------|------|------|------|------|-----------------|-----------------|-----------------|------|
| night | home | stationary | in_use | workday | 设置明日闹钟(88%) | 查看明日日程(80%) | 拉伸提醒(62%) | 工作日夜间；准备明天 |
| night | home | stationary | holding_lying | workday | 设置明日闹钟(90%) | 查看明日日程(74%) | 休息提醒(68%) | 工作日晚躺着看手机 |
| night | home | stationary | charging | workday | 设置明日闹钟(86%) | 查看明日日程(72%) | 拉伸提醒(60%) | 工作日晚充电 |
| night | home | stationary | face_up | workday | 设置明日闹钟(85%) | 休息提醒(72%) | 查看明日日程(65%) | 暗室静置，可能准备入睡 |
| night | home | stationary | in_use | weekend | 播放音乐(72%) | 查看步数(64%) | 查看新闻摘要(60%) | 周末夜间娱乐 |
| night | home | stationary | holding_lying | weekend | 播放音乐(70%) | 查看新闻摘要(62%) | 设置闹钟(52%) | 周末晚躺着放松 |
| night | home | stationary | charging | weekend | 播放音乐(65%) | 新闻摘要(58%) | 设置闹钟(50%) | 周末夜间充电 |
| night | home | stationary | in_use | holiday | 播放音乐(70%) | 查看步数(60%) | 查看新闻摘要(58%) | 节假日夜间娱乐 |
| night | restaurant | stationary | in_use | weekend | 点餐建议(84%) | 联系人提醒(70%) | 导航回家(55%) | 周末宵夜 |
| night | restaurant | stationary | in_use | holiday | 点餐建议(82%) | 联系人提醒(74%) | 导航回家(58%) | 节假日宵夜聚会 |
| night | gym | running | in_pocket | workday | 查看步数(88%) | 补水提醒(82%) | 播放音乐(74%) | 工作日夜跑 |
| night | gym | walking | in_pocket | weekend | 查看步数(84%) | 补水提醒(80%) | 拉伸提醒(68%) | 周末夜间健身 |
| night | outdoor | walking | in_pocket | weekend | 查看步数(80%) | 播放音乐(70%) | 导航回家(62%) | 周末夜间散步 |
| night | outdoor | walking | in_pocket | holiday | 查看步数(78%) | 播放音乐(72%) | 导航回家(65%) | 节假日夜间户外 |
| night | shopping | walking | in_pocket | weekend | 查看步数(64%) | 导航到店铺(60%) | 补水提醒(45%) | 周末夜间购物 |
| night | commute | driving | in_pocket | workday | 导航回家(88%) | 播放音乐(74%) | 停车位记录(62%) | 加班后驾车回家 |
| night | unknown | stationary | in_use | workday | 设置明日闹钟(80%) | 休息提醒(68%) | 查看明日日程(64%) | 夜间位置未知 |
| night | unknown | walking | in_pocket | weekend | 查看步数(70%) | 导航回家(65%) | 播放音乐(58%) | 周末夜间外出 |

---

### 🕛 late_night（23-24时）

| 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注 |
|------|------|------|------|------|-----------------|-----------------|-----------------|------|
| late_night | home | stationary | holding_lying | workday | 设置明日闹钟(94%) | 休息提醒(88%) | 查看明日日程(72%) | 深夜工作日；睡眠准备最重要 |
| late_night | home | stationary | in_use | workday | 设置明日闹钟(92%) | 休息提醒(85%) | 查看明日日程(70%) | 深夜还在用手机 |
| late_night | home | stationary | charging | workday | 设置明日闹钟(90%) | 休息提醒(78%) | 查看明日日程(65%) | 充电准备睡觉 |
| late_night | home | stationary | face_up | workday | 设置明日闹钟(88%) | 休息提醒(82%) | 查看明日日程(60%) | 暗室静置，即将入睡 |
| late_night | home | stationary | holding_lying | weekend | 播放音乐(68%) | 休息提醒(72%) | 设置闹钟(65%) | 周末深夜躺着 |
| late_night | home | stationary | in_use | weekend | 休息提醒(75%) | 设置闹钟(68%) | 播放音乐(60%) | 周末深夜刷手机 |
| late_night | home | stationary | charging | weekend | 休息提醒(70%) | 设置闹钟(65%) | 播放白噪音(52%) | 周末深夜充电 |
| late_night | unknown | stationary | in_use | workday | 休息提醒(85%) | 设置闹钟(80%) | 查看明日日程(60%) | ⚠️LW2降权；深夜位置未知 |
| late_night | outdoor | walking | in_pocket | weekend | 导航回家(80%) | 查看步数(62%) | 播放音乐(55%) | 深夜外出步行 |

---

## 光线/声音修饰符表

### 光线修饰符（light）

| 光线值 | 典型场景 | 推荐调整策略 |
|--------|----------|-------------|
| **dark（黑暗）** | 深夜关灯、睡前、暗室 | ① 加入"屏幕亮度降低提醒"（置信度 70%）② 睡眠类推荐（设置闹钟/休息提醒）置信度 +10% ③ 阅读/浏览类推荐（新闻）置信度 −15%（护眼） |
| **dim（昏暗）** | 傍晚室内、昏暗餐厅、卧室台灯 | ① 推荐整体小幅调整 ② 若 time∈{night, late_night}，睡眠类推荐 +5% ③ 阅读类推荐 −8% |
| **normal（正常）** | 日间室内、有照明办公室 | 基准状态，不调整 |
| **bright（明亮）** | 户外晴天、明亮商场、阳光直射 | ① 若 location=outdoor，步数/天气推荐 +8% ② 屏幕亮度相关提醒降优先级 ③ 户外导航推荐 +5% |

### 声音修饰符（sound）

| 声音值 | 典型场景 | 推荐调整策略 |
|--------|----------|-------------|
| **quiet（安静）** | 深夜居家、图书馆、专注工作 | ① 播放音乐推荐置信度 −20%（已够安静） ② 若 time∈{night, sleeping}，休息/睡眠提醒 +10% ③ 语音类功能建议切换为静音/文字模式 |
| **normal（正常）** | 普通室内、一般环境 | 基准状态，不调整 |
| **noisy（嘈杂）** | 餐厅嘈杂、健身房、闹市户外 | ① 播放音乐置信度 −15%（噪音环境效果差）② 点餐建议维持最高优先级 ③ 导航推荐切换为纯视觉模式（不语音播报）④ 通话/联系人提醒置信度 −10% |
| **unknown（未知）** | 无麦克风数据 | 不调整，使用基础推荐 |

### 组合修饰示例

| 典型场景 | 光线 | 声音 | 组合调整效果 |
|----------|------|------|-------------|
| 深夜床上刷手机 | dark | quiet | 休息提醒 +20%；播放音乐 −20%；加入屏幕亮度提醒 |
| 健身房跑步 | normal | noisy | 播放音乐 −15%；补水提醒维持；导航切视觉模式 |
| 夜间驾车回家 | dim | normal | 导航维持最高优先；睡眠类提醒 +5% |
| 户外晴天散步 | bright | normal | 步数/天气推荐 +8%；户外导航 +5% |
| 嘈杂餐厅就餐 | normal | noisy | 点餐建议维持最高；联系人提醒 −10% |
| 昏暗餐厅夜间 | dim | noisy | 阅读类 −8%；点餐建议维持；联系人提醒 −10% |
| 明亮户外运动 | bright | normal | 步数推荐 +8%；补水提醒维持 |

---

## 使用方法

### 查询流程

```
1. 获取用户当前7元组: (time, location, motion, phone, light, sound, dayType)
2. 检查过滤规则 F1-F13，命中则标记为无效组合（跳过）
3. 检查低权重规则 LW1-LW2，命中则整体置信度 −15%
4. 在主矩阵中按 (time, location, motion, phone, dayType) 查找匹配行
5. 获取基础推荐列表和置信度
6. 应用 light 修饰符调整置信度
7. 应用 sound 修饰符调整置信度
8. 按最终置信度降序排列，取前3条作为推荐输出
```

### 模糊匹配降级策略

当找不到精确匹配时，按优先级逐步降级：

| 级别 | 匹配维度 | 说明 |
|------|----------|------|
| L1（精确） | time + location + motion + phone + dayType | 完全精确匹配 |
| L2 | time + location + motion + phone | 忽略日期类型 |
| L3 | time + location + motion | 忽略手机状态 |
| L4（兜底） | time + location | 仅时间+位置粗匹配 |

### 置信度阈值

| 置信度范围 | 行为策略 |
|-----------|----------|
| **≥75%** | 主动推送（无需用户询问，直接弹出卡片） |
| **50-74%** | 候选推荐（显示在推荐列表，等待用户选择） |
| **25-49%** | 低优先级（仅在用户主动询问时展示） |
| **<25%** | 不推荐（置信度过低，跳过） |

---

## 版本信息

| 字段 | 值 |
|------|----|
| 文档版本 | v1.0 |
| 创建日期 | 2026-03-03 |
| 矩阵规模 | ~175 行（覆盖所有 time×location 核心组合） |
| 推荐动作库 | 15+ 种可执行动作 |
| 维护方式 | 根据用户行为数据定期更新置信度 |
