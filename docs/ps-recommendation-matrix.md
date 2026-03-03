# ClawdBot 7元组物理状态推荐矩阵

## 概述

本文档定义了 ClawdBot 在不同物理状态组合下的推荐策略矩阵。
系统通过7个维度描述用户当前物理状态，并据此生成情境感知推荐（Contextual Recommendations）。

**主要维度（构成矩阵行）：** 时间 × 位置 × 运动 × 手机 × 日期  
**修饰维度（调整置信度）：** 光线 × 声音


---

## 状态编码（StateCode）

每个7元组状态可编码为一个 **7位字符串**，格式为：

```
[T][L][M][P][Li][S][D]
```

| 位 | 维度 | 含义 | 编码表 |
|----|------|------|--------|
| T | 时间 | time | 1=sleeping 2=dawn 3=morning 4=forenoon 5=lunch 6=afternoon 7=evening 8=night 9=late_night |
| L | 位置 | location | **0**=未知; **1-9**: 1=家 2=公司 3=通勤 4=餐厅 5=健身房 6=户外 7=机场 8=购物 9=地铁站; **A-Z**: A=公交站 B=轮渡 C=火车站 D=咖啡馆 E=电影院 F=公园 G-Z=扩展预留 |
| M | 运动 | motion | 1=stationary 2=walking 3=running 4=driving |
| P | 手机 | phone | 1=in_use 2=holding_lying 3=on_desk 4=face_up 5=in_pocket 6=face_down 7=charging 8=unknown |
| Li | 光线 | light | 0=未指定 1=dark 2=dim 3=normal 4=bright |
| S | 声音 | sound | 0=未指定 1=quiet 2=normal 3=noisy 4=unknown |
| D | 日期 | dayType | 1=workday 2=weekend 3=holiday |

> **0 = 未指定**（该维度未检测或不适用）

### 编码示例

| StateCode | 解读 |
|-----------|------|
| `3D11002` | morning × 咖啡馆(D) × stationary × in_use × 光线未指定 × 声音未指定 × weekend |
| `3D11332` | morning × 咖啡馆(D) × stationary × in_use × normal × noisy × weekend |
| `7111001` | evening × 家(1) × stationary × in_use × 未指定 × 未指定 × workday |
| `4231001` | forenoon × 公司(2) × stationary × on_desk × 未指定 × 未指定 × workday（久坐场景） |
| `3321001` | morning × 通勤(3) × walking × in_use × 未指定 × 未指定 × workday |
| `6531002` | afternoon × 健身房(5) × running × on_desk × 未指定 × 未指定 × weekend |

> 矩阵中每行 Code 格式为 `TLMPLiSD`，光线/声音列未明确列出时用 `0` 占位。

---
---

## 维度定义

| 维度 | 枚举值 | 中文说明 |
|------|--------|----------|
| **时间 (time)** | sleeping / dawn / morning / forenoon / lunch / afternoon / evening / night / late_night | 0-5时 / 5-7时 / 7-9时 / 9-12时 / 12-14时 / 14-17时 / 17-20时 / 20-23时 / 23-24时 |
| **位置 (location)** | home / work / commute / restaurant / gym / outdoor / airport / shopping / subway / bus_stop / ferry / unknown | 家 / 公司 / 通勤中 / 餐厅 / 健身房 / 户外 / 机场 / 购物 / 地铁站 / 公交站 / 轮渡渡口 / 未知 |
| **运动 (motion)** | stationary / walking / running / driving | 静止 / 步行 / 跑步 / 驾车 |
| **手机 (phone)** | in_use / holding_lying / on_desk / face_up / in_pocket / face_down / charging / unknown | 手握使用 / 手握躺卧 / 平放桌上 / 平放暗室 / 在口袋 / 屏幕朝下 / 充电中 / 未知 |
| **光线 (light)** | dark / dim / normal / bright | 黑暗 / 昏暗 / 正常 / 明亮 |
| **声音 (sound)** | quiet / normal / noisy / unknown | 安静 / 正常 / 嘈杂 / 未知 |
| **日期 (dayType)** | workday / weekend / holiday | 工作日 / 周末 / 节假日 |

### 位置分类补充说明

| 位置值 | 中文名 | 典型场景 |
|--------|--------|----------|
| subway | 地铁站 | 乘坐或等候地铁 |
| bus_stop | 公交站 | 等候或乘坐公交 |
| ferry | 轮渡/渡口 | 等候或乘坐轮渡 |

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
| F14 | location ∈ {subway, bus_stop, ferry} → motion ∈ {stationary, walking} | 地铁/公交站/轮渡不驾车、不跑步 |
| F15 | location=subway → sound ≠ quiet | 地铁站环境通常嘈杂，排除 quiet |

**低权重规则（保留但推荐置信度整体降低 15%）：**
- LW1: time=dawn AND location=work → 极少数早班人群
- LW2: time=late_night AND location ≠ home → 深夜外出不常见

**位置特定声音规则（修饰符说明）：**
- subway → sound 通常为 noisy（嘈杂），建议应用 noisy 修饰符
- bus_stop → sound 通常为 normal 或 noisy（户外环境）
- ferry → sound 通常为 normal（船舱相对安静）

---

## 主推荐矩阵

> **置信度说明：** 表示在该情境下，用户确实需要该推荐的概率（0-100%）  
> **光线/声音修饰符** 见文末修饰符表，可进一步调整置信度

---

### 🌙 sleeping（0-5时）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-001 | 工作日睡前充电 | sleeping | home | stationary | charging | workday | 设置明日闹钟(88%) | 查看明日日程(55%) | 查看天气/穿衣(42%) | 睡前充电插上；工作日闹钟最重要 | (Code: `1117001`)
| PS-002 | 工作日半睡持机 | sleeping | home | stationary | holding_lying | workday | 设置明日闹钟(82%) | 休息提醒(52%) | 查看明日日程(40%) | 半睡半醒状态持机 | (Code: `1112001`)
| PS-003 | 工作日暗室静置 | sleeping | home | stationary | face_up | workday | 设置明日闹钟(78%) | 休息提醒(55%) | 查看明日日程(38%) | 暗室静置，可能辗转难眠 | (Code: `1114001`)
| PS-004 | 周末睡前充电 | sleeping | home | stationary | charging | weekend | 设置闹钟(58%) | 播放白噪音(45%) | 休息提醒(35%) | 周末睡眠；闹钟优先级降低 | (Code: `1117002`)
| PS-005 | 周末半睡躺机 | sleeping | home | stationary | holding_lying | weekend | 播放白噪音(48%) | 设置闹钟(42%) | 休息提醒(40%) | 周末可能更晚起 | (Code: `1112002`)

---

### 🌅 dawn（5-7时）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-006 | 工作日晨起充电 | dawn | home | stationary | charging | workday | 查看今日日程(90%) | 查看天气/穿衣建议(85%) | 设置出行提醒(68%) | 刚起床充电；核心晨起情境 | (Code: `2117001`)
| PS-007 | 工作日晨起用机 | dawn | home | stationary | in_use | workday | 查看今日日程(92%) | 查看天气/穿衣建议(88%) | 查看新闻摘要(58%) | 主动使用手机；信息需求高 | (Code: `2111001`)
| PS-008 | 周末晨起用机 | dawn | home | stationary | in_use | weekend | 查看天气(72%) | 查看新闻摘要(62%) | 设置提醒(38%) | 周末早起；放松浏览模式 | (Code: `2111002`)
| PS-009 | 工作日晨起散步 | dawn | home | walking | in_pocket | workday | 查看天气(75%) | 查看步数(62%) | 播放音乐(58%) | 室内早操或晨起活动 | (Code: `2125001`)
| PS-010 | 极早班驾车通勤 | dawn | commute | driving | in_pocket | workday | 导航到目的地(82%) | 播放音乐(72%) | 查看今日日程(52%) | 极早班驾车通勤 | (Code: `2345001`)
| PS-011 | 极早班步行通勤 | dawn | commute | walking | in_pocket | workday | 播放音乐(78%) | 查看今日日程(62%) | 查看天气(48%) | 极早班步行通勤 | (Code: `2325001`)
| PS-012 | 极早班在办公室 | dawn | work | stationary | on_desk | workday | 查看今日日程(61%) | 补水提醒(47%) | 查看天气(30%) | ⚠️LW1降权：极少数早班上班族 | (Code: `2213001`)
| PS-013 | 周末清晨户外走 | dawn | outdoor | walking | in_pocket | weekend | 查看天气(80%) | 查看步数(68%) | 播放音乐(62%) | 周末晨练/晨走 | (Code: `2625002`)
| PS-014 | 周末清晨晨跑 | dawn | outdoor | running | in_pocket | weekend | 查看步数(85%) | 补水提醒(78%) | 播放音乐(68%) | 周末晨跑 | (Code: `2635002`)
| PS-015 | 工作日极早健身 | dawn | gym | walking | in_pocket | workday | 查看步数(82%) | 补水提醒(75%) | 拉伸提醒(60%) | 工作日极早健身 | (Code: `2525001`)

---

### 🌄 morning（7-9时）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-016 | 工作日晨起充电 | morning | home | stationary | charging | workday | 查看今日日程(92%) | 查看天气/穿衣建议(88%) | 设置出行提醒(72%) | 起床准备上班；最核心情境 | (Code: `3117001`)
| PS-017 | 工作日晨起用机 | morning | home | stationary | in_use | workday | 查看今日日程(94%) | 查看天气/穿衣建议(90%) | 查看新闻摘要(62%) | 早晨主动使用手机；高信息需求 | (Code: `3111001`)
| PS-018 | 工作日早饭手机 | morning | home | stationary | on_desk | workday | 查看今日日程(88%) | 查看天气/穿衣建议(82%) | 设置出行提醒(68%) | 手机放桌；可能在吃早饭 | (Code: `3113001`)
| PS-019 | 周末早晨用机 | morning | home | stationary | in_use | weekend | 查看天气(82%) | 查看新闻摘要(72%) | 设置提醒(48%) | 周末早上；轻松浏览 | (Code: `3111002`)
| PS-020 | 周末早晨充电 | morning | home | stationary | charging | weekend | 查看天气(78%) | 查看新闻摘要(65%) | 播放音乐(50%) | 周末充电晨起 | (Code: `3117002`)
| PS-021 | 步行上班口袋 | morning | commute | walking | in_pocket | workday | 播放音乐(88%) | 查看今日日程(74%) | 查看天气(52%) | 步行通勤；手机在口袋 | (Code: `3325001`)
| PS-022 | 驾车上班口袋 | morning | commute | driving | in_pocket | workday | 导航到公司(90%) | 播放音乐(78%) | 查看今日日程(58%) | 驾车上班；导航优先 | (Code: `3345001`)
| PS-023 | 步行通勤用机 | morning | commute | walking | in_use | workday | 查看今日日程(82%) | 查看新闻摘要(80%) | 播放音乐(68%) | 步行通勤中主动使用手机 | (Code: `3321001`)
| PS-024 | 驾车上班用机 | morning | commute | driving | in_use | workday | 导航到公司(85%) | 播放音乐(72%) | 停车位记录(55%) | ⚠️驾车使用手机，降低非导航推荐 | (Code: `3341001`)
| PS-025 | 到公司看日程 | morning | work | stationary | on_desk | workday | 查看今日日程(94%) | 补水提醒(58%) | 查看新闻摘要(48%) | 到公司第一件事；日程查看最强 | (Code: `3213001`)
| PS-026 | 工作中用手机 | morning | work | stationary | in_use | workday | 查看今日日程(90%) | 联系人提醒(62%) | 补水提醒(52%) | 工作中主动用手机 | (Code: `3211001`)
| PS-027 | 工作日早餐用机 | morning | restaurant | stationary | in_use | workday | 点餐建议(85%) | 查看今日日程(68%) | 联系人提醒(42%) | 公司附近早餐 | (Code: `3411001`)
| PS-028 | 工作日早餐放桌 | morning | restaurant | stationary | on_desk | workday | 点餐建议(80%) | 查看今日日程(62%) | 补水提醒(40%) | 早餐手机放桌 | (Code: `3413001`)
| PS-029 | 周末晨走户外 | morning | outdoor | walking | in_pocket | weekend | 查看天气(84%) | 查看步数(72%) | 播放音乐(70%) | 周末晨走 | (Code: `3625002`)
| PS-030 | 周末晨跑户外 | morning | outdoor | running | in_pocket | weekend | 查看步数(90%) | 补水提醒(82%) | 播放音乐(76%) | 周末晨跑 | (Code: `3635002`)
| PS-031 | 节假日晨走 | morning | outdoor | walking | in_pocket | holiday | 查看天气(82%) | 查看步数(70%) | 播放音乐(68%) | 节假日晨走 | (Code: `3625003`)
| PS-032 | 工作日晨练 | morning | gym | walking | in_pocket | workday | 查看步数(82%) | 补水提醒(76%) | 拉伸提醒(62%) | 工作日晨练 | (Code: `3525001`)
| PS-033 | 周末晨跑健身 | morning | gym | running | in_pocket | weekend | 查看步数(92%) | 补水提醒(86%) | 播放音乐(74%) | 周末晨跑健身 | (Code: `3535002`)
| PS-034 | 赶飞机步行 | morning | airport | walking | in_pocket | workday | 检查行程(94%) | 导航到登机口(88%) | 查看天气(58%) | 赶飞机；行程最优先 | (Code: `3725001`)
| PS-035 | 机场候机用机 | morning | airport | stationary | in_use | workday | 检查行程(96%) | 联系人提醒(62%) | 播放音乐(52%) | 机场候机，主动使用 | (Code: `3711001`)

---

### ☀️ forenoon（9-12时）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-036 | 工作日上午办公 | forenoon | work | stationary | on_desk | workday | 久坐提醒(90%) | 补水提醒(82%) | 查看今日日程(74%) | 上午工作主情境；久坐最重要 | (Code: `4213001`)
| PS-037 | 上午工作用机 | forenoon | work | stationary | in_use | workday | 查看今日日程(82%) | 久坐提醒(74%) | 补水提醒(68%) | 工作时主动使用手机 | (Code: `4211001`)
| PS-038 | 上午专注关屏 | forenoon | work | stationary | face_down | workday | 久坐提醒(88%) | 补水提醒(80%) | 拉伸提醒(68%) | 屏幕朝下，专注工作中 | (Code: `4216001`)
| PS-039 | 周末加班办公 | forenoon | work | stationary | on_desk | weekend | 久坐提醒(78%) | 补水提醒(70%) | 查看天气(48%) | 周末加班 | (Code: `4213002`)
| PS-040 | 居家办公上午 | forenoon | home | stationary | on_desk | workday | 久坐提醒(82%) | 补水提醒(70%) | 查看今日日程(62%) | 居家办公；久坐提醒重要 | (Code: `4113001`)
| PS-041 | 居家办公用机 | forenoon | home | stationary | in_use | workday | 查看今日日程(78%) | 久坐提醒(68%) | 补水提醒(62%) | 居家办公用手机 | (Code: `4111001`)
| PS-042 | 周末居家休闲 | forenoon | home | stationary | in_use | weekend | 查看天气(74%) | 查看新闻摘要(68%) | 播放音乐(58%) | 周末居家休闲 | (Code: `4111002`)
| PS-043 | 周末居家充电 | forenoon | home | stationary | charging | weekend | 查看天气(70%) | 新闻摘要(62%) | 播放音乐(55%) | 周末充电休闲 | (Code: `4117002`)
| PS-044 | 工作日上午健身 | forenoon | gym | walking | in_pocket | workday | 查看步数(90%) | 补水提醒(84%) | 拉伸提醒(68%) | 工作日健身 | (Code: `4525001`)
| PS-045 | 周末跑步健身 | forenoon | gym | running | in_pocket | weekend | 查看步数(94%) | 补水提醒(90%) | 播放音乐(74%) | 周末跑步健身 | (Code: `4535002`)
| PS-046 | 节假日健身 | forenoon | gym | walking | in_pocket | holiday | 查看步数(88%) | 补水提醒(82%) | 拉伸提醒(65%) | 节假日健身 | (Code: `4525003`)
| PS-047 | 周末户外散步 | forenoon | outdoor | walking | in_pocket | weekend | 查看步数(84%) | 查看天气(70%) | 播放音乐(65%) | 周末户外散步 | (Code: `4625002`)
| PS-048 | 周末户外跑步 | forenoon | outdoor | running | in_pocket | weekend | 查看步数(92%) | 补水提醒(88%) | 播放音乐(72%) | 周末户外跑步 | (Code: `4635002`)
| PS-049 | 节假日户外游 | forenoon | outdoor | walking | in_pocket | holiday | 查看步数(82%) | 查看天气(68%) | 导航(58%) | 节假日户外游览 | (Code: `4625003`)
| PS-050 | 周末购物逛街 | forenoon | shopping | walking | in_pocket | weekend | 导航到店铺(70%) | 查看步数(58%) | 补水提醒(48%) | 周末购物 | (Code: `4825002`)
| PS-051 | 节假日购物 | forenoon | shopping | walking | in_pocket | holiday | 导航到店铺(74%) | 查看步数(60%) | 补水提醒(50%) | 节假日购物 | (Code: `4825003`)
| PS-052 | 上午餐厅用机 | forenoon | restaurant | stationary | in_use | workday | 点餐建议(88%) | 联系人提醒(52%) | 查看日程(48%) | 早会后或早餐时段 | (Code: `4411001`)
| PS-053 | 迟到步行通勤 | forenoon | commute | walking | in_pocket | workday | 播放音乐(74%) | 查看日程(62%) | 查看步数(52%) | 迟到的步行通勤 | (Code: `4325001`)
| PS-054 | 上午航班候机 | forenoon | airport | walking | in_pocket | workday | 检查行程(92%) | 导航到登机口(82%) | 补水提醒(58%) | 上午航班候机 | (Code: `4725001`)
| PS-055 | 机场等候区 | forenoon | airport | stationary | in_use | workday | 检查行程(92%) | 播放音乐(64%) | 联系人提醒(58%) | 机场等候区 | (Code: `4711001`)
| PS-056 | 位置未知办公 | forenoon | unknown | stationary | on_desk | workday | 久坐提醒(78%) | 补水提醒(70%) | 查看日程(62%) | 位置未知，可能在工作 | (Code: `4013001`)
| PS-057 | 周末外出活动 | forenoon | unknown | walking | in_pocket | weekend | 查看步数(74%) | 查看天气(62%) | 播放音乐(60%) | 周末外出活动 | (Code: `4025002`)

---

### 🍱 lunch（12-14时）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-058 | 工作日餐厅用机 | lunch | restaurant | stationary | in_use | workday | 点餐建议(94%) | 联系人提醒(60%) | 查看下午日程(52%) | 午餐就餐；点餐最强信号 | (Code: `5411001`)
| PS-059 | 工作日午餐放桌 | lunch | restaurant | stationary | on_desk | workday | 点餐建议(90%) | 休息提醒(65%) | 查看下午日程(50%) | 手机放桌吃饭 | (Code: `5413001`)
| PS-060 | 周末外出午餐 | lunch | restaurant | stationary | in_use | weekend | 点餐建议(88%) | 联系人提醒(68%) | 导航(48%) | 周末外出午餐 | (Code: `5411002`)
| PS-061 | 节假日午餐聚 | lunch | restaurant | stationary | in_use | holiday | 点餐建议(86%) | 联系人提醒(72%) | 导航(52%) | 节假日午餐聚会 | (Code: `5411003`)
| PS-062 | 公司订外卖 | lunch | work | stationary | in_use | workday | 点餐建议(80%) | 休息提醒(72%) | 查看下午日程(68%) | 公司订外卖/看菜单 | (Code: `5211001`)
| PS-063 | 公司午休放桌 | lunch | work | stationary | on_desk | workday | 久坐提醒(74%) | 休息提醒(70%) | 查看下午日程(62%) | 公司午休 | (Code: `5213001`)
| PS-064 | 公司午休关屏 | lunch | work | stationary | face_down | workday | 休息提醒(78%) | 补水提醒(65%) | 查看下午日程(58%) | 公司午休关屏 | (Code: `5216001`)
| PS-065 | 居家午餐用机 | lunch | home | stationary | in_use | workday | 查看下午日程(74%) | 点餐建议(68%) | 休息提醒(60%) | 居家午餐 | (Code: `5111001`)
| PS-066 | 周末午餐在家 | lunch | home | stationary | in_use | weekend | 查看天气(70%) | 点餐建议(62%) | 新闻摘要(58%) | 周末午餐在家 | (Code: `5111002`)
| PS-067 | 周末午休躺着 | lunch | home | stationary | holding_lying | weekend | 播放音乐(65%) | 休息提醒(58%) | 查看天气(45%) | 周末午休躺着 | (Code: `5112002`)
| PS-068 | 外出觅食途中 | lunch | outdoor | walking | in_pocket | workday | 导航到餐厅(78%) | 查看步数(60%) | 查看天气(48%) | 外出觅食途中 | (Code: `5625001`)
| PS-069 | 周末外出找餐 | lunch | outdoor | walking | in_pocket | weekend | 导航到餐厅(74%) | 查看步数(62%) | 查看天气(52%) | 周末外出找餐厅 | (Code: `5625002`)
| PS-070 | 购物中场找餐 | lunch | shopping | walking | in_pocket | weekend | 导航到餐厅(72%) | 查看步数(60%) | 补水提醒(50%) | 购物中场找餐厅 | (Code: `5825002`)
| PS-071 | 驾车外出午餐 | lunch | commute | driving | in_pocket | workday | 导航到餐厅(82%) | 停车位记录(65%) | 播放音乐(50%) | 驾车外出午餐 | (Code: `5345001`)
| PS-072 | 午间健身 | lunch | gym | walking | in_pocket | workday | 查看步数(85%) | 补水提醒(80%) | 点餐建议(48%) | 午间健身 | (Code: `5525001`)

---

### 🌤 afternoon（14-17时）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-073 | 下午办公久坐 | afternoon | work | stationary | on_desk | workday | 久坐提醒(94%) | 补水提醒(84%) | 查看今日日程(74%) | 下午工作高峰；久坐最核心 | (Code: `6213001`)
| PS-074 | 下午工作用机 | afternoon | work | stationary | in_use | workday | 查看今日日程(82%) | 久坐提醒(76%) | 补水提醒(70%) | 工作时用手机 | (Code: `6211001`)
| PS-075 | 下午专注关屏 | afternoon | work | stationary | face_down | workday | 久坐提醒(90%) | 补水提醒(80%) | 拉伸提醒(68%) | 屏幕朝下专注工作 | (Code: `6216001`)
| PS-076 | 周末加班下午 | afternoon | work | stationary | on_desk | weekend | 久坐提醒(80%) | 补水提醒(72%) | 查看天气(50%) | 周末加班 | (Code: `6213002`)
| PS-077 | 居家办公下午 | afternoon | home | stationary | on_desk | workday | 久坐提醒(88%) | 补水提醒(74%) | 查看日程(62%) | 居家办公下午 | (Code: `6113001`)
| PS-078 | 周末居家下午 | afternoon | home | stationary | in_use | weekend | 查看天气(70%) | 查看步数(60%) | 新闻摘要(58%) | 周末下午居家 | (Code: `6111002`)
| PS-079 | 周末午后躺机 | afternoon | home | stationary | holding_lying | weekend | 拉伸提醒(72%) | 设置提醒(58%) | 播放音乐(52%) | 周末午休后躺着 | (Code: `6112002`)
| PS-080 | 居家办公充电 | afternoon | home | stationary | charging | workday | 久坐提醒(82%) | 补水提醒(70%) | 查看日程(60%) | 居家办公充电 | (Code: `6117001`)
| PS-081 | 工作日下午跑 | afternoon | gym | running | in_pocket | workday | 查看步数(92%) | 补水提醒(90%) | 播放音乐(78%) | 工作日下午跑步 | (Code: `6535001`)
| PS-082 | 工作日下午练 | afternoon | gym | walking | in_pocket | workday | 查看步数(88%) | 补水提醒(84%) | 拉伸提醒(70%) | 工作日下午健身 | (Code: `6525001`)
| PS-083 | 周末下午跑步 | afternoon | gym | running | in_pocket | weekend | 查看步数(94%) | 补水提醒(90%) | 播放音乐(80%) | 周末下午跑步 | (Code: `6535002`)
| PS-084 | 节假日健身 | afternoon | gym | walking | in_pocket | holiday | 查看步数(88%) | 补水提醒(82%) | 拉伸提醒(68%) | 节假日健身 | (Code: `6525003`)
| PS-085 | 工作日外出 | afternoon | outdoor | walking | in_pocket | workday | 查看步数(80%) | 导航(68%) | 查看天气(58%) | 工作日外出 | (Code: `6625001`)
| PS-086 | 周末下午散步 | afternoon | outdoor | walking | in_pocket | weekend | 查看步数(84%) | 查看天气(68%) | 播放音乐(62%) | 周末下午散步 | (Code: `6625002`)
| PS-087 | 周末下午跑步 | afternoon | outdoor | running | in_pocket | weekend | 查看步数(90%) | 补水提醒(86%) | 播放音乐(74%) | 周末下午跑步 | (Code: `6635002`)
| PS-088 | 节假日户外游 | afternoon | outdoor | walking | in_pocket | holiday | 查看步数(82%) | 导航(70%) | 查看天气(65%) | 节假日户外游览 | (Code: `6625003`)
| PS-089 | 周末购物逛街 | afternoon | shopping | walking | in_pocket | weekend | 导航到店铺(72%) | 查看步数(60%) | 补水提醒(50%) | 周末购物 | (Code: `6825002`)
| PS-090 | 节假日购物 | afternoon | shopping | walking | in_pocket | holiday | 导航到店铺(76%) | 查看步数(62%) | 补水提醒(54%) | 节假日购物 | (Code: `6825003`)
| PS-091 | 下午驾车外出 | afternoon | commute | driving | in_pocket | workday | 导航到目的地(90%) | 播放音乐(74%) | 停车位记录(64%) | 驾车外出办事 | (Code: `6345001`)
| PS-092 | 下午步行通勤 | afternoon | commute | walking | in_pocket | workday | 播放音乐(78%) | 查看步数(68%) | 导航(60%) | 步行通勤/外出 | (Code: `6325001`)
| PS-093 | 下午航班候机 | afternoon | airport | walking | in_pocket | workday | 检查行程(92%) | 导航到登机口(84%) | 补水提醒(60%) | 下午航班候机 | (Code: `6725001`)
| PS-094 | 下午机场等候 | afternoon | airport | stationary | in_use | workday | 检查行程(90%) | 播放音乐(68%) | 查看新闻摘要(58%) | 机场等候区 | (Code: `6711001`)
| PS-095 | 节假日出行 | afternoon | airport | walking | in_pocket | holiday | 检查行程(90%) | 导航到登机口(82%) | 联系人提醒(60%) | 节假日出行 | (Code: `6725003`)
| PS-096 | 周末下午茶餐 | afternoon | restaurant | stationary | in_use | weekend | 点餐建议(84%) | 联系人提醒(64%) | 导航(48%) | 周末下午茶/餐 | (Code: `6411002`)
| PS-097 | 位置未知工作 | afternoon | unknown | stationary | on_desk | workday | 久坐提醒(80%) | 补水提醒(72%) | 查看日程(64%) | 位置未知，工作时间 | (Code: `6013001`)
| PS-098 | 周末外出活动 | afternoon | unknown | walking | in_pocket | weekend | 查看步数(72%) | 查看天气(62%) | 播放音乐(58%) | 周末外出活动 | (Code: `6025002`)

---

### 🌆 evening（17-20时）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-099 | 驾车下班回家 | evening | commute | driving | in_pocket | workday | 导航回家(94%) | 播放音乐(80%) | 停车位记录(68%) | 驾车下班回家；最典型通勤 | (Code: `7345001`)
| PS-100 | 步行下班回家 | evening | commute | walking | in_pocket | workday | 播放音乐(84%) | 查看步数(70%) | 查看新闻摘要(60%) | 步行下班 | (Code: `7325001`)
| PS-101 | 驾车充电通勤 | evening | commute | driving | charging | workday | 导航回家(90%) | 播放音乐(74%) | 停车位记录(62%) | 驾车充电 | (Code: `7347001`)
| PS-102 | 下班回家用机 | evening | home | stationary | in_use | workday | 查看今日日程(74%) | 查看新闻摘要(70%) | 拉伸提醒(60%) | 下班回家 | (Code: `7111001`)
| PS-103 | 回家充电放松 | evening | home | stationary | charging | workday | 拉伸提醒(74%) | 查看新闻摘要(68%) | 查看明日日程(62%) | 回家充电放松 | (Code: `7117001`)
| PS-104 | 周末傍晚居家 | evening | home | stationary | in_use | weekend | 查看天气(70%) | 播放音乐(64%) | 查看新闻摘要(60%) | 周末傍晚居家 | (Code: `7111002`)
| PS-105 | 周末晚躺着机 | evening | home | stationary | holding_lying | weekend | 播放音乐(68%) | 拉伸提醒(58%) | 查看新闻摘要(50%) | 周末晚上躺着休息 | (Code: `7112002`)
| PS-106 | 节假日傍晚家 | evening | home | stationary | in_use | holiday | 查看天气(68%) | 播放音乐(62%) | 查看新闻摘要(58%) | 节假日傍晚居家 | (Code: `7111003`)
| PS-107 | 下班晚餐用机 | evening | restaurant | stationary | in_use | workday | 点餐建议(90%) | 联系人提醒(64%) | 查看步数(48%) | 下班晚餐 | (Code: `7411001`)
| PS-108 | 下班晚餐放桌 | evening | restaurant | stationary | on_desk | workday | 点餐建议(86%) | 休息提醒(60%) | 查看步数(45%) | 下班晚餐手机放桌 | (Code: `7413001`)
| PS-109 | 周末晚餐用机 | evening | restaurant | stationary | in_use | weekend | 点餐建议(88%) | 联系人提醒(70%) | 导航回家(50%) | 周末晚餐 | (Code: `7411002`)
| PS-110 | 节假日晚餐 | evening | restaurant | stationary | in_use | holiday | 点餐建议(84%) | 联系人提醒(74%) | 查看步数(52%) | 节假日晚餐 | (Code: `7411003`)
| PS-111 | 下班后夜跑 | evening | gym | running | in_pocket | workday | 查看步数(92%) | 补水提醒(88%) | 播放音乐(80%) | 下班后健身跑步 | (Code: `7535001`)
| PS-112 | 下班后健身 | evening | gym | walking | in_pocket | workday | 查看步数(88%) | 补水提醒(84%) | 拉伸提醒(70%) | 下班后健身 | (Code: `7525001`)
| PS-113 | 周末傍晚跑步 | evening | gym | running | in_pocket | weekend | 查看步数(90%) | 补水提醒(86%) | 播放音乐(76%) | 周末傍晚跑步 | (Code: `7535002`)
| PS-114 | 工作日傍晚散 | evening | outdoor | walking | in_pocket | workday | 查看步数(80%) | 播放音乐(68%) | 查看天气(58%) | 工作日傍晚散步 | (Code: `7625001`)
| PS-115 | 周末傍晚散步 | evening | outdoor | walking | in_pocket | weekend | 查看步数(84%) | 播放音乐(72%) | 查看天气(60%) | 周末傍晚散步 | (Code: `7625002`)
| PS-116 | 节假日傍晚外 | evening | outdoor | walking | in_pocket | holiday | 查看步数(82%) | 播放音乐(74%) | 导航(58%) | 节假日傍晚外出 | (Code: `7625003`)
| PS-117 | 加班中看日程 | evening | work | stationary | on_desk | workday | 查看今日日程(80%) | 久坐提醒(72%) | 下班提醒(68%) | 加班；下班提醒有价值 | (Code: `7213001`)
| PS-118 | 加班用手机 | evening | work | stationary | in_use | workday | 查看今日日程(74%) | 联系人提醒(60%) | 下班提醒(58%) | 加班中用手机 | (Code: `7211001`)
| PS-119 | 周末傍晚购物 | evening | shopping | walking | in_pocket | weekend | 导航到店铺(72%) | 查看步数(62%) | 补水提醒(52%) | 周末傍晚购物 | (Code: `7825002`)
| PS-120 | 节假日购物 | evening | shopping | walking | in_pocket | holiday | 导航到店铺(76%) | 查看步数(64%) | 补水提醒(54%) | 节假日购物 | (Code: `7825003`)
| PS-121 | 傍晚航班 | evening | airport | walking | in_pocket | workday | 检查行程(92%) | 导航到登机口(84%) | 联系人提醒(62%) | 傍晚航班 | (Code: `7725001`)
| PS-122 | 傍晚机场候机 | evening | airport | stationary | in_use | workday | 检查行程(90%) | 播放音乐(68%) | 联系人提醒(60%) | 傍晚机场候机 | (Code: `7711001`)
| PS-123 | 晚高峰驾车 | evening | unknown | driving | in_pocket | workday | 导航(86%) | 播放音乐(72%) | 停车位记录(60%) | 晚高峰驾车 | (Code: `7045001`)
| PS-124 | 下班途中未知 | evening | unknown | walking | in_pocket | workday | 播放音乐(78%) | 查看步数(68%) | 导航(60%) | 下班途中未知位置 | (Code: `7025001`)

---

### 🌙 night（20-23时）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-125 | 工作日夜间准备 | night | home | stationary | in_use | workday | 设置明日闹钟(88%) | 查看明日日程(80%) | 拉伸提醒(62%) | 工作日夜间；准备明天 | (Code: `8111001`)
| PS-126 | 工作日晚躺机 | night | home | stationary | holding_lying | workday | 设置明日闹钟(90%) | 查看明日日程(74%) | 休息提醒(68%) | 工作日晚躺着看手机 | (Code: `8112001`)
| PS-127 | 工作日夜间充电 | night | home | stationary | charging | workday | 设置明日闹钟(86%) | 查看明日日程(72%) | 拉伸提醒(60%) | 工作日晚充电 | (Code: `8117001`)
| PS-128 | 工作日夜暗室机 | night | home | stationary | face_up | workday | 设置明日闹钟(85%) | 休息提醒(72%) | 查看明日日程(65%) | 暗室静置，可能准备入睡 | (Code: `8114001`)
| PS-129 | 周末夜间娱乐 | night | home | stationary | in_use | weekend | 播放音乐(72%) | 查看步数(64%) | 查看新闻摘要(60%) | 周末夜间娱乐 | (Code: `8111002`)
| PS-130 | 周末晚躺着放松 | night | home | stationary | holding_lying | weekend | 播放音乐(70%) | 查看新闻摘要(62%) | 设置闹钟(52%) | 周末晚躺着放松 | (Code: `8112002`)
| PS-131 | 周末夜间充电 | night | home | stationary | charging | weekend | 播放音乐(65%) | 新闻摘要(58%) | 设置闹钟(50%) | 周末夜间充电 | (Code: `8117002`)
| PS-132 | 节假日夜间娱乐 | night | home | stationary | in_use | holiday | 播放音乐(70%) | 查看步数(60%) | 查看新闻摘要(58%) | 节假日夜间娱乐 | (Code: `8111003`)
| PS-133 | 周末宵夜 | night | restaurant | stationary | in_use | weekend | 点餐建议(84%) | 联系人提醒(70%) | 导航回家(55%) | 周末宵夜 | (Code: `8411002`)
| PS-134 | 节假日宵夜聚 | night | restaurant | stationary | in_use | holiday | 点餐建议(82%) | 联系人提醒(74%) | 导航回家(58%) | 节假日宵夜聚会 | (Code: `8411003`)
| PS-135 | 工作日夜跑 | night | gym | running | in_pocket | workday | 查看步数(88%) | 补水提醒(82%) | 播放音乐(74%) | 工作日夜跑 | (Code: `8535001`)
| PS-136 | 周末夜间健身 | night | gym | walking | in_pocket | weekend | 查看步数(84%) | 补水提醒(80%) | 拉伸提醒(68%) | 周末夜间健身 | (Code: `8525002`)
| PS-137 | 周末夜间散步 | night | outdoor | walking | in_pocket | weekend | 查看步数(80%) | 播放音乐(70%) | 导航回家(62%) | 周末夜间散步 | (Code: `8625002`)
| PS-138 | 节假日夜间外 | night | outdoor | walking | in_pocket | holiday | 查看步数(78%) | 播放音乐(72%) | 导航回家(65%) | 节假日夜间户外 | (Code: `8625003`)
| PS-139 | 周末夜间购物 | night | shopping | walking | in_pocket | weekend | 查看步数(64%) | 导航到店铺(60%) | 补水提醒(45%) | 周末夜间购物 | (Code: `8825002`)
| PS-140 | 加班驾车回家 | night | commute | driving | in_pocket | workday | 导航回家(88%) | 播放音乐(74%) | 停车位记录(62%) | 加班后驾车回家 | (Code: `8345001`)
| PS-141 | 夜间位置未知 | night | unknown | stationary | in_use | workday | 设置明日闹钟(80%) | 休息提醒(68%) | 查看明日日程(64%) | 夜间位置未知 | (Code: `8011001`)
| PS-142 | 周末夜间外出 | night | unknown | walking | in_pocket | weekend | 查看步数(70%) | 导航回家(65%) | 播放音乐(58%) | 周末夜间外出 | (Code: `8025002`)

---

### 🕛 late_night（23-24时）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-143 | 深夜工作日躺机 | late_night | home | stationary | holding_lying | workday | 设置明日闹钟(94%) | 休息提醒(88%) | 查看明日日程(72%) | 深夜工作日；睡眠准备最重要 | (Code: `9112001`)
| PS-144 | 深夜刷手机 | late_night | home | stationary | in_use | workday | 设置明日闹钟(92%) | 休息提醒(85%) | 查看明日日程(70%) | 深夜还在用手机 | (Code: `9111001`)
| PS-145 | 深夜充电备睡 | late_night | home | stationary | charging | workday | 设置明日闹钟(90%) | 休息提醒(78%) | 查看明日日程(65%) | 充电准备睡觉 | (Code: `9117001`)
| PS-146 | 深夜暗室静置 | late_night | home | stationary | face_up | workday | 设置明日闹钟(88%) | 休息提醒(82%) | 查看明日日程(60%) | 暗室静置，即将入睡 | (Code: `9114001`)
| PS-147 | 周末深夜躺着 | late_night | home | stationary | holding_lying | weekend | 播放音乐(68%) | 休息提醒(72%) | 设置闹钟(65%) | 周末深夜躺着 | (Code: `9112002`)
| PS-148 | 周末深夜刷机 | late_night | home | stationary | in_use | weekend | 休息提醒(75%) | 设置闹钟(68%) | 播放音乐(60%) | 周末深夜刷手机 | (Code: `9111002`)
| PS-149 | 周末深夜充电 | late_night | home | stationary | charging | weekend | 休息提醒(70%) | 设置闹钟(65%) | 播放白噪音(52%) | 周末深夜充电 | (Code: `9117002`)
| PS-150 | 深夜位置未知 | late_night | unknown | stationary | in_use | workday | 休息提醒(85%) | 设置闹钟(80%) | 查看明日日程(60%) | ⚠️LW2降权；深夜位置未知 | (Code: `9011001`)
| PS-151 | 深夜户外散步 | late_night | outdoor | walking | in_pocket | weekend | 导航回家(80%) | 查看步数(62%) | 播放音乐(55%) | 深夜外出步行 | (Code: `9625002`)

---

### 🚇 subway（地铁站）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-152 | 早高峰地铁通勤 | morning | subway | walking | in_use | workday | 查看到站时间(90%) | 听播客/音乐(80%) | 今日日程概览(70%) | 嘈杂环境，戴耳机 | (Code: `3921001`)
| PS-153 | 晚高峰地铁返程 | evening | subway | stationary | in_pocket | workday | 查看回家路线(88%) | 提醒下车站(75%) | 新闻摘要(60%) | 拥挤时手机入袋 | (Code: `7915001`)
| PS-154 | 工作日地铁晨用 | morning | subway | stationary | in_use | workday | 今日日程概览(88%) | 查看新闻摘要(78%) | 查看天气(62%) | 座位上刷手机 | (Code: `3911001`)
| PS-155 | 工作日晚班地铁 | evening | subway | walking | in_pocket | workday | 导航回家(82%) | 查看步数(68%) | 新闻摘要(58%) | 换乘步行中 | (Code: `7925001`)
| PS-156 | 工作日午间地铁 | lunch | subway | stationary | in_use | workday | 点餐建议(80%) | 导航到餐厅(72%) | 新闻摘要(55%) | 外出午餐途中 | (Code: `5911001`)
| PS-157 | 工作日下午地铁 | afternoon | subway | stationary | in_use | workday | 查看下午日程(82%) | 新闻摘要(70%) | 听播客(60%) | 下午出行 | (Code: `6911001`)
| PS-158 | 周末地铁出行 | morning | subway | stationary | in_use | weekend | 导航到目的地(85%) | 查看天气(72%) | 听播客(65%) | 周末出行 | (Code: `3911002`)
| PS-159 | 周末地铁夜归 | evening | subway | stationary | in_use | weekend | 导航回家(80%) | 查看步数(65%) | 新闻摘要(55%) | 周末夜间归家 | (Code: `7911002`)
| PS-160 | 周末午后地铁 | afternoon | subway | walking | in_pocket | weekend | 导航到目的地(80%) | 查看步数(65%) | 听音乐(60%) | 换乘步行 | (Code: `6925002`)
| PS-161 | 节假日地铁出游 | morning | subway | stationary | in_use | holiday | 查看景点信息(85%) | 导航到目的地(80%) | 查看天气(68%) | 节假日出行较拥挤 | (Code: `3911003`)

---

### 🚌 bus_stop（公交站）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-162 | 早高峰等公交 | morning | bus_stop | stationary | in_use | workday | 查看到站时间(92%) | 今日行程(78%) | 天气提醒(65%) | 户外等候 | (Code: `3A11001`)
| PS-163 | 晚高峰等公交 | evening | bus_stop | stationary | in_use | workday | 查看回家路线(90%) | 查看到站时间(82%) | 新闻摘要(60%) | 下班等车 | (Code: `7A11001`)
| PS-164 | 工作日早走等车 | morning | bus_stop | walking | in_pocket | workday | 查看到站时间(88%) | 听音乐(74%) | 今日日程(60%) | 走向公交站 | (Code: `3A25001`)
| PS-165 | 工作日晚走等车 | evening | bus_stop | walking | in_pocket | workday | 查看回家路线(85%) | 查看步数(68%) | 新闻摘要(55%) | 步行前往公交 | (Code: `7A25001`)
| PS-166 | 工作日下午等车 | afternoon | bus_stop | stationary | in_use | workday | 导航到目的地(85%) | 查看天气(70%) | 查看日程(58%) | 下午出行 | (Code: `6A11001`)
| PS-167 | 周末等公交出行 | morning | bus_stop | stationary | in_use | weekend | 查看到站时间(88%) | 导航到目的地(78%) | 查看天气(68%) | 周末出行 | (Code: `3A11002`)
| PS-168 | 周末傍晚等车 | evening | bus_stop | stationary | in_use | weekend | 导航回家(82%) | 查看步数(65%) | 新闻摘要(55%) | 周末归家 | (Code: `7A11002`)
| PS-169 | 周末午后等车 | afternoon | bus_stop | stationary | in_use | weekend | 导航到目的地(80%) | 查看天气(68%) | 查看步数(58%) | 周末外出 | (Code: `6A11002`)
| PS-170 | 节假日等公交 | morning | bus_stop | stationary | in_use | holiday | 查看到站时间(86%) | 导航到景点(82%) | 查看天气(72%) | 节假日出行 | (Code: `3A11003`)
| PS-171 | 节假日等车归途 | evening | bus_stop | stationary | in_use | holiday | 导航回家(84%) | 查看步数(68%) | 新闻摘要(58%) | 节假日归途 | (Code: `7A11003`)

---

### ⛴ ferry（轮渡/渡口）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-172 | 工作日早班轮渡 | morning | ferry | stationary | in_use | workday | 查看轮渡时刻(90%) | 今日行程(80%) | 听播客(65%) | 等待时间长 | (Code: `3B11001`)
| PS-173 | 工作日晚班轮渡 | evening | ferry | stationary | in_use | workday | 查看回家路线(88%) | 新闻摘要(75%) | 听播客(68%) | 下班乘轮渡 | (Code: `7B11001`)
| PS-174 | 工作日轮渡等候 | morning | ferry | stationary | in_pocket | workday | 查看轮渡时刻(85%) | 今日行程(72%) | 天气提醒(60%) | 码头等候 | (Code: `3B15001`)
| PS-175 | 工作日下午轮渡 | afternoon | ferry | stationary | in_use | workday | 查看轮渡时刻(82%) | 今日日程(70%) | 听播客(62%) | 下午出行 | (Code: `6B11001`)
| PS-176 | 周末轮渡出游 | morning | ferry | stationary | in_use | weekend | 查看轮渡时刻(88%) | 查看天气(80%) | 导航到目的地(70%) | 周末出游 | (Code: `3B11002`)
| PS-177 | 周末轮渡归途 | evening | ferry | stationary | in_use | weekend | 导航回家(85%) | 查看步数(68%) | 新闻摘要(60%) | 周末归途 | (Code: `7B11002`)
| PS-178 | 节假日轮渡出游 | morning | ferry | stationary | in_use | holiday | 查看轮渡时刻(90%) | 查看景点信息(82%) | 查看天气(74%) | 节假日出行 | (Code: `3B11003`)
| PS-179 | 节假日轮渡归途 | evening | ferry | stationary | in_use | holiday | 导航回家(86%) | 查看步数(70%) | 新闻摘要(62%) | 节假日归途 | (Code: `7B11003`)

---

---

### 🚉 train_station（火车站/高铁站）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-180 | 工作日赶高铁 | morning | train_station | walking | in_use | workday | 检查行程/车票(95%) | 导航到候车厅(86%) | 查看天气(55%) | 赶车，行程最优先 | (Code: `3C21001`)
| PS-181 | 工作日候车 | morning | train_station | stationary | in_use | workday | 检查行程/车票(92%) | 查看今日日程(78%) | 听播客(62%) | 候车等待时间长 | (Code: `3C11001`)
| PS-182 | 上午高铁候车 | forenoon | train_station | stationary | in_use | workday | 检查行程/车票(90%) | 查看新闻摘要(74%) | 听音乐(65%) | 上午班次候车 | (Code: `4C11001`)
| PS-183 | 午间高铁候车 | lunch | train_station | stationary | in_use | workday | 检查行程/车票(88%) | 导航到站内餐厅(72%) | 听音乐(58%) | 午间出行 | (Code: `5C11001`)
| PS-184 | 下午高铁候车 | afternoon | train_station | stationary | in_use | workday | 检查行程/车票(88%) | 听音乐/播客(72%) | 查看日程(60%) | 下午班次 | (Code: `6C11001`)
| PS-185 | 傍晚高铁出发 | evening | train_station | walking | in_use | workday | 检查行程/车票(90%) | 导航到候车厅(80%) | 联系人提醒(62%) | 傍晚班次赶车 | (Code: `7C21001`)
| PS-186 | 工作日到站接人 | evening | train_station | stationary | in_use | workday | 导航(78%) | 联系人提醒(88%) | 停车位记录(65%) | 接人等候 | (Code: `7C11001`)
| PS-187 | 夜间高铁候车 | night | train_station | stationary | in_use | workday | 检查行程/车票(88%) | 导航到候车厅(74%) | 联系人提醒(65%) | 晚班高铁 | (Code: `8C11001`)
| PS-188 | 周末出行高铁 | morning | train_station | walking | in_use | weekend | 检查行程/车票(90%) | 导航到候车厅(80%) | 查看天气(62%) | 周末出游赶车 | (Code: `3C21002`)
| PS-189 | 节假日高铁拥挤 | morning | train_station | walking | in_pocket | holiday | 提醒检票时间(90%) | 注意财物(78%) | 导航到检票口(72%) | 节假日人多拥挤 | (Code: `3C25003`)
| PS-190 | 节假日高铁候车 | afternoon | train_station | stationary | in_use | holiday | 检查行程/车票(88%) | 导航景点(70%) | 听音乐(65%) | 节假日出游 | (Code: `6C11003`)


---

### ☕ cafe（咖啡馆）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-191 | 工作日咖啡工作 | morning | cafe | stationary | on_desk | workday | 查看今日日程(88%) | 久坐提醒(72%) | 补水提醒(65%) | 咖啡馆办公，久坐提醒重要 | (Code: `3D13001`)
| PS-192 | 工作日咖啡刷机 | morning | cafe | stationary | in_use | workday | 查看今日日程(82%) | 点餐建议(70%) | 查看新闻(58%) | 早晨咖啡时间 | (Code: `3D11001`)
| PS-193 | 上午咖啡馆办公 | forenoon | cafe | stationary | on_desk | workday | 久坐提醒(90%) | 补水提醒(80%) | 查看日程(68%) | 居家/出差咖啡馆办公 | (Code: `4D13001`)
| PS-194 | 上午咖啡休闲 | forenoon | cafe | stationary | in_use | weekend | 查看天气(75%) | 查看新闻摘要(68%) | 播放音乐(58%) | 周末咖啡休闲 | (Code: `4D11002`)
| PS-195 | 午间咖啡馆 | lunch | cafe | stationary | in_use | workday | 点餐建议(86%) | 查看下午日程(68%) | 补水提醒(55%) | 午餐咖啡 | (Code: `5D11001`)
| PS-196 | 下午咖啡办公 | afternoon | cafe | stationary | on_desk | workday | 久坐提醒(88%) | 补水提醒(78%) | 查看日程(65%) | 下午咖啡馆工作 | (Code: `6D13001`)
| PS-197 | 周末下午咖啡 | afternoon | cafe | stationary | in_use | weekend | 查看天气(72%) | 播放音乐(65%) | 联系人提醒(55%) | 周末社交咖啡 | (Code: `6D11002`)
| PS-198 | 傍晚咖啡约会 | evening | cafe | stationary | in_use | weekend | 联系人提醒(78%) | 点餐建议(72%) | 导航回家(55%) | 周末社交聚会 | (Code: `7D11002`)
| PS-199 | 节假日咖啡馆 | afternoon | cafe | stationary | in_use | holiday | 播放音乐(70%) | 查看天气(65%) | 查看新闻(58%) | 节假日放松 | (Code: `6D11003`)

---

### 🎬 cinema（电影院）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-200 | 工作日电影前 | afternoon | cinema | stationary | in_use | workday | 查看场次/座位(92%) | 联系人提醒(68%) | 导航到影厅(62%) | 观影前查票 | (Code: `6E11001`)
| PS-201 | 工作日观影中 | afternoon | cinema | stationary | face_down | workday | 关闭通知提醒(88%) | 设置散场提醒(75%) | 静音确认(70%) | 观影中手机朝下 | (Code: `6E16001`)
| PS-202 | 工作日观影入袋 | afternoon | cinema | stationary | in_pocket | workday | 关闭通知提醒(85%) | 设置散场提醒(72%) | 静音确认(68%) | 拥挤影院手机入袋 | (Code: `6E15001`)
| PS-203 | 周末电影前 | afternoon | cinema | stationary | in_use | weekend | 查看场次/座位(94%) | 点餐建议(74%) | 联系人提醒(65%) | 周末观影，可能买爆米花 | (Code: `6E11002`)
| PS-204 | 周末观影中 | afternoon | cinema | stationary | face_down | weekend | 关闭通知提醒(90%) | 设置散场提醒(78%) | 静音确认(72%) | 观影礼仪 | (Code: `6E16002`)
| PS-205 | 晚间电影前 | evening | cinema | stationary | in_use | weekend | 查看场次/座位(92%) | 联系人提醒(72%) | 导航回家(55%) | 晚场电影 | (Code: `7E11002`)
| PS-206 | 晚间观影中 | evening | cinema | stationary | face_down | weekend | 关闭通知提醒(88%) | 设置散场提醒(75%) | 导航回家(60%) | 晚场观影结束提前准备回家 | (Code: `7E16002`)
| PS-207 | 节假日电影前 | afternoon | cinema | walking | in_use | holiday | 查看场次/座位(92%) | 点餐建议(76%) | 查看步数(48%) | 节假日热门场，提前到 | (Code: `6E21003`)
| PS-208 | 节假日观影中 | afternoon | cinema | stationary | in_pocket | holiday | 关闭通知提醒(90%) | 设置散场提醒(78%) | 静音确认(72%) | 节假日影院拥挤 | (Code: `6E15003`)

---

### 🌳 park（公园）

| ID | Title | 时间 | 位置 | 运动 | 手机 | 日期 | 推荐1（置信度%） | 推荐2（置信度%） | 推荐3（置信度%） | 备注（含StateCode） |
|----|-------|------|------|------|------|------|-----------------|-----------------|-----------------|---------------------|
| PS-209 | 工作日晨练公园 | dawn | park | running | in_pocket | workday | 查看步数(90%) | 补水提醒(82%) | 播放音乐(74%) | 早晨公园跑步 | (Code: `2F35001`)
| PS-210 | 工作日公园散步 | morning | park | walking | in_pocket | workday | 查看步数(86%) | 查看天气(72%) | 播放音乐(68%) | 上班前公园晨走 | (Code: `3F25001`)
| PS-211 | 午间公园休息 | lunch | park | stationary | in_use | workday | 查看下午日程(78%) | 补水提醒(70%) | 拉伸提醒(60%) | 午休公园 | (Code: `5F11001`)
| PS-212 | 下午公园跑步 | afternoon | park | running | in_pocket | workday | 查看步数(92%) | 补水提醒(88%) | 播放音乐(78%) | 下班前跑步 | (Code: `6F35001`)
| PS-213 | 工作日傍晚公园 | evening | park | walking | in_pocket | workday | 查看步数(84%) | 播放音乐(72%) | 查看天气(60%) | 下班后散步 | (Code: `7F25001`)
| PS-214 | 周末公园晨跑 | morning | park | running | in_pocket | weekend | 查看步数(94%) | 补水提醒(88%) | 播放音乐(80%) | 周末晨跑 | (Code: `3F35002`)
| PS-215 | 周末公园漫步 | morning | park | walking | in_use | weekend | 查看步数(84%) | 查看天气(72%) | 查看新闻摘要(62%) | 周末公园散步刷机 | (Code: `3F21002`)
| PS-216 | 周末公园野餐 | afternoon | park | stationary | in_use | weekend | 查看天气(80%) | 联系人提醒(70%) | 查看步数(58%) | 周末公园休闲 | (Code: `6F11002`)
| PS-217 | 节假日公园游览 | afternoon | park | walking | in_pocket | holiday | 查看步数(86%) | 导航景点(74%) | 查看天气(68%) | 节假日公园 | (Code: `6F25003`)
| PS-218 | 节假日公园跑步 | morning | park | running | in_pocket | holiday | 查看步数(92%) | 补水提醒(86%) | 播放音乐(76%) | 节假日晨跑 | (Code: `3F35003`)


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
| **noisy（嘈杂）** | 餐厅嘈杂、健身房、闹市户外、地铁站 | ① 播放音乐置信度 −15%（噪音环境效果差）② 点餐建议维持最高优先级 ③ 导航推荐切换为纯视觉模式（不语音播报）④ 通话/联系人提醒置信度 −10% |
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
| 地铁站早高峰 | normal | noisy | 音乐 −15%；到站时间维持最高；导航切视觉模式 |

---

## 使用方法

### 查询流程

```
1. 获取用户当前7元组: (time, location, motion, phone, light, sound, dayType)
2. 检查过滤规则 F1-F15，命中则标记为无效组合（跳过）
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
| 文档版本 | v1.5 |
| 创建日期 | 2026-03-03 |
| 更新日期 | 2026-03-03 |
| 矩阵规模 | 179 行（覆盖 time×location 核心组合，含 subway/bus_stop/ferry） |
| 推荐动作库 | 15+ 种可执行动作 |
| 维护方式 | 根据用户行为数据定期更新置信度 |
