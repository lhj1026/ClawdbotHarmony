# Context Intelligence Framework Design Document
> Version: 8.0
> Date: 2026-02-27
> Author: 刘洪杰 (Hongjie Liu)

### Revision History

| Version | Date | Author | Change Description |
|---------|------|--------|-------------------|
| 1.0 | 2026-02-17 | 刘洪杰 (Hongjie Liu) | Initial version: overview, data classification, perception plugins, intent recognition, importance calculation, reward system, learning system |
| 2.0 | 2026-02-19 | 刘洪杰 (Hongjie Liu) | Encoders changed to probability distribution output; intent recognition rewritten: configurable rules -> auto-compiled decision tree -> soft matching -> LinUCB (semantic fusion) -> 5-layer robustness protection; added temporal rules, OR conditions, cooldown, decision tracing, template inheritance, dynamic thresholds; composite reward function |
| 3.0 | 2026-02-19 | 刘洪杰 (Hongjie Liu) | Full document restructured following DDD 7-step method: Boundary -> Use Case -> Sub-domain -> Layer -> Architecture -> Narrow-down -> Entity; added system boundary definition, four problem domain partitioning, six-layer architecture model, execution domain design, implementation roadmap |
| 4.0 | 2026-02-20 | 刘洪杰 (Hongjie Liu) | C++ NAPI migration implementation (4 new modules); context.test remote testing capability; 21-scenario full coverage test suite; cooldown loadRules fix; actual directory structure update |
| 5.0 | 2026-02-22 | 刘洪杰 (Hongjie Liu) | LLM fallback rule feedback loop (pending -> promote/remove); rule deduplication mechanism; recommendation anti-duplication; active exploration mode design; FeedbackService card lifecycle; merged context_awareness_design.md (collection strategy, geofence learning, app learning, silent mode enhancement, wearable integration, data tray, training sync, feedback learning) |
| 7.0 | 2026-02-27 | 刘洪杰 (Hongjie Liu) | Stream Deep RL online reinforcement learning engine: Per-Arm StreamMLP (16→64→32→1) online training; Sparse Init + LayerNorm + ObGD stable training; Welford observation/reward normalization; LinUCB cold-start fallback + linear transition; NAPI bridge + ArkTS persistence; hybrid scoring formula |
| 8.0 | 2026-02-27 | 刘洪杰 (Hongjie Liu) | Action Execution System: ActionExecutor routes accepted recommendations to system capabilities (calendar, app launch, mode switch); CalendarPlugin extension (getUpcomingEvents, findConflicts, formatEventsMarkdown); Stream RL UI Display: recommendation cards show RL learning labels (探索中/学习中/已学习); ContextSettingsPage RL stats panel; NAPI getStreamRLStats/getStreamRLArmSamples; Explore mode RL phase info |
| 9.0 | 2026-03-02 | 刘洪杰 (Hongjie Liu) | State Transition Modeling: 7-dimension state model, 70-scenario enumeration, INPUT_DIM expansion 16→25 with 9 transition features (StateTransitionTracker C++), network architecture 25→128→64→1, recommendation card transition path bar (P0), persistence via NAPI |
| 10.0 | 2026-03-02 | 刘洪杰 (Hongjie Liu) | 7-Tuple Physical State & Scenario Intelligence: PhysicalState 7-tuple (time, location, motion, phone, light, sound, dayType) with 226,800 state space; PhysicalStateBuilder sensor→state classification; ScenarioMatcher deterministic chain matching (72 scenarios, 12 categories); Stream MLP 25→34 dim + LinUCB 8→14 dim feature expansion; ContextSettingsPage physical state card; dual pipeline architecture (rules + scenarios) |

---

## Table of Contents

- [1. Boundary — Problem Boundary](#1-boundary--problem-boundary)
  - [1.1 What Context Intelligence Is](#11-what-context-intelligence-is)
  - [1.2 What Context Intelligence Is Not](#12-what-context-intelligence-is-not)
  - [1.3 System Boundary Diagram](#13-system-boundary-diagram)
  - [1.4 Input Boundary](#14-input-boundary)
  - [1.5 Output Boundary](#15-output-boundary)
  - [1.6 Privacy Boundary](#16-privacy-boundary)
- [2. Use Case — Scenarios and Use Cases](#2-use-case--scenarios-and-use-cases)
  - [2.1 Physical World Data Sources](#21-physical-world-data-sources)
  - [2.2 Digital World Data Sources (by Maslow's Hierarchy of Needs)](#22-digital-world-data-sources-by-maslows-hierarchy-of-needs)
  - [2.3 Core Use Case List](#23-core-use-case-list)
  - [2.4 Use Case Priorities](#24-use-case-priorities)
- [3. Sub-domain — Problem Domain Partitioning](#3-sub-domain--problem-domain-partitioning)
  - [3.1 Four Major Problem Domains](#31-four-major-problem-domains)
  - [3.2 Perception Domain](#32-perception-domain)
  - [3.3 Decision Domain](#33-decision-domain)
  - [3.4 Execution Domain](#34-execution-domain)
  - [3.5 Learning Domain](#35-learning-domain)
  - [3.6 Inter-domain Interactions](#36-inter-domain-interactions)
- [4. Layer — Layered Architecture](#4-layer--layered-architecture)
  - [4.1 Six-Layer Model](#41-six-layer-model)
  - [4.2 Layer Responsibilities and Languages](#42-layer-responsibilities-and-languages)
  - [4.3 Inter-layer Dependency Rules](#43-inter-layer-dependency-rules)
- [5. Architecture — Architecture Design](#5-architecture--architecture-design)
  - [5.1 Perception Domain Architecture](#51-perception-domain-architecture)
  - [5.2 Decision Domain Architecture](#52-decision-domain-architecture)
  - [5.3 Execution Domain Architecture](#53-execution-domain-architecture)
  - [5.4 Learning Domain Architecture](#54-learning-domain-architecture)
  - [5.5 Full Data Flow Panorama](#55-full-data-flow-panorama)
- [6. Narrow-down — Technical Key Points](#6-narrow-down--technical-key-points)
  - [6.1 Decision Tree Auto-compilation](#61-decision-tree-auto-compilation)
  - [6.2 Soft Matching Strategy](#62-soft-matching-strategy)
  - [6.3 LinUCB Algorithm Details](#63-linucb-algorithm-details)
  - [6.4 Robustness Detailed Design](#64-robustness-detailed-design)
  - [6.5 Temporal Rules](#65-temporal-rules)
  - [6.6 Cooldown + Merged Push](#66-cooldown--merged-push)
  - [6.7 Cold Start Strategy](#67-cold-start-strategy)
  - [6.8 On-device Training Approach](#68-on-device-training-approach)
- [7. Entity — Implementation Design](#7-entity--implementation-design)
  - [7.1 Core Data Structures](#71-core-data-structures)
  - [7.2 C++ Module Design](#72-c-module-design)
  - [7.3 NAPI Interface Definitions](#73-napi-interface-definitions)
  - [7.4 ArkTS Service Design](#74-arkts-service-design)
  - [7.5 Storage Design](#75-storage-design)
  - [7.6 Directory Structure](#76-directory-structure)
  - [7.7 Implementation Roadmap](#77-implementation-roadmap)
- [8. Implementation Record — C++ NAPI Migration](#8-implementation-record--c-napi-migration)
  - [8.1 Migration Principles](#81-migration-principles)
  - [8.2 New C++ Modules](#82-new-c-modules)
  - [8.3 ArkTS Wrapper Layer](#83-arkts-wrapper-layer)
  - [8.4 Fixed Issues](#84-fixed-issues)
  - [8.5 Actual Directory Structure](#85-actual-directory-structure)
- [9. Test Suite](#9-test-suite)
  - [9.1 Test Architecture](#91-test-architecture)
  - [9.2 Test Scenario List](#92-test-scenario-list)
  - [9.3 Test Results](#93-test-results)
- [10. LLM Fallback Rule Feedback Loop](#10-llm-fallback-rule-feedback-loop)
  - [10.1 Design Goals](#101-design-goals)
  - [10.2 Rule Lifecycle](#102-rule-lifecycle)
  - [10.3 Pending Rule Storage](#103-pending-rule-storage)
  - [10.4 Feedback-driven Promotion/Demotion](#104-feedback-driven-promotiondemotion)
  - [10.5 Recommendation Anti-duplication](#105-recommendation-anti-duplication)
- [11. Rule Deduplication Mechanism](#11-rule-deduplication-mechanism)
  - [11.1 Deduplication Strategy](#111-deduplication-strategy)
  - [11.2 Deduplication Timing](#112-deduplication-timing)
- [12. Active Exploration Mode](#12-active-exploration-mode)
  - [12.1 Design Philosophy](#121-design-philosophy)
  - [12.2 Workflow](#122-workflow)
  - [12.3 State Fingerprint](#123-state-fingerprint)
  - [12.4 Differences from Normal Mode](#124-differences-from-normal-mode)
- [13. Multi-level Collection Strategy (Power Optimization)](#13-multi-level-collection-strategy-power-optimization)
  - [13.1 CellID Location Change Detection](#131-cellid-location-change-detection)
  - [13.2 Collection Interval Configuration](#132-collection-interval-configuration)
  - [13.3 Motion State Detection](#133-motion-state-detection)
  - [13.4 Phone Pickup Detection](#134-phone-pickup-detection)
- [14. Geofence Feature Learning](#14-geofence-feature-learning)
  - [14.1 Data Structure](#141-data-structure)
  - [14.2 Learning Trigger and Feature Matching](#142-learning-trigger-and-feature-matching)
- [15. App Usage Record Learning](#15-app-usage-record-learning)
- [16. Silent Mode Enhancement](#16-silent-mode-enhancement)
  - [16.1 Key Information Extraction](#161-key-information-extraction)
  - [16.2 Emotion/Mood Detection](#162-emotionmood-detection)
- [17. Wearable Device Integration](#17-wearable-device-integration)
- [18. Data Tray Specification](#18-data-tray-specification)
- [19. Training Data Sync System (C++)](#19-training-data-sync-system-c)
  - [19.1 Architecture Overview](#191-architecture-overview)
  - [19.2 C++ Data Structures](#192-c-data-structures)
  - [19.3 NAPI Interface](#193-napi-interface)
  - [19.4 Data Flow](#194-data-flow)
  - [19.5 Server-side Interface](#195-server-side-interface)
- [20. Feedback Learning System Detailed Design](#20-feedback-learning-system-detailed-design)
- [21. Stream Deep RL — Online Reinforcement Learning Engine](#21-stream-deep-rl--online-reinforcement-learning-engine)
  - [21.1 Overview](#211-overview)
  - [21.2 Data Flow Architecture](#212-data-flow-architecture)
  - [21.3 Key Techniques](#213-key-techniques)
  - [21.4 MLP Model Architecture (Per-Arm)](#214-mlp-model-architecture-per-arm)
  - [21.5 Hybrid Scoring and Cold-Start Strategy](#215-hybrid-scoring-and-cold-start-strategy)
  - [21.6 C++ Implementation Design](#216-c-implementation-design)
  - [21.7 NAPI Bridge Interface](#217-napi-bridge-interface)
  - [21.8 ArkTS Integration](#218-arkts-integration)
  - [21.9 File Manifest and Implementation Order](#219-file-manifest-and-implementation-order)
  - [21.10 Test Plan](#2110-test-plan)
- [22. Recommendation Action Execution System](#22-recommendation-action-execution-system)
  - [22.1 Overview](#221-overview)
  - [22.2 ActionExecutor Design](#222-actionexecutor-design)
  - [22.3 CalendarPlugin Extension](#223-calendarplugin-extension)
  - [22.4 NodeRuntime Integration](#224-noderuntime-integration)
  - [22.5 Active Recommendation Cache](#225-active-recommendation-cache)
- [23. Stream Deep RL UI Display](#23-stream-deep-rl-ui-display)
  - [23.1 Overview](#231-overview)
  - [23.2 New NAPI Functions](#232-new-napi-functions)
  - [23.3 Recommendation Card RL Labels](#233-recommendation-card-rl-labels)
  - [23.4 ContextSettingsPage Stats Panel](#234-contextsettingspage-stats-panel)
  - [23.5 Explore Mode RL Info](#235-explore-mode-rl-info)
- [24. State Transition Modeling and Feature Expansion](#24-state-transition-modeling-and-feature-expansion)
  - [24.1 7-Dimension State Model](#241-7-dimension-state-model)
  - [24.2 Scenario Enumeration (70 Scenarios)](#242-scenario-enumeration-70-scenarios)
  - [24.3 Input Dimension Coverage Analysis](#243-input-dimension-coverage-analysis)
  - [24.4 State Transition Features (9 Dimensions)](#244-state-transition-features-9-dimensions)
  - [24.5 StateTransitionTracker (C++)](#245-statetransitiontracker-c)
  - [24.6 Network Architecture Update (25→128→64→1)](#246-network-architecture-update-25128641)
  - [24.7 Recommendation Card Transition Path Bar](#247-recommendation-card-transition-path-bar)
  - [24.8 Future Roadmap](#248-future-roadmap)
- [25. 7-Tuple Physical State & Scenario Intelligence](#25-7-tuple-physical-state--scenario-intelligence)
  - [25.1 Architecture Overview](#251-architecture-overview)
  - [25.2 7-Tuple Physical State Model](#252-7-tuple-physical-state-model)
  - [25.3 PhysicalStateBuilder](#253-physicalstatebuilder)
  - [25.4 Scenario Chain Matching](#254-scenario-chain-matching)
  - [25.5 72 Scenario Definitions](#255-72-scenario-definitions)
  - [25.6 RL Feature Expansion](#256-rl-feature-expansion)
  - [25.7 Dual Pipeline Integration](#257-dual-pipeline-integration)
  - [25.8 UI Display](#258-ui-display)
  - [25.9 File Manifest](#259-file-manifest)
- [Appendix: TODO Items](#appendix-todo-items)

---

## 1. Boundary — Problem Boundary

### 1.1 What Context Intelligence Is

An **AI secretary** embedded in the phone that can:
- **Perceive** — Collect data from the physical world and digital world
- **Understand** — Know the user's needs and intentions
- **Act** — Provide assistance at the right moment

**Core Principles:**

| Principle | Description |
|-----------|-------------|
| **Independent Personality** | AI is a companion, not a subordinate; has its own opinions and boundaries |
| **Privacy First** | Users control what AI can see; minimum permissions by default |
| **Local First** | Personal data never leaves the device; learning is done locally |
| **Progressive Intelligence** | From rules to models to LLM, upgrading complexity as needed |

### 1.2 What Context Intelligence Is Not

| Not | Description |
|-----|-------------|
| Not a general AI assistant | Does not handle user-initiated conversations/Q&A (that's the ClawdBot main body's job) |
| Not a notification manager | Not just filtering/forwarding notifications, but proactively providing services after understanding the context |
| Not a background service | Not continuously polling all data, but event-driven + on-demand queries |
| Not a cloud system | Core decisions are made locally; cloud is only used for LLM fallback and model delivery |

### 1.3 System Boundary Diagram

```plantuml
@startuml
package "ClawdBot App (HarmonyOS)" {
  rectangle "Chat UI\n(User-initiated conversation)\n<- User sends message" as ChatUI
  rectangle "Context Intelligence Engine\n(Scope of this document)\nPerception->Decision->Execution->Learning\n<- Event-driven, proactive service" as ContextAI #LightBlue
  rectangle "OpenClaw Gateway\n(Cloud LLM channel)" as Gateway
  rectangle "HarmonyOS System APIs\n(Sensors/Notifications/Calendar/GPS)" as SystemAPI

  ChatUI --> Gateway
  ContextAI --> Gateway : LLM fallback
  ContextAI --> SystemAPI : Sensor data
  ChatUI --> SystemAPI
}
@enduml
```

**Boundary Definitions:**
- **Boundary with Chat UI**: User actively sends a message -> Chat UI handles it; context intelligence proactively pushes -> via notifications/cards/voice
- **Boundary with OpenClaw Gateway**: Context intelligence only calls Gateway at Layer 3 (LLM fallback); daily decisions are purely local
- **Boundary with HarmonyOS**: Context intelligence obtains sensor data and sends notifications via system APIs; does not modify system behavior

### 1.4 Input Boundary

```
Inputs received by context intelligence:
├── Physical world events (sensor-triggered)
│   ├── Location changes (GPS/WiFi/Bluetooth)
│   ├── Motion state changes (accelerometer)
│   ├── Environmental changes (light/noise/temperature)
│   └── Phone state changes (charging/battery/connectivity)
│
├── Digital world events (system notifications)
│   ├── New message notifications (IM/email/SMS)
│   ├── App notifications (food delivery/courier/bank)
│   ├── Calendar event reminders
│   └── System events (incoming calls/alarms)
│
└── User feedback (explicit + implicit)
    ├── Click/ignore/swipe away notifications
    ├── Say "thanks" / "don't bother me"
    └── Manually configure rules
```

### 1.5 Output Boundary

```
Outputs produced by context intelligence:
├── User notifications (primary output)
│   ├── System notification bar (fullscreen/banner/badge/silent)
│   ├── Voice broadcast (driving mode)
│   ├── Cards (rich media information)
│   └── Merged summaries (batch information digest)
│
├── Silent actions (non-intrusive)
│   ├── Pre-cache data (pre-load weather/traffic)
│   ├── Adjust system settings (mute/brightness)
│   └── Background preparation (organize schedule summary)
│
└── Feedback to learning system
    ├── Decision trace records
    └── Reward signals (for LinUCB)
```

### 1.6 Privacy Boundary

| Level | Symbol | AI Visible Content | Description |
|-------|--------|-------------------|-------------|
| **Open** | 🟢 | Full original text | AI has full visibility |
| **Summary** | 🟡 | Summary + metadata | AI only sees overview, not original text |
| **Forbidden** | 🔴 | Only "new message" | AI has no visibility |
| **Authorized** | 🔵 | Temporary full access | Visible after user authorization, revoked after use |

**Privacy Principles:**
1. Minimum permissions by default (new data sources default to 🔴)
2. User-initiated authorization
3. Temporary authorization auto-revokes
4. Summary level only provides statistics, not original text
5. Audit logs are available for review

---

## 2. Use Case — Scenarios and Use Cases

### 2.1 Physical World Data Sources

#### Human

| Subcategory | Data | Source |
|-------------|------|--------|
| **Vital Signs** | Heart rate, HRV, blood pressure, SpO2, body temperature | Watch/band |
| **Motion State** | Stationary (sitting/standing/lying), walking, running, cycling, riding in vehicle | Accelerometer |
| **Body Attributes** | Height, weight, body fat, age, gender | User profile |
| **Mental State** | Sleep quality, fatigue, stress, emotion | Inferred/self-reported |
| **Biometrics** | Voiceprint, face, fingerprint | Sensors |

#### Phone

| Subcategory | Data |
|-------------|------|
| **Posture** | Grip style, screen orientation |
| **Location** | GPS coordinates, place type (home/office/mall) |
| **Power** | Battery level, charging status |
| **Connectivity** | WiFi, Bluetooth, signal strength |
| **Time** | Time of day, day of week, holidays |

#### Environment (Five Senses)

| Sense | Data | Source |
|-------|------|--------|
| **Sight** | Light level, scene, people, objects | Camera/light sensor |
| **Hearing** | Noise level, ambient sound type, voice | Microphone |
| **Smell** | Air quality, PM2.5 | Sensor/API |
| **Taste** | (Indirect inference) | Scene + time |
| **Touch** | Temperature, humidity, atmospheric pressure | Environmental sensors |

### 2.2 Digital World Data Sources (by Maslow's Hierarchy of Needs)

| Level | Data | Privacy | Source |
|-------|------|---------|--------|
| **1. Physiological** | Food delivery/grocery orders | 🟢 | Meituan/Ele.me |
| | Health data trends | 🟡 | Health apps |
| | Medical diagnosis records | 🔴 | Medical apps |
| **2. Safety** | Courier/ride status | 🟢 | Courier/ride apps |
| | Bill reminders | 🟡 | Banking apps |
| | Financial details/passwords | 🔴 | Finance apps |
| **3. Social** | Public group chats | 🟢 | Social apps |
| | Private chat message summaries | 🟡 | IM apps |
| | Private conversation content | 🔴 | IM apps |
| **4. Esteem** | Tasks/schedule | 🟢 | Calendar/task apps |
| | Work document titles | 🟡 | Office apps |
| | Salary/performance | 🔴 | HR systems |
| **5. Self-actualization** | Public learning content | 🟢 | Learning platforms |
| | Learning progress | 🟡 | Learning apps |
| | Private diary | 🔴 | Note apps |

### 2.3 Core Use Case List

| Use Case | Trigger Condition | Action | Priority |
|----------|-------------------|--------|----------|
| Commute reminder | Weekday + 7:00 +/- 30min + at home | Push traffic + weather | 🟡 |
| Lunch recommendation | Weekday + 12:00 +/- 1h + at office | Push nearby restaurants/delivery | 🟢 |
| Important message | Spouse/boss sends message | Urgent notification | 🔴 |
| Low battery | Battery < 20% + not charging | Remind to charge | 🟡 |
| Bedtime summary | 22:00-24:00 + at home | Tomorrow's schedule + weather | 🟢 |
| Package arrival | Courier notification + at home | Remind to pick up | 🟢 |
| Exercise reminder | Sedentary > 2 hours | Suggest activity | 🟢 |
| Message pile-up | 3+ unread messages in 10 min | Merged reminder | 🟡 |
| Homebound traffic | Leaving office + getting in car | Broadcast traffic conditions | 🟡 |
| Sleep suggestion | 3 consecutive days using phone after 23:00 | Suggest going to bed earlier | 🟢 |
| Meeting preparation | 15 min before calendar event | Reminder + materials | 🟡 |
| Auto mute | Entering meeting room/cinema | Mute phone | ⚪ |

### 2.4 Use Case Priorities

| Phase | Use Cases | Reason |
|-------|-----------|--------|
| **MVP** | Commute reminder, important message, low battery, bedtime summary | Simple trigger conditions, high value |
| **Phase 2** | Lunch recommendation, message pile-up, meeting preparation, package arrival | Requires notification interception |
| **Phase 3** | Exercise reminder, sleep suggestion, auto mute, homebound traffic | Requires continuous sensors + temporal patterns |

---

## 3. Sub-domain — Problem Domain Partitioning

### 3.1 Four Major Problem Domains

```plantuml
@startuml
skinparam rectangle {
  RoundCorner 10
}

package "Context Intelligence System" {
  rectangle "Perception Domain\nPerception" as P #LightGreen
  rectangle "Decision Domain\nDecision" as D #LightBlue
  rectangle "Execution Domain\nExecution" as E #LightYellow
  rectangle "Learning Domain\nLearning" as L #LightPink

  P -right-> D : EncodedEvent
  D -right-> E : Decision
  E -right-> L : Feedback
  L -left-> P : Feedback loop
  L -up-> D : Update parameters
}
@enduml
```

### 3.2 Perception Domain

**Responsibility:** Collect raw data and encode it into structured probability distribution events

```
Input: Raw sensor data / System notifications / API data
Output: EncodedEvent (probability distribution + feature vector + data quality)

Sub-modules:
├── Plugin registration (category / classifier / encoder triad)
├── Physical world encoders (location/motion/environment -> probability distribution)
├── Digital world encoders (notifications/calendar/messages -> probability distribution)
└── Perception bus (event routing + privacy pre-filtering)
```

**Core Interface:** Probability distribution output (multi-label, normalization not required) + data quality score

### 3.3 Decision Domain

**Responsibility:** Based on the current context, decide what to do

```
Input: EncodedEvent + user context
Output: Decision (intent + confidence + action type + decision trace)

Sub-modules:
├── Rule configuration (user writes flat rules)
├── Decision tree compiler (auto-compilation + cost-aware sorting)
├── Soft matching engine (probability distribution -> multi-leaf confidence)
├── LinUCB policy (semantic fusion + action selection)
├── LLM fallback (scenarios not covered by decision tree)
├── Cooldown management
├── Temporal rule engine (event sequence matching)
└── Decision trace recording
```

**Core Algorithm:** Decision tree (soft matching) + LinUCB (semantic fusion + time decay)

### 3.4 Execution Domain

**Responsibility:** Transform decisions into concrete user-visible actions

```
Input: Decision
Output: User notifications / Voice broadcast / Silent actions

Sub-modules:
├── Privacy filter (last line of defense before execution)
├── Content generation (template filling / API assembly / LLM generation)
├── Form selection (fullscreen/banner/badge/voice/silent)
├── Timing scheduling (immediate/wait for unlock/wait for idle/merge)
├── Multi-modal output (text/card/voice/quick action)
└── Feedback collection trigger
```

**Core Strategy:** Urgency x User state -> Push form matrix

### 3.5 Learning Domain

**Responsibility:** Continuously improve decision quality from user feedback

```
Input: User feedback (explicit + implicit)
Output: Updated LinUCB parameters

Sub-modules:
├── Feedback collection (click/ignore/swipe away/thanks/don't bother me)
├── Reward calculation (base feedback + disturbance penalty + accuracy)
├── Anomaly detection (filter bad feedback)
├── LinUCB online update (time decay)
├── Checkpoint management (auto snapshots + rollback)
└── Performance monitoring (sliding window average reward)
```

**Core Mechanism:** 5-layer robustness protection + time-decay forgetting

### 3.6 Inter-domain Interactions

```plantuml
@startuml
rectangle "Perception Domain" as P #LightGreen
rectangle "Decision Domain" as D #LightBlue
rectangle "Execution Domain" as E #LightYellow
rectangle "Learning Domain" as L #LightPink
actor User as U

P -right-> D : EncodedEvent
D -right-> E : Decision
E -right-> U : Action (notification/voice)
U -down-> L : Feedback
L -left-> D : UpdatedParams (LinUCB)
@enduml
```

**Data Format Conventions:**
- Perception -> Decision: `EncodedEvent` (probability distribution + features + quality)
- Decision -> Execution: `Decision` (intent + confidence + action + trace)
- Execution -> Learning: `Feedback` (action_id + user response + delay)
- Learning -> Decision: Directly updates LinUCB internal parameters (A, b matrices)

---

## 4. Layer — Layered Architecture

### 4.1 Six-Layer Model

```plantuml
@startuml
skinparam component {
  BackgroundColor<<ui>> #DCEEFB
  BackgroundColor<<biz>> #D5E8D4
  BackgroundColor<<napi>> #FFF2CC
  BackgroundColor<<engine>> #F8CECC
  BackgroundColor<<os>> #E1D5E7
  BackgroundColor<<ext>> #F5F5F5
}

rectangle "Layer 6: ArkTS UI Layer\nRule configuration / Decision tracing / Learning settings / Notification cards" <<ui>> as L6
rectangle "Layer 5: ArkTS Business Layer\nAction execution / Content generation / Timing scheduling / Plugin management / Feedback collection" <<biz>> as L5
rectangle "Layer 4: C++ NAPI Bridge Layer\nJSON serialization / Type conversion / Async call wrapping" <<napi>> as L4
rectangle "Layer 3: C++ Engine Layer\nDecision tree / Soft matching / LinUCB / Event buffer / Cooldown / Tracing" <<engine>> as L3
rectangle "Layer 2: HarmonyOS System Layer\nSensor API / Notification interception / Calendar API / GPS / Bluetooth / WiFi" <<os>> as L2
rectangle "Layer 1: External Services Layer\nOpenClaw Gateway (LLM) / Weather API / Map API" <<ext>> as L1

L6 -down-> L5
L5 -down-> L4
L4 -down-> L3
L3 -down-> L2
L5 -down-> L2 : System API calls
L5 -down-> L1 : HTTP
@enduml
```

### 4.2 Layer Responsibilities and Languages

| Layer | Responsibility | Language | Reason |
|-------|---------------|----------|--------|
| UI Layer | User interaction interface | ArkTS | HarmonyOS UI must use ArkTS |
| Business Layer | Execution domain logic | ArkTS | Needs to call system APIs, UI rendering |
| NAPI Bridge | ArkTS <-> C++ | C++ | N-API standard |
| Engine Layer | Decision domain + Learning domain core | C++ | Performance, memory control, cross-platform |
| System Layer | Perception domain data sources | ArkTS -> C++ | System APIs use ArkTS, encoding uses C++ |
| External Services | LLM/API | HTTP | Network calls |

### 4.3 Inter-layer Dependency Rules

```
Upper layers can call lower layers ✅
Lower layers cannot call upper layers ❌ (use callbacks/events for notification)
Same-layer communication through interfaces ✅
Cross-layer calls prohibited (must go through adjacent layers) ❌
```

---

## 5. Architecture — Architecture Design

### 5.1 Perception Domain Architecture

#### Plugin Registration Triad

```plantuml
@startuml
skinparam rectangle {
  RoundCorner 10
}

rectangle "Perception Plugin" {
  rectangle "1. Category Registration\n- Physical/Digital world\n- Domain/subdomain\n- Default privacy level" as Cat #LightGreen
  rectangle "2. Classifier\n- Small model or rule function\n- Input: raw data\n- Output: classification label + confidence" as Cls #LightBlue
  rectangle "3. Encoder\n- Output probability distribution (multi-label)\n- Output feature vector (for LinUCB)\n- Output summary (for LLM)\n- Output data quality score" as Enc #LightYellow

  Cat -down-> Cls
  Cls -down-> Enc
}
@enduml
```

#### Encoder Output Specification

```typescript
interface EncodedOutput {
  distribution: Map<string, number>;  // Probability distribution (normalization not required)
  features: number[];                 // Feature vector
  summary?: string;                   // Text summary
  quality: number;                    // Data quality 0~1
}
```

#### Plugin Distribution Output Examples

| Plugin | Distribution Output | Description |
|--------|-------------------|-------------|
| Location | `{home:0.8, market:0.7, office:0.02}` | When GPS accuracy is poor, multiple locations have probabilities |
| Motion | `{still:0.6, walking:0.3, driving:0.1}` | At a red light, both stationary and driving are possible |
| Time Period | `{morning:0.9, commute:0.7}` | Non-mutually exclusive categories |
| Noise | `{quiet:0.4, office:0.5, cafe:0.3}` | Ambient sound is uncertain |

### 5.2 Decision Domain Architecture

#### Overall Flow

```plantuml
@startuml
start
:User rules (flat);
:compile();
:Decision tree (auto-compiled, cost-aware sorting);
:evaluateSoft();
:Multiple leaf nodes + confidence;
:Semantic fusion;
:State vector\n[raw features, context semantics, history];
:LinUCB selects action;
if (Confidence sufficient?) then (yes)
  :Output Decision;
else (no)
  :Fallback to LLM;
endif
stop
@enduml
```

#### Rule Configuration

Users write flat rules, the system auto-compiles them into a decision tree:

```typescript
interface SmartRule {
  id: string;
  name: string;
  enabled: boolean;
  conditions: Map<string, RuleCondition>;       // AND relationship
  conditionGroups?: Map<string, RuleCondition>[]; // OR groups (optional)
  temporal?: TemporalCondition;                 // Temporal condition (optional)
  extends?: string[];                           // Template inheritance (optional)
  intent: string;
  priority: '🔴' | '🟡' | '🟢' | '⚪';
  action: string;
  cooldown?: CooldownConfig;
}
```

#### Decision Tree Auto-compilation

- Automatically builds tree by key, merging identical keys
- Cost-aware sorting: cheap checks (time, day of week) placed at upper levels, expensive ones (GPS, sensors) at lower levels
- Automatically recompiles when rules change

#### Soft Matching

- Each condition returns 0~1 confidence (not boolean)
- Missing data = 0.5 (unknown ≠ non-match)
- Key features like location use multi-source fusion (GPS + WiFi + Bluetooth + history)
- Decision tree can traverse multiple paths, confidence multiplied along paths
- Final responses graded by confidence level

#### LinUCB (Semantic Fusion)

A single global LinUCB with semantically fused state vector as input:

```
State = concat(
  raw_features,     // Raw perception features ~20 dimensions
  context_vector,   // Leaf node semantically weighted fusion ~10 dimensions
  history_features, // Push count/recent feedback ~10 dimensions
) -> Total ~40 dimensions

score(action) = θᵀx + α√(xᵀA⁻¹x)
Update: A = γA + xxᵀ, b = γb + rx (γ=0.998 time decay)
```

### 5.3 Execution Domain Architecture

#### Execution Pipeline

```plantuml
@startuml
start
:Decision (from Decision Domain);
:Privacy filter;
note right: 🔴 Block / 🟡 Desensitize\n🟢 Pass / 🔵 Request authorization
if (Privacy passed?) then (yes)
  :Content generation;
  note right: Template filling (<10ms)\nAPI assembly (100-500ms)\nLLM generation (500-2000ms)
  :Form selection;
  note right: Urgency x User state matrix
  :Timing scheduling;
  note right: Immediate / Wait for unlock\nWait for idle / Merged push
  :Multi-modal output;
  note right: Text + Card + Voice\n+ Quick action buttons
  :Begin feedback collection;
else (blocked)
  stop
endif
stop
@enduml
```

#### Push Form Matrix

```
            Idle        Busy        Meeting     Sleeping    Driving
🔴 Now     Full+sound  Banner+vib  Banner+vib  Full+sound  Voice
🟡 Soon    Banner      Badge       Silent      Silent      Voice
🟢 Later   Badge       Silent      Silent      Silent      Silent
⚪ Bg      Silent      Silent      Silent      Silent      Silent
```

Low confidence (<0.6) automatically downgrades one level (fullscreen -> banner -> badge -> silent).

#### Merged Push

Multiple 🟢/⚪ pushes within 5 minutes are merged into a single summary notification.

### 5.4 Learning Domain Architecture

#### Reward Calculation

```python
reward = base_reward              # Explicit/implicit feedback
       + disturbance_penalty      # -0.1 x (recent push count^1.5)
       + accuracy_bonus           # Correct push +0.5 / Should have pushed but didn't -1.0
```

Time-period weighting: sleeping x3, meeting x2, driving x2.5.

#### 5-Layer Robustness Protection

| Layer | Protection | Mechanism |
|-------|-----------|-----------|
| Input | Feature anomaly | Range check + missing value filling |
| Feedback | Abnormal feedback | 3σ detection + frequency limiting + reward clipping |
| Model | Parameter protection | Time decay γ + 5% change limit + condition number monitoring |
| Output | Uncertainty | Confidence check + fallback to rules when uncertain |
| System | Overall degradation | Daily checkpoints + performance monitoring + auto rollback |

#### Cold Start

| Phase | Rules | RL | Description |
|-------|-------|-----|-------------|
| First 2 weeks | 100% | 0% | Only collect data |
| Week 2 | 70% | 30% | Start participating |
| Week 4+ | 30% | 70% | Gradually hand over control |
| Stabilized | Fallback | Leading | Use rules when RL is uncertain |

### 5.5 Full Data Flow Panorama

```plantuml
@startuml
skinparam activity {
  BackgroundColor<<perception>> #D5E8D4
  BackgroundColor<<decision>> #DCEEFB
  BackgroundColor<<execution>> #FFF2CC
  BackgroundColor<<learning>> #F8CECC
}

|Perception Domain|
start
:Sensors / Notifications;
:Perception plugin encoding;
note right: EncodedEvent\n{distribution, features, quality}

|Decision Domain|
:Decision tree (soft matching);
note right: Multiple leaf nodes\n[{leaf, confidence}]
:Semantic fusion;
note right: context_vector
:LinUCB selects action;
note right: Decision\n{intent, confidence, action, trace}

|Execution Domain|
:Privacy filter;
:Content generation;
note right: ActionContent\n{text, card, voice}
:Form selection + Timing scheduling;
:Push to user;

|Learning Domain|
:User feedback;
note right: Feedback\n{action_id, response, delay}
:Reward calculation;
note right: reward = base\n+ disturbance_penalty\n+ accuracy_bonus
:LinUCB update;
note right: A = γA + xxᵀ\nb = γb + rx

|Decision Domain|
:Parameters updated;
stop
@enduml
```

---

## 6. Narrow-down — Technical Key Points

### 6.1 Decision Tree Auto-compilation

**Key Selection Strategy:** `score = coverage x discrimination / cost`

```typescript
const featureCosts: Record<string, number> = {
  'weekday': 1, 'hour': 1, 'charging': 1, 'battery': 1,  // Free
  'keyword': 2, 'sender': 2, 'app': 2,                    // Lightweight
  'location': 10, 'activity': 10,                         // Requires sensors
  'noise': 15, 'heartrate': 20,                           // Expensive
};
```

Cheap keys placed at upper levels -> early pruning -> avoids unnecessary sensor queries.

### 6.2 Soft Matching Strategy

**Time:** Gaussian decay, 1.0 within tolerance, exponential decay beyond
```
target=7:30, tolerance=30min:
7:30->1.0, 7:00->1.0, 6:50->0.85, 6:30->0.45, 6:00->0.05
```

**Location:** Multi-source fusion takes the highest
```
GPS (if available) + WiFi SSID (0.95) + Bluetooth devices (0.8) + Historical inference
-> max(scores)
```

**Missing data:** confidence=0.5 (neutral), not 0 (negative)

### 6.3 LinUCB Algorithm Details

```
Select action: score = θᵀx + α√(xᵀA⁻¹x)
Update:        A = γA + xxᵀ, b = γb + rx
Parameters:    d≈40, α=1.0, γ=0.998
Memory:        A(40x40) x 10 actions x 4 bytes ≈ 70KB
Update time:   <0.01ms
```

**Semantic Fusion:** Leaf nodes -> semantic vectors (auto-generated from rule conditions) -> weighted fusion by confidence -> one global LinUCB

**Exploration Strategy:** 🔴 urgent: no exploration; low risk + user idle: ε=0.2; otherwise ε=0.05

### 6.4 Robustness Detailed Design

**Time Decay:** γ=0.998, half-life ≈ 346 iterations (approximately 2 weeks), old habits automatically fade

**Anomaly Detection:** Reward deviates 3σ / >5 feedback entries within 1 minute / features out of range -> filter

**Rollback:** Daily snapshots; 30% performance drop -> auto restore checkpoint

### 6.5 Temporal Rules

```typescript
interface TemporalCondition {
  event: string;                              // Event type
  window: number;                             // Time window (ms)
  count?: { min?: number, max?: number };
  sequence?: string[];                        // Ordered event sequence
}
```

Implementation: Event ring buffer (last 7 days, max 10,000 entries), O(N) scan.

### 6.6 Cooldown + Merged Push

```typescript
interface CooldownConfig {
  duration: number;       // Minimum interval (ms)
  scope: 'rule' | 'intent';  // Dedup scope
  resetOn?: string;       // Reset event
  merge?: boolean;        // Merge during cooldown
}
```

### 6.7 Cold Start Strategy

MVP starts with statistical learning (average reward table per leaf node action), then upgrades to LinUCB.

### 6.8 On-device Training Approach

| Phase | Approach | Description |
|-------|----------|-------------|
| MVP | Statistical learning (no gradients needed) | Average reward table, argmax |
| Phase 2 | Hand-written C++ LinUCB | Matrix operations, <100 lines of code |
| Phase 3 | MindSpore Lite (if training is supported) | Huawei native |

---

## 7. Entity — Implementation Design

### 7.1 Core Data Structures

```typescript
// Rule
interface SmartRule {
  id: string;
  name: string;
  enabled: boolean;
  conditions: Map<string, RuleCondition>;
  conditionGroups?: Map<string, RuleCondition>[];
  temporal?: TemporalCondition;
  extends?: string[];
  intent: string;
  priority: string;
  action: string;
  cooldown?: CooldownConfig;
}

// Decision tree node
interface ExecNode {
  key: string;
  branches: Map<Object, ExecNode | LeafNode>;
  fallthrough?: ExecNode;
}

// Leaf node
interface LeafNode {
  rules: SmartRule[];
  semantic: number[];  // Semantic vector
}

// Match result
interface MatchResult {
  rule: SmartRule;
  confidence: number;
  path: { key: string, actual: Object, expected: Object, confidence: number }[];
}

// Decision output
interface Decision {
  intent: string;
  confidence: number;
  priority: string;
  action: string;
  actionParams: Record<string, string>;
  trace: DecisionTrace;
}

// Encoder output
interface EncodedOutput {
  distribution: Map<string, number>;
  features: number[];
  quality: number;
  summary?: string;
}
```

### 7.2 C++ Module Design

```cpp
// Rule compiler
class RuleCompiler {
  ExecNode* compile(vector<Rule>& rules);
  string selectBestKey(vector<Rule>& rules);
  SemanticVector generateSemantic(Rule& rule);
};

// Decision tree execution
class DecisionTree {
  vector<MatchResult> evaluateSoft(ExecNode* root, Context& ctx);
};

// Soft matcher
class SoftMatcher {
  float match(string key, Value actual, Value expected);
  float matchLocation(string target, LocationSources& sources);
  float matchHour(float actual, float target, float tolerance);
};

// LinUCB policy
class RobustLinUCB {
  int selectAction(VectorXf& x);
  void update(int arm, VectorXf& x, float reward);
  // Built-in: time decay, anomaly filtering, reward clipping
};

// Event buffer
class EventRingBuffer {
  void push(Event& e);
  int countInWindow(string event, int64_t windowMs);
  bool matchSequence(vector<string>& seq, int64_t windowMs);
};

// Cooldown manager
class CooldownManager {
  bool isInCooldown(string ruleId);
  void startCooldown(string ruleId, int64_t durationMs);
  void mergeEvent(string ruleId, Event& e);
};

// Decision tracer
class DecisionTracer {
  void record(vector<MatchResult>& results, Context& ctx);
  string getHistory(int limit);  // JSON
};

// Model checkpoint
class ModelCheckpoint {
  void save(RobustLinUCB& model);
  void maybeRollback(RobustLinUCB& model, float currentAvgReward);
};
```

### 7.3 NAPI Interface Definitions

```typescript
// Calling C++ engine from ArkTS
import ruleEngine from 'libruleengine.so';

// Rule management
ruleEngine.loadRules(rulesJson: string): boolean;
ruleEngine.compileTree(): boolean;

// Event input
ruleEngine.pushEvent(eventJson: string): void;

// Decision
ruleEngine.evaluate(contextJson: string): string;  // -> Decision JSON

// Feedback
ruleEngine.feedback(ruleId: string, reward: number): void;

// Tracing
ruleEngine.getTraceHistory(limit: number): string;  // -> JSON

// Model management
ruleEngine.saveModel(path: string): boolean;
ruleEngine.loadModel(path: string): boolean;
ruleEngine.resetModel(): boolean;
```

### 7.4 ArkTS Service Design

```typescript
// Context intelligence main service
class ContextAIService {
  // Initialize engine
  async init(): Promise<void>;

  // Event loop: receive perception events -> decide -> execute
  async onEvent(event: EncodedEvent): Promise<void>;

  // Execution pipeline
  async executeAction(decision: Decision): Promise<void>;
}

// Perception plugin manager
class PluginManager {
  registerPlugin(plugin: PerceptionPlugin): void;
  startAll(): void;
  stopAll(): void;
}

// Content generator
class ContentGenerator {
  async generate(intent: string, context: Context): Promise<ActionContent>;
}

// Feedback collector
class FeedbackCollector {
  watch(actionId: string): void;
  onUserResponse(actionId: string, response: UserResponse): void;
}
```

### 7.5 Storage Design

```
entry/src/main/resources/
└── rawfile/
    └── context_ai/
        └── default_rules.json     # Pre-set rule library

AppData/
└── context_ai/
    ├── rules/
    │   ├── user_rules.json        # User-defined rules
    │   └── templates.json         # Rule templates
    ├── model/
    │   ├── linucb_params.bin      # LinUCB parameters (~70KB)
    │   ├── action_stats.json      # Statistical learning data (MVP)
    │   └── checkpoints/           # Historical checkpoints
    ├── data/
    │   ├── event_buffer.bin       # Event ring buffer
    │   ├── feedback_log.db        # Feedback log
    │   └── decision_trace.db      # Decision trace (last 1000 entries)
    └── config/
        └── learning_config.json   # Learning parameters (γ, α, etc.)
```

Total storage: < 5MB

### 7.6 Directory Structure

**Design Target Directory (Planned):**

```
entry/src/main/
├── ets/
│   └── service/
│       └── contextai/
│           ├── ContextAIService.ets    # Main service
│           ├── PluginManager.ets       # Plugin management
│           ├── ContentGenerator.ets    # Content generation
│           ├── DeliveryManager.ets     # Push form + timing
│           ├── FeedbackCollector.ets   # Feedback collection
│           └── plugins/                # Perception plugins
│               ├── LocationPlugin.ets
│               ├── TimePlugin.ets
│               ├── NotificationPlugin.ets
│               └── MotionPlugin.ets
├── cpp/
│   └── rule_engine/
│       ├── CMakeLists.txt
│       ├── napi_entry.cpp              # NAPI bindings
│       ├── rule_compiler.h/cpp         # Rule compiler
│       ├── decision_tree.h/cpp         # Decision tree
│       ├── soft_matcher.h/cpp          # Soft matching
│       ├── linucb.h/cpp                # LinUCB
│       ├── event_buffer.h/cpp          # Event buffer
│       ├── cooldown.h/cpp              # Cooldown management
│       ├── decision_tracer.h/cpp       # Decision tracing
│       ├── feedback_validator.h/cpp    # Anomaly detection
│       ├── model_checkpoint.h/cpp      # Checkpoints
│       └── json_utils.h/cpp            # JSON utilities
└── resources/rawfile/context_ai/
    └── default_rules.json
```

**Actual Implemented Directory (v2.38.0, 2026-02-20):**

```
entry/src/main/
├── ets/service/context/                      # ArkTS context intelligence services
│   ├── ContextAwarenessService.ets           # Main service (perception + scheduling)
│   ├── ContextEngine.ets                     # Decision engine ArkTS wrapper
│   ├── ContextModels.ets                     # Data model definitions
│   ├── DataTray.ets                          # Sensor data tray (NAPI wrapper)
│   ├── GeoUtils.ets                          # Geographic calculations (NAPI wrapper)
│   ├── Dbscan.ets                            # DBSCAN clustering (NAPI wrapper)
│   ├── LocationFusionNative.ets              # Location fusion (NAPI wrapper)
│   ├── LocationFusionService.ets             # Location fusion business logic
│   ├── LocationDiscoveryService.ets          # Location discovery + learning
│   ├── GeofenceManager.ets                   # Geofence management
│   ├── BehaviorLogger.ets                    # Behavior logging
│   ├── SensorDataTray.ets                    # Legacy data tray (kept as backup)
│   └── plugins/                              # Perception plugins
│       ├── MotionPlugin.ets                  # Motion state
│       ├── BatteryPlugin.ets                 # Battery/charging
│       ├── NetworkPlugin.ets                 # Network state
│       ├── ScreenStatePlugin.ets             # Screen state
│       └── DigitalWorldPlugin.ets            # Digital world (notification interception)
│
├── cpp/                                      # C++ NAPI modules
│   ├── CMakeLists.txt                        # Root CMake (registers all sub-modules)
│   ├── napi_exec.cpp                         # exec module
│   ├── context_engine/                       # Decision engine (core)
│   │   ├── CMakeLists.txt
│   │   ├── context_engine.h                  # Header (Rule, MatchResult, RuleEngine, etc.)
│   │   ├── context_engine_napi.cpp           # NAPI bindings
│   │   ├── rule_engine.cpp                   # Rule engine (evaluate + cooldown + rate limit)
│   │   ├── decision_tree.cpp                 # Decision tree auto-compilation
│   │   ├── soft_match.cpp                    # Soft matching (in/eq/lte/gte/range/neq + decay)
│   │   ├── mab.cpp                           # Multi-Armed Bandit
│   │   └── linucb.cpp                        # LinUCB algorithm
│   ├── data_tray/                            # Sensor data cache (TTL + quality decay)
│   │   ├── CMakeLists.txt
│   │   ├── data_tray.h                       # Header (singleton, thread-safe)
│   │   └── data_tray_napi.cpp                # NAPI bindings
│   ├── geo_utils/                            # Geographic calculations
│   │   ├── CMakeLists.txt
│   │   ├── geo_utils.h                       # Haversine + geofence ray casting
│   │   └── geo_utils_napi.cpp                # NAPI bindings
│   ├── dbscan_cluster/                       # DBSCAN clustering
│   │   ├── CMakeLists.txt
│   │   ├── dbscan_cluster.h                  # DBSCAN + time pattern + category inference
│   │   └── dbscan_cluster_napi.cpp           # NAPI bindings
│   ├── location_fusion/                      # Multi-source location fusion
│   │   ├── CMakeLists.txt
│   │   ├── location_fusion.h                 # GPS/WiFi/BT confidence fusion
│   │   └── location_fusion_napi.cpp          # NAPI bindings
│   ├── voiceprint/                           # Voiceprint recognition
│   └── types/                                # TypeScript declarations
│       ├── libdata_tray/                     # index.d.ts + oh-package.json5
│       ├── libgeo_utils/
│       ├── libdbscan/
│       └── liblocation_fusion/
│
├── ets/service/gateway/                      # OpenClaw node capabilities
│   ├── NodeRuntime.ets                       # Contains context.test invoke handler
│   └── GatewayProtocol.ets                   # Contains Command.CONTEXT_TEST
```

### 7.7 Implementation Roadmap

| Phase | Duration | Goal | Deliverables |
|-------|----------|------|-------------|
| **MVP** | 4 weeks | Basic rule engine + 4 core use cases | Hard-match decision tree + template notifications + statistical learning |
| **Phase 2** | 4 weeks | Soft matching + LinUCB + notification interception | Probability distribution encoding + LinUCB + 8 use cases |
| **Phase 3** | 4 weeks | Temporal rules + voice + robustness | Event buffer + TTS + 5-layer protection + 12 use cases |
| **Phase 4** | Ongoing | LLM fallback + federated learning + more plugins | Complete system |

**MVP Details:**
1. Week 1: C++ decision tree (hard matching) + NAPI interface
2. Week 2: 4 perception plugins (time/location/battery/notification)
3. Week 3: ArkTS execution layer (notification push + template content)
4. Week 4: Statistical learning + feedback collection + basic UI

---

## 8. Implementation Record — C++ NAPI Migration

> Date: 2026-02-20
> Principle: ArkTS only handles UI + HarmonyOS API calls + NAPI bridging; all computation, caching, and algorithms in C++

### 8.1 Migration Principles

| Principle | Description |
|-----------|-------------|
| **C++ for computation** | Distance calculation, clustering, fusion, rule matching all native |
| **ArkTS for bridging** | Thin wrapper layer, only does JSON conversion + NAPI calls |
| **ArkTS for system calls** | Sensors, GPS, WiFi, Bluetooth, notifications and other HarmonyOS Kit APIs can only be called from ArkTS |
| **Header-only implementation** | New modules use header file implementation + separate NAPI binding .cpp, simplifying compilation |
| **Singleton pattern** | data_tray uses `std::mutex` for thread-safe singleton |

### 8.2 New C++ Modules

| Module | SO Name | Functionality | Key Algorithm |
|--------|---------|---------------|---------------|
| **data_tray** | libdata_tray.so | Sensor data caching | TTL expiry + quality decay (linear interpolation) |
| **geo_utils** | libgeo_utils.so | Geographic distance calculation | Haversine formula + polygon geofence ray casting |
| **dbscan_cluster** | libdbscan.so | Location clustering + learning | DBSCAN + time pattern analysis + category inference |
| **location_fusion** | liblocation_fusion.so | Multi-source location fusion | GPS/WiFi/BT confidence-weighted fusion |

**Pre-existing C++ Modules (before migration):**

| Module | SO Name | Functionality |
|--------|---------|---------------|
| **context_engine** | libcontext_engine.so | Rule engine + decision tree + soft matching + LinUCB + MAB + event buffer |
| **voiceprint** | libvoiceprint.so | Voiceprint recognition (stub) |
| **exec** | libexec.so | Shell command execution |

### 8.3 ArkTS Wrapper Layer

| Wrapper File | Corresponding C++ Module | Replaced Legacy ArkTS Implementation |
|-------------|-------------------------|--------------------------------------|
| DataTray.ets | data_tray | SensorDataTray.ets (kept as backup) |
| GeoUtils.ets | geo_utils | GeofenceManager inline distance calculation |
| Dbscan.ets | dbscan_cluster | LocationDiscoveryService inline DBSCAN |
| LocationFusionNative.ets | location_fusion | LocationFusionService inline confidence calculation |

### 8.4 Fixed Issues

| Issue | File | Fix |
|-------|------|-----|
| context_engine not compiled | cpp/CMakeLists.txt | Added `add_subdirectory(context_engine)` |
| ImportLinUCB function not closed | context_engine_napi.cpp | Added `return nullptr;` and `}` |
| loadRules doesn't clear cooldown | rule_engine.cpp | Clear all lastFired_/categoryFirings_/globalFirings_ on loadRules |

### 8.5 Remote Testing Capability — context.test

Remote scenario injection testing implemented via the OpenClaw Node invoke protocol.

**Call Chain:**
```
Server (nodes invoke) -> Gateway -> Susan (WebSocket) -> NodeRuntime.handleContextTest()
  -> ContextEngineService.init() -> nativeLoadRules() -> nativeEvaluate() -> Return MatchResult[]
```

**Invoke Parameters:**
```json
{
  "scenario": "Scenario name",
  "loadDefaultRules": true,           // Optional: reload built-in rules (including cooldown clearing)
  "geofences": [                      // Optional: bind geofences
    { "id": "work_001", "category": "work" }
  ],
  "snapshot": {                       // Required: simulated ContextSnapshot
    "timeOfDay": "morning",
    "hour": "8",
    "dayOfWeek": "1",
    "isWeekend": "false",
    "motionState": "walking",
    "batteryLevel": "10",
    "isCharging": "false",
    "networkType": "cellular",
    "geofence": "work_001"            // Optional
  },
  "maxResults": 5                     // Optional: maximum returned results
}
```

**Gateway Configuration:** `gateway.nodes.allowCommands` must include `"context.test"`

---

## 9. Test Suite

### 9.1 Test Architecture

```
Server (Linda/OpenClaw)
  │
  ├── nodes invoke context.test  -->  Susan (Phone App)
  │                                       │
  │                                       ├── ContextEngineService.init()
  │                                       ├── loadDefaultRules() + rebindGeofences()
  │                                       ├── C++ nativeEvaluate(snapshot)
  │                                       │     ├── Decision tree routing
  │                                       │     ├── Soft matching (in/eq/lte/gte/range/neq)
  │                                       │     └── Cooldown + Rate Limit check
  │                                       │
  │  <-- Return { matches, ruleCount } ---┘
  │
  └── Verify matches vs expected
```

### 9.2 Test Scenario List

#### Full Rule Coverage (11/11 rules)

| # | Scenario | Key Conditions | Expected Rule | Result |
|---|----------|---------------|---------------|--------|
| 1 | Low battery commute | morning + walking + battery=10 + !charging | rule_low_battery(100%) + rule_morning_workday(100%) | PASS |
| 2 | Weekday driving commute | morning + driving + !weekend | rule_morning_workday(100%) + rule_commuting(100%) | PASS |
| 3 | Arrive at office | morning + stationary + geofence=work | rule_arrive_work(100%) | PASS |
| 4 | Weekend morning at home | morning + weekend + stationary | rule_weekend_morning(100%) + rule_long_stationary(100%) | PASS |
| 5 | Late night stationary | night + hour=23 + stationary | rule_bedtime(100%) | PASS |
| 6 | Evening leaving work driving | evening + driving + !weekend | rule_commuting(100%) | PASS |
| 7 | Evening arrive home | evening + stationary + geofence=home | rule_evening_home(100%) | PASS |
| 8 | Negative - afternoon stationary no geofence | afternoon + stationary + battery=60 | Only rule_long_stationary(100%) | PASS |
| 9 | Arrive at gym | evening + stationary + geofence=gym | rule_arrive_gym(100%) | PASS |
| 10 | Morning leave home (full match) | morning + walking + geofence != home | rule_leave_home_morning(100%) | PASS |
| 11 | Leave work after hours | evening + walking + geofence != work | rule_leave_work(100%) | PASS |

#### Boundary Value Tests

| # | Scenario | Key Conditions | Expected | Result |
|---|----------|---------------|----------|--------|
| 12 | Battery exactly 15% | batteryLevel=15 + !charging | rule_low_battery(100%) | PASS |
| 13 | Battery 16% (soft decay) | batteryLevel=16 + !charging | rule_low_battery(33%) decay | PASS |
| 14 | Charging with low battery | batteryLevel=10 + charging | rule_low_battery not triggered | PASS |
| 17 | hour=22 boundary | hour=22 + stationary | rule_bedtime(100%) | PASS |
| 18 | hour=21 decay | hour=21 + stationary | rule_bedtime(55%) soft decay | PASS |

#### Motion State Coverage

| # | Scenario | motionState | Verification | Result |
|---|----------|------------|--------------|--------|
| 1 | Walking commute | walking | rule_morning_workday triggered | PASS |
| 2 | Driving commute | driving | rule_commuting triggered | PASS |
| 15 | Running | running | Does not falsely trigger commute rules | PASS |
| 16 | Transit | transit | rule_commuting triggered | PASS |
| 20 | Cycling | cycling | Does not falsely trigger commute rules | PASS |
| 4 | Stationary | stationary | rule_long_stationary triggered | PASS |

#### Network State Coverage

| # | Scenario | networkType | Result |
|---|----------|-----------|--------|
| Multiple | WiFi | wifi | PASS |
| Multiple | Cellular | cellular | PASS |
| 19 | No network | none | PASS, no false triggers |

#### Negative Tests

| # | Scenario | Verification | Result |
|---|----------|-------------|--------|
| 8 | Afternoon stationary no geofence | Does not trigger commute/leave rules | PASS |
| 14 | Charging with low battery | Does not trigger low battery reminder | PASS |
| 15 | Running on weekend | Does not falsely trigger commute | PASS |
| 20 | Cycling on weekend | Does not falsely trigger commute | PASS |
| 21 | Inside home geofence + morning | Does not trigger leave_home | PASS |

### 9.3 Test Results

- **Total scenarios:** 21
- **Passed:** 21/21 (100%)
- **Rule coverage:** 11/11 (100%)
- **Motion state coverage:** 6/6 (stationary/walking/running/cycling/driving/transit)
- **Network type coverage:** 3/3 (wifi/cellular/none)
- **Geofence category coverage:** 3/6 (home/work/gym); transit/shopping/restaurant have no built-in rules (handled by ContextAwarenessService default recommendation logic, not through C++ engine)

### 9.4 Discovered and Fixed Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| Same rule won't trigger in consecutive tests | loadRules doesn't clear lastFired_ cooldown map | Clear all cooldown timers on loadRules |
| context_engine.so fails to load | CMakeLists.txt missing add_subdirectory | Added context_engine to root CMakeLists |
| ImportLinUCB compilation error | Function missing return + closing brace | Added `return nullptr;` and `}` |

---

## 10. LLM Fallback Rule Feedback Loop

> Date: 2026-02-22
> Core Problem: Rules generated by LLM fallback should not be immediately added to the rule library; they need user feedback confirmation before being promoted to persistent rules

### 10.1 Design Goals

| Goal | Description |
|------|-------------|
| **Non-intrusive** | LLM-suggested rules are only "tentative"; discarded if user doesn't approve |
| **Progressive learning** | Only user-approved rules are written to the engine, preventing rule library bloat |
| **Feedback loop** | Every user interaction (thumbs up/thumbs down/execute/ignore/swipe away) produces a clear promotion/demotion signal |

### 10.2 Rule Lifecycle

```plantuml
@startuml
[*] --> LLM_Generated
LLM_Generated --> Pending : addPendingRule()
Pending --> Shown_to_User : Recommendation card
Shown_to_User --> Promoted : Thumbs up / Execute action
Shown_to_User --> Removed : Thumbs down
Shown_to_User --> Removed : Swipe away (after 5min)
Shown_to_User --> Removed : Ignore (after 10min)
Promoted --> Rule_Library : promotePendingRule()
Removed --> [*] : removePendingRule()
Rule_Library --> [*] : Persisted to C++ engine
@enduml
```

**Three States:**

| State | Storage Location | Persistence | Description |
|-------|-----------------|-------------|-------------|
| **Pending** | `ContextEngineService.pendingLlmRules` (Map) | In-memory | Just generated by LLM, awaiting user feedback |
| **Promoted** | C++ RuleEngine (nativeAddRule) | Disk | User approved, becomes a persistent rule |
| **Removed** | None | None | User rejected or timed out, discarded |

### 10.3 Pending Rule Storage

```typescript
// In ContextEngineService
private pendingLlmRules: Map<string, ContextRule> = new Map();

// Add pending rule (not written to engine)
addPendingRule(rule: ContextRule): void {
  this.pendingLlmRules.set(rule.id, rule);
}

// Promote to official rule (deduplicated before writing to engine)
async promotePendingRule(ruleId: string): Promise<boolean> {
  let rule = this.pendingLlmRules.get(ruleId);
  if (!rule) return false;
  if (this.isDuplicateRule(rule)) {
    this.pendingLlmRules.delete(ruleId);
    return false;  // Duplicate rule already exists
  }
  await this.addRule(rule);
  this.pendingLlmRules.delete(ruleId);
  return true;
}

// Delete pending rule
removePendingRule(ruleId: string): void {
  this.pendingLlmRules.delete(ruleId);
}
```

### 10.4 Feedback-driven Promotion/Demotion

**FeedbackService Decision Matrix:**

| User Action | reward | LLM Rule Handling | Normal Rule Handling |
|-------------|--------|-------------------|---------------------|
| Thumbs up | +1.0 | `promotePendingRule()` -> write to engine | LinUCB positive reward |
| Execute action | +0.8 | `promotePendingRule()` -> write to engine | LinUCB positive reward |
| Thumbs down | -0.5 | `removePendingRule()` -> discard | LinUCB negative reward |
| Swipe away (5min) | -0.1 | `removePendingRule()` -> discard | LinUCB mild penalty |
| Ignore (10min) | -0.2 | `removePendingRule()` -> discard | LinUCB mild penalty |

**Card Lifecycle Management:**

```
onCardShown(rec)
  ├── Start 10min ignore timer
  └── Record ActiveCard { rec, shownAt, timers, resolved }

onCardDismissed(ruleId)
  ├── Clear ignore timer
  └── Start 5min dismiss timer

onThumbsUp / onActionTaken (ruleId)
  ├── resolveCard() -> clear all timers
  ├── recordFeedback(ruleId, type, reward)
  ├── logToBehavior()
  └── handleLlmRuleFeedback(ruleId, positive=true) -> promote

onThumbsDown(ruleId)
  ├── resolveCard() -> clear all timers
  ├── recordFeedback(ruleId, type, reward)
  └── handleLlmRuleFeedback(ruleId, positive=false) -> remove
```

### 10.5 Recommendation Anti-duplication

**Problem:** The same type of LLM suggestion (e.g., "commute home from work") should not be repeatedly pushed if the user hasn't responded.

**Solution:** ContextAwarenessService tracks the last LLM recommendation payload:

```typescript
private lastLlmPayload: string = '';          // Last LLM recommendation content
private lastLlmRuleId: string = '';           // Last LLM rule ID
private lastLlmFeedbackReceived: boolean = false;  // Whether feedback has been received

// When LLM generates a new recommendation
if (llmPayload === this.lastLlmPayload && !this.lastLlmFeedbackReceived) {
  // Skip duplicate recommendation, only update timestamp (don't create new card)
  return;
}

// FeedbackService notifies via callback that feedback has been received
feedbackSvc.setLlmFeedbackCallback((ruleId: string) => {
  this.markLlmFeedbackReceived(ruleId);
});
```

**Rule ID Format:** `user_llm_yyyy-MM-dd HH:mm:ss` (human-readable timestamp)

---

## 11. Rule Deduplication Mechanism

> Date: 2026-02-22
> Core Problem: The rule library may contain functionally duplicate rules that need automatic deduplication

### 11.1 Deduplication Strategy

**Two-level Deduplication:**

| Level | Matching Method | Description |
|-------|----------------|-------------|
| **Exact dedup** | Action payload is identical | Two rules produce the exact same action -> keep only one |
| **Semantic dedup** | Core conditions highly overlapping (>= 3 keys identical) | Two rules are equivalent on key dimensions -> keep only one |

**Core Condition Keys:**
- `timeOfDay` — Time period
- `isWeekend` — Weekday/weekend
- `motionState` — Motion state
- `geofence` — Geofence location

```typescript
// Exact dedup: compare action payload
isDuplicateRule(newRule: ContextRule): boolean {
  let newPayload = JSON.stringify(newRule.action);
  let existingRules = this.exportRules();
  // ... iterate through existing rules
  if (existingPayload === newPayload) return true;  // Exact match

  // Semantic dedup: compare core conditions
  if (this.conditionsOverlap(existingConditions, newConditions)) return true;

  return false;
}

// Core condition overlap detection
conditionsOverlap(a: Map<string, Object>, b: Map<string, Object>): boolean {
  let coreKeys = ['timeOfDay', 'isWeekend', 'motionState', 'geofence'];
  let matchCount = 0;
  for (let key of coreKeys) {
    if (a.get(key) === b.get(key)) matchCount++;
  }
  return matchCount >= 3;  // 3/4 core conditions identical -> judged as duplicate
}
```

### 11.2 Deduplication Timing

| Timing | Method | Description |
|--------|--------|-------------|
| **Engine initialization** | `deduplicateRules()` | Clean up existing duplicate rules at startup |
| **Rule promotion** | `promotePendingRule()` calls `isDuplicateRule()` internally | Check before LLM rule promotion |
| **Manual addition** | Optional check in `addRule()` | When user manually adds rules |

---

## 12. Active Exploration Mode

> Date: 2026-02-22 (Design phase)
> Core Philosophy: Let AI proactively explore user's preference needs in each new context

### 12.1 Design Philosophy

In normal mode, context intelligence only calls LLM fallback when rule matching fails. **Active exploration mode** inverts this logic:

- **Every time an unexplored state combination is encountered**, proactively call LLM to generate suggestions
- **User feedback determines whether to convert into a persistent rule**
- Goal: Rapidly learn the user's real needs across various scenarios

```
Normal mode:    Rule matching -> Hit? -> Recommend / Miss -> LLM fallback (probabilistic trigger)
Exploration:    State change -> New state? -> Always trigger LLM -> User feedback -> Rule conversion
```

### 12.2 Workflow

```plantuml
@startuml
start
:State snapshot (ContextSnapshot);
:Compute state fingerprint;
if (Fingerprint already explored?) then (yes)
  :Skip, follow normal flow;
  stop
else (no)
  :Mark as explored;
  :Call LLM to generate context suggestion;
  :Create Pending Rule;
  :Show recommendation card;
  if (User feedback?) then (Thumbs up / Execute)
    :promotePendingRule();
    note right: Rule made permanent
  else (Thumbs down / Ignore / Swipe away)
    :removePendingRule();
    note right: Discard
  endif
endif
stop
@enduml
```

### 12.3 State Fingerprint

To avoid repeatedly triggering LLM for the "same state", a **state fingerprint** needs to be defined:

```typescript
// Compress ContextSnapshot into a comparable string
function computeFingerprint(snapshot: ContextSnapshot): string {
  // Only take core dimensions, ignore high-frequency changing dimensions (e.g., exact time, battery percentage)
  return `${snapshot.timeOfDay}|${snapshot.isWeekend}|${snapshot.motionState}|${snapshot.geofence || 'none'}`;
}
```

**Fingerprint Granularity Design:**

| Dimension | Included in Fingerprint | Description |
|-----------|------------------------|-------------|
| timeOfDay | Yes | morning/afternoon/evening/night |
| isWeekend | Yes | Weekday and weekend behaviors differ |
| motionState | Yes | Stationary/walking/driving, etc. |
| geofence | Yes | Home/office/gym, etc. |
| hour | No | Too fine-grained; 7:00 and 7:30 should not be different states |
| batteryLevel | No | Continuously changing, not suitable as fingerprint |
| wifiSsid | No | Already indirectly covered by geofence |

**Fingerprint Space Estimation:**
- timeOfDay: 4 types
- isWeekend: 2 types
- motionState: 6 types
- geofence: ~10 types (including none)
- Total: 4 x 2 x 6 x 10 = **480 combinations**

At 10 new states explored per day, approximately 48 days to cover all combinations. In practice, users encounter about 30-50 state combinations in daily use.

### 12.4 Differences from Normal Mode

| Dimension | Normal Mode | Active Exploration Mode |
|-----------|------------|------------------------|
| LLM trigger condition | All rules miss + probabilistic trigger | Every new state fingerprint always triggers |
| Recommendation frequency | Low (limited by cooldown and dedup) | High (triggered on new states) |
| Rule growth rate | Slow (occasional LLM fallback approved) | Fast (continuous exploration + feedback) |
| Use case | Daily use | New user cold start / User manually enables |
| Toggle | Enabled by default | User manually enables |
| API cost | Low | Higher (more LLM calls) |

**Recommended Use Cases:**
1. **New user cold start**: Enable for the first 1-2 weeks to quickly build a personal rule library
2. **Context change**: After moving/changing jobs, enable briefly to re-learn
3. **Curious users**: Want to see what AI can suggest in various scenarios

---

## 13. Multi-level Collection Strategy (Power Optimization)

> Source: context_awareness_design.md Section 1
> Design Principle: Dynamically adjust sensor collection frequency based on motion state; reduce frequency when stationary to save power, increase frequency when moving for accuracy

### 13.1 CellID Location Change Detection

**Principle:** Cell tower CellID changes -> user may have moved; CellID unchanged -> location hasn't changed

```
1. Get current CellID
2. If CellID is the same as last time:
   - Don't request GPS, continue using cached location
3. If CellID has changed:
   - May have moved, request GPS once
   - Update cached location
```

**Advantage:** CellID has extremely low power consumption (part of network state), greatly reduces GPS requests, especially effective in indoor/stationary scenarios

**API:** `@ohos.telephony.radio` — `getSignalInformation()` or listen for network state changes

> Note: HarmonyOS `radio.getSignalInformation()` only returns signalType/signalLevel, doesn't directly provide CellID. Alternative: `telephony.radio.getNetworkState()` or rely on WiFi + accelerometer

### 13.2 Collection Interval Configuration

| Motion State | GPS Interval | WiFi Interval | Accelerometer Interval | Description |
|-------------|-------------|---------------|----------------------|-------------|
| stationary | 5 min | 5 min | 5 sec | At home/office sedentary |
| walking | 30 sec | 2 min | 1 sec | Low-speed movement |
| running | 15 sec | 5 min | 500ms | High-frequency exercise, WiFi not needed |
| driving | 5 sec | Disabled | 2 sec | High-speed movement, frequent GPS updates |
| unknown | 1 min | 2 min | 1 sec | Default configuration |

### 13.3 Motion State Detection

- **Accelerometer**: Detects body movement
- **GPS Speed**: Solves the constant-speed driving/train problem
  - GPS speed > 20m/s (72km/h) -> Driving
  - GPS speed > 5m/s (18km/h) -> Driving/cycling
  - GPS speed > 1.5m/s (5.4km/h) -> Running/fast walking

### 13.4 Phone Pickup Detection

**Problem:** "Picking up the phone" triggers motion state changes, causing unnecessary GPS resampling

**Feature Differentiation:**

| Feature | Phone Pickup | Actual Movement |
|---------|-------------|-----------------|
| Accelerometer | Brief pulse + gravity direction change | Sustained changes |
| Gyroscope | Rapid rotation | No significant rotation |
| Step count | Does not increase | Increases |
| GPS displacement | None | Present |
| Duration | < 3 seconds | > 10 seconds |

**Implementation Key Points:** Distinguish "pick up and glance" vs "start moving"; phone pickup should not trigger GPS frequency adjustment

---

## 14. Geofence Feature Learning

> Source: context_awareness_design.md Section 2

### 14.1 Data Structure

```typescript
interface LearnedPlaceSignals {
  wifiSSIDs?: string[];            // Associated WiFi SSID list
  bluetoothDevices?: string[];     // Associated Bluetooth device MAC/names
  typicalTimes?: TimeRange[];      // Typical presence time periods
  lastSeen?: number;               // Last learning timestamp
  visitCount?: number;             // Visit count
}
```

### 14.2 Learning Trigger and Feature Matching

- **Learning:** Automatically learns current WiFi/Bluetooth when entering a geofence; notifies in chat window when learning new features for the first time; data persisted to `user_places.json`
- **Matching:** When WiFi connects, checks if it matches a known geofence; even with imprecise GPS, position can be determined via WiFi; supports multiple WiFi bindings to the same geofence

---

## 15. App Usage Record Learning

> Source: context_awareness_design.md Section 3
> Status: Limited — `ohos.permission.LOOK_AT_SCREEN_DATA` does not exist in the current SDK

**App Categories:**

| Category | Example Apps |
|----------|-------------|
| Social | WeChat, QQ, WhatsApp, Telegram, Discord |
| Work | Email, WPS, Teams, Zoom, Feishu, DingTalk |
| Entertainment | Douyin (TikTok), Kuaishou, Bilibili, YouTube, Netflix |
| Navigation | Amap, Baidu Maps, Google Maps |
| Shopping | Taobao, JD.com, Pinduoduo, Amazon |
| News | Toutiao, Zhihu, Twitter, Reddit |
| Health | Huawei Health, Keep |
| Music | NetEase Cloud Music, QQ Music, Spotify |
| Reading | WeRead, Kindle |
| Gaming | Various games |

**Learning Content:** Current foreground app, usage duration, usage time patterns, category usage frequency

**Alternative Approach:** Use `ForegroundAppPlugin` for foreground app detection (limited), record usage time, learn user's app usage habits at different locations/times

---

## 16. Silent Mode Enhancement

> Source: context_awareness_design.md Section 4

### 16.1 Key Information Extraction

```typescript
interface ConversationKeyInfo {
  times: string[];           // "tomorrow at 3pm", "next Monday"
  dates: string[];           // "March 15", "this weekend"
  locations: string[];       // "Starbucks", "downstairs from office"
  people: string[];          // "Old Wang", "Director Zhang"
  events: string[];          // "meeting", "dinner", "watch movie"
  plans: string[];           // "planning to buy a computer", "preparing for business trip"
  topics: string[];          // "discussing project progress", "talking about children's education"
}
```

> Partially implemented: SilentModeExtractor.ets supports regex extraction; v2.52.0 added LLM action item extraction -> automatic calendar event creation

### 16.2 Emotion/Mood Detection

```typescript
interface EmotionAnalysis {
  mood: 'happy' | 'sad' | 'angry' | 'neutral' | 'excited' | 'tired';
  activity: 'talking' | 'singing' | 'arguing' | 'laughing' | 'whispering';
  energy: 'high' | 'medium' | 'low';
  stress: number;  // 0-100
}
```

**Detection Methods:** Tone analysis (pitch, speech rate, volume), vocabulary sentiment analysis, sound features (laughter, sighing)

**Singing Detection:** Pitch stability, rhythm features, melody patterns, background music detection

> Partially implemented: EmotionAnalyzer.ets provides basic emotion analysis

---

## 17. Wearable Device Integration

> Source: context_awareness_design.md Section 5

**Problem:** HarmonyOS `sensor.SensorId.HEART_RATE` can only read the phone's own sensors, cannot directly read Huawei watch data

**Solutions:**

| Approach | Description | Status |
|----------|-------------|--------|
| **A: Health Kit API** | Read health data via `@ohos.health` | Partially implemented (WearablePlugin.ets) |
| **B: Sensor sync** | After Huawei Health app sync, `sensor.on(HEART_RATE)` may read data | Pending verification |

**Permission:** `ohos.permission.READ_HEALTH_DATA`

> Partially implemented: WearablePlugin.ets reads heart rate and step count data via Health Kit

---

## 18. Data Tray Specification

> Source: context_awareness_design.md Section 7

**Naming Convention:** Unified lowerCamelCase (`wifiSsid`, `gpsSpeed`, `heartRate`)

**Current Fields:**

| Key | TTL | Source | Description |
|-----|-----|--------|-------------|
| latitude | 2min | GPS | Latitude |
| longitude | 2min | GPS | Longitude |
| wifiSsid | 2min | WiFi | Currently connected WiFi |
| motionState | 30s | Accelerometer | Motion state |
| gpsSpeed | 2min | GPS | GPS speed |
| heartRate | 30s | Wearable device | Heart rate |
| stepCount | 5min | Pedometer | Step count |

**Implementation:** C++ `data_tray` module (`libdata_tray.so`), singleton pattern + mutex thread safety, TTL expiry + quality decay (linear interpolation)

---

## 19. Training Data Sync System (C++)

> Source: context_awareness_design.md Section 9

### 19.1 Architecture Overview

```
┌────────────────────────────────────────────┐
│           ArkTS Layer (thin wrapper)        │
│  TrainingDataSync.ets                      │
│  - Initialize configuration (endpoint,     │
│    deviceId)                               │
│  - Call NAPI interfaces                    │
│  - HTTP upload (HarmonyOS network API)     │
└──────────────────┬─────────────────────────┘
                   │ NAPI
┌──────────────────┴─────────────────────────┐
│           C++ Core Layer                    │
│  training_sync.cpp                         │
│  - Training data collection and buffering  │
│  - Data serialization (JSON)               │
│  - Batch management, TTL cleanup           │
│  - Statistics                              │
└────────────────────────────────────────────┘
```

### 19.2 C++ Data Structures

```cpp
enum class TrainingDataType {
    RULE_MATCH,          // Rule match record
    USER_FEEDBACK,       // User feedback
    STATE_TRANSITION,    // State transition
    GEOFENCE_FEATURE     // Geofence feature
};

struct TrainingRecord {
    std::string id;
    TrainingDataType type;
    int64_t timestamp;
    std::map<std::string, std::string> stringData;
    std::map<std::string, double> numericData;
    std::map<std::string, bool> boolData;
    bool synced;
};

struct SyncStats {
    int pendingCount;
    int syncedCount;
    int64_t lastSyncTime;
    int64_t totalBytes;
};
```

**Class Design:** `TrainingDataSync` singleton, `MAX_RECORDS=200`, `SYNC_INTERVAL=1h`

### 19.3 NAPI Interface

```typescript
interface TrainingSyncNapi {
    init(deviceId: string): void;
    recordRuleMatch(data: RuleMatchRecord): void;
    recordFeedback(data: UserFeedbackRecord): void;
    recordStateTransition(data: StateTransitionRecord): void;
    exportPending(): string;
    markSynced(ids: string[]): void;
    serialize(): string;
    deserialize(json: string): void;
    getStats(): { pending: number; synced: number; lastSync: number };
}
```

> The ArkTS wrapper layer (TrainingDataSync.ets) uses typed wrapper functions to call the native module, meeting ArkTS strict mode requirements

### 19.4 Data Flow

```
1. Data Generation:
   ContextAwarenessService -> C++ recordRuleMatch() / recordFeedback() / recordStateTransition()

2. Persistence (after each record):
   C++ serialize() -> ArkTS preferences.put()

3. Sync Trigger (scheduled 1h / manual):
   ArkTS -> C++ exportPending() -> JSON -> HTTP POST -> C++ markSynced() -> persist

4. Startup Recovery:
   ArkTS preferences.get() -> C++ deserialize()
```

### 19.5 Server-side Interface

**Server:** `server/training-server.js` (port 18790, same machine as OpenClaw Gateway 18789)

```
POST /training/upload    — Upload training data (JSONL)
GET  /training/stats     — View statistics
GET  /health             — Health check
```

**Data Storage:** `server/training-data/{deviceId}_{date}.jsonl`

**Privacy:** Sensitive fields are configurable for upload; stored locally by default; sync enabled only after user authorization; HTTPS encrypted

---

## 20. Feedback Learning System Detailed Design

> Source: context_awareness_design.md Section 10

**C++ Data Structures:**

```cpp
struct FeedbackRecord {
    std::string id;
    FeedbackType type;           // USEFUL / INACCURATE / DISMISS / ADJUST
    FeedbackContext context;     // Context at the time of feedback
    AdjustmentValue adjustment;  // User adjustment value
    int64_t timestamp;
};

struct RulePreference {
    std::string ruleId;
    double preferredHour;        // User preferred hour
    double preferredMinute;      // User preferred minute
    double hourAdjustment;       // Hour adjustment amount
    double confidence;           // Confidence
    int usefulCount;             // Useful count
    int inaccurateCount;         // Inaccurate count
    int adjustCount;             // Adjustment count
};
```

**Use Cases:**
1. **Bedtime reminder adjustment**: User feedback that 21:00 is too early, adjusted to 22:00
2. **Sedentary reminder frequency**: User feedback that it's too frequent, reduce reminder frequency
3. **Commute time**: User feedback that commute time is inaccurate, adjust trigger time

**UI Interaction:**

```
┌─────────────────────────────────┐
│ Context Intelligence Recommendation │
│ It's late, go to bed early         │
│ Rule: Bedtime reminder | Confidence: 65% │
├─────────────────────────────────┤
│ [👍 Useful] [👎 Inaccurate] [Adjust Time] │
└─────────────────────────────────┘

After clicking "Adjust Time":
┌─────────────────────────────────┐
│ Adjust Reminder Time              │
│ Current: 21:00                   │
│ Adjust to: [ 22 ] : [ 00 ]      │
│         [Confirm] [Cancel]       │
└─────────────────────────────────┘
```

> Partially implemented: FeedbackService.ets provides thumbs_up/thumbs_down/action_taken/dismissed/ignored feedback types, adjusting decision weights through LinUCB reward mechanism

---

## 21. Stream Deep RL — Online Reinforcement Learning Engine

### 21.1 Overview

The Context Intelligence Engine employs a three-layer progressive decision architecture. Stream Deep RL serves as Layer 2:

| Layer | Method | Responsibility | Status |
|-------|--------|---------------|--------|
| **Layer 1** | Rule Engine (Decision Tree + Soft Matching) | Generate candidate recommendation list from predefined rules | Completed |
| **Layer 2** | **Stream Deep RL (MLP Online Learning)** | Rerank candidates based on learned user preferences | **This Section** |
| **Layer 3** | LLM Fallback | Generate recommendations via LLM when no rules match | Completed |

**Core Idea**: Each time a user provides feedback on a recommendation card (thumbs up/down/ignore), the MLP performs a single-sample online gradient update (no replay buffer), progressively learning user preferences across different contexts. LinUCB is retained as a cold-start fallback.

**Technical Reference**: Elsayed et al. 2024 *"Streaming Deep Reinforcement Learning Finally Works"*

### 21.2 Data Flow Architecture

```
Sensor Data → DataTray → ContextSnapshot
                              │
                    ┌─────────┼──────────┐
                    │ Layer 1: Rule Engine│
                    │ (Decision Tree +   │
                    │  Soft Matching)     │
                    │ → Candidate List   │
                    └─────────┬──────────┘
                              │ candidates[]
                    ┌─────────┼──────────┐
                    │ Layer 2: Stream RL  │
                    │ (MLP Reranking)     │
                    │ hybrid_score =      │
                    │   rule_score ×      │
                    │   (1 + w × mlp)     │
                    └─────────┬──────────┘
                              │ reranked top-1
                    ┌─────────┼──────────┐
                    │ Push Recommendation │
                    └─────────┬──────────┘
                              │ User Feedback (reward)
                    ┌─────────┼──────────┐
                    │ Single-Sample       │
                    │ Online Training     │
                    │ MLP.update(ctx, r)  │
                    └─────────┴──────────┘
No match → Layer 3: LLM Fallback (unchanged)
```

### 21.3 Key Techniques

Based on Elsayed et al. 2024, six key techniques ensure stable MLP training in a purely online (no replay buffer) setting:

| # | Technique | Description | Implementation |
|---|-----------|-------------|----------------|
| 1 | **Layer Normalization** | Pre-activation LayerNorm on each hidden layer (non-learnable params) | `(x - mean(x)) / sqrt(var(x) + 1e-5)` |
| 2 | **Sparse Initialization** | 90% of weights initialized to 0, remainder use LeCun init | `U[-1/√fan_in, 1/√fan_in]`, mask rate 0.9 |
| 3 | **ObGD** | Overshooting-Bounded Gradient Descent, step-size limiting to prevent large destabilizing updates | `step = min(lr, lr / (κ × \|δ\| × ‖grad‖₁))` when product > 1 |
| 4 | **Observation Normalization** | Running mean/std normalization on input features | Welford's online algorithm for mean/var |
| 5 | **Reward Normalization** | Running mean/std normalization on rewards | Same as above |
| 6 | **No Replay Buffer** | Immediate single-sample gradient update upon each new observation | Single-sample SGD, zero extra memory overhead |

### 21.4 MLP Model Architecture (Per-Arm)

Each rule/action owns an independent StreamMLP:

```
Input (16-dim) → Linear(16, 64) → LayerNorm → LeakyReLU(α=0.01)
              → Linear(64, 32)  → LayerNorm → LeakyReLU(α=0.01)
              → Linear(32, 1)   // Predicted reward value
```

**Sparse Init**: 90% weights = 0, 10% weights ~ LeCun distribution.

#### 21.4.1 Feature Vector Definition (16-dim)

| Dim | Feature | Encoding | Range |
|-----|---------|----------|-------|
| 0-1 | hour | sin/cos cyclic encoding | [-1, 1] |
| 2-3 | dayOfWeek | sin/cos cyclic encoding | [-1, 1] |
| 4 | isWeekend | binary | {0, 1} |
| 5 | timeOfDay | enum mapping | dawn=0.1, morning=0.3, afternoon=0.5, evening=0.7, night=0.9 |
| 6 | batteryLevel | /100 normalized | [0, 1] |
| 7 | isCharging | binary | {0, 1} |
| 8-11 | motionState | one-hot | stationary, walking, running, driving |
| 12 | hasGeofence | binary | {0, 1} |
| 13 | wifiConnected | binary | {0, 1} |
| 14-15 | networkType | one-hot | wifi, cellular (none = both 0) |

#### 21.4.2 Resource Overhead Estimation

| Item | Value | Notes |
|------|-------|-------|
| Parameters per Arm | 3,169 | 16×64+64+64×32+32+32×1+1 |
| Memory per Arm | ~25 KB | 3169 × 8 bytes (double) |
| Total for 30 Arms | ~750 KB | Fully acceptable for on-device |
| Single forward pass | < 0.01 ms | Pure CPU matrix operations |
| Single backward pass | < 0.05 ms | Including gradient + ObGD |

#### 21.4.3 Feature Vector Extensibility

The feature dimension is designed to be extensible. When adding new features, only two changes are needed:

1. **Update `STREAM_FEAT_DIM` constant** (e.g., 16 → 20)
2. **Append new feature encoding at the end of `buildFeatures()`**

MLP layer sizes are template parameters (`DenseLayer<STREAM_FEAT_DIM, STREAM_H1>`) that automatically adapt to the dimension change — no manual network structure modification required.

**Model migration strategy**: After a dimension change, persisted weight matrices will have mismatched shapes (e.g., old 16×64 vs new 20×64). `importJson()` checks the dimension; on mismatch it skips the import, causing the MLP to re-initialize with sparse init and automatically fall back to LinUCB cold-start. The model recovers after a few rounds of user feedback.

**Candidate extension features**:

| Dim | Candidate Feature | Encoding |
|-----|-------------------|----------|
| 16 | Bluetooth connected device count | /10 normalized |
| 17 | Step activity level | steps in last 30 min / 1000 |
| 18 | Screen brightness | /255 normalized |
| 19 | Altitude / floor level | normalized |

### 21.5 Hybrid Scoring and Cold-Start Strategy

```
if arm.samples < 5:                      // Cold-start phase
    score = LinUCB.scoreArm(actionId, ctx)   // Use LinUCB fallback
elif arm.samples < 20:                    // Linear transition phase
    w = (samples - 5) / 15
    score = (1-w) * linucb_score + w * mlp_score
else:                                     // MLP-dominant phase
    score = mlp_score
```

**Hybrid scoring formula** (in RuleEngine's `evaluate()` sort stage):

```
ruleScore = confidence × priorityAdjustment

// Cold-start phase (samples < 5)
hybridScore = ruleScore  (or LinUCB fallback)

// Transition phase (5 ≤ samples < 20)
rlWeight = (samples - 5) / 15 × 0.3
normalizedMlp = tanh(mlp_score)              // Bound to [-1, 1]
hybridScore = ruleScore × (1 + rlWeight × normalizedMlp)

// MLP-dominant phase (samples ≥ 20)
hybridScore = ruleScore × (1 + 0.3 × tanh(mlp_score))
```

### 21.6 C++ Implementation Design

#### 21.6.1 Core Class Structure

```cpp
namespace context_engine {

constexpr int STREAM_FEAT_DIM = 16;       // Input feature dimension
constexpr int STREAM_H1 = 64;             // Hidden layer 1
constexpr int STREAM_H2 = 32;             // Hidden layer 2
constexpr double STREAM_LR = 0.01;        // Learning rate
constexpr double STREAM_KAPPA = 2.0;      // ObGD step-size bound
constexpr double STREAM_WEIGHT_DECAY = 1e-4;
constexpr double STREAM_LEAKY_ALPHA = 0.01;  // LeakyReLU negative slope
constexpr double SPARSE_RATIO = 0.9;      // Sparse init ratio
constexpr int STREAM_MIN_SAMPLES = 5;     // Cold-start minimum samples
constexpr int STREAM_RAMP_SAMPLES = 20;   // Transition end sample count

// Online statistics (Welford's algorithm)
struct RunningStats {
    std::array<double, STREAM_FEAT_DIM> mean;
    std::array<double, STREAM_FEAT_DIM> var;
    int count;
    void update(const double* x);
    void normalize(const double* x, double* out) const;
};

// Dense layer
template<int IN, int OUT>
struct DenseLayer {
    double W[OUT][IN];
    double b[OUT];
    void sparseInit();
    void forward(const double* in, double* out) const;
    static void layerNorm(double* x, int dim);
};

// Per-Arm StreamMLP
class StreamMLP {
public:
    StreamMLP();  // sparse init
    double predict(const double* features);
    void update(const double* features, double reward);
    std::string exportJson() const;
    void importJson(const std::string& json);
    int samples() const { return sampleCount_; }
private:
    DenseLayer<STREAM_FEAT_DIM, STREAM_H1> layer1_;
    DenseLayer<STREAM_H1, STREAM_H2> layer2_;
    DenseLayer<STREAM_H2, 1> output_;
    RunningStats inputStats_;
    double rewardMean_, rewardVar_;
    int rewardCount_, sampleCount_;
};

// Per-Arm manager
class StreamRLEngine {
public:
    double scoreArm(const std::string& actionId, const double* features);
    void trainArm(const std::string& actionId, const double* features, double reward);
    static std::array<double, STREAM_FEAT_DIM> buildFeatures(const ContextMap& ctx);
    int getArmSamples(const std::string& actionId) const;
    std::string exportJson() const;
    void importJson(const std::string& json);
private:
    std::unordered_map<std::string, StreamMLP> arms_;
    mutable std::mutex mu_;
};

}  // namespace context_engine
```

#### 21.6.2 Key Algorithm Implementations

**Sparse Initialization**:
```cpp
void sparseInit() {
    double limit = 1.0 / std::sqrt((double)IN);
    for (int o = 0; o < OUT; ++o)
        for (int i = 0; i < IN; ++i)
            W[o][i] = (rand01() >= SPARSE_RATIO) ? uniform(-limit, limit) : 0.0;
}
```

**ObGD Step-size Limiting**:
```cpp
double product = STREAM_KAPPA * std::abs(delta) * gradL1;
double effectiveLR = (product > 1.0) ? STREAM_LR / product : STREAM_LR;
// W -= effectiveLR * grad + weight_decay * W
```

**LayerNorm (non-learnable parameters)**:
```cpp
static void layerNorm(double* x, int dim) {
    double mean = 0, var = 0;
    for (int i = 0; i < dim; ++i) mean += x[i];
    mean /= dim;
    for (int i = 0; i < dim; ++i) var += (x[i]-mean)*(x[i]-mean);
    double invStd = 1.0 / std::sqrt(var/dim + 1e-5);
    for (int i = 0; i < dim; ++i) x[i] = (x[i] - mean) * invStd;
}
```

**Welford Online Statistics**:
```cpp
void RunningStats::update(const double* x) {
    count++;
    for (int i = 0; i < STREAM_FEAT_DIM; ++i) {
        double d = x[i] - mean[i];
        mean[i] += d / count;
        var[i] += d * (x[i] - mean[i]);  // M2 accumulator
    }
}
```

#### 21.6.3 RuleEngine Integration

In `evaluate()`, after deduplication and before sorting, inject hybrid scoring:

```cpp
auto feats = StreamRLEngine::buildFeatures(ctx);

auto hybridScore = [&](const MatchResult& r) -> double {
    double ruleScore = r.confidence * priorityMap[r.ruleId];
    int samples = streamRL_.getArmSamples(r.action.id);

    if (samples < STREAM_MIN_SAMPLES) {
        // Cold-start: LinUCB fallback
        auto ls = linucb_.scoreArm(r.action.id, ctx);
        if (ls.pulls < 5) return ruleScore;
        double w = std::min(1.0, ls.pulls / 20.0) * 0.2;
        return ruleScore * (1.0 + w * std::tanh(ls.exploit));
    }

    double mlpScore = streamRL_.scoreArm(r.action.id, feats.data());
    double rlWeight = (samples >= STREAM_RAMP_SAMPLES)
        ? 0.3
        : (double)(samples - STREAM_MIN_SAMPLES)
          / (STREAM_RAMP_SAMPLES - STREAM_MIN_SAMPLES) * 0.3;

    return ruleScore * (1.0 + rlWeight * std::tanh(mlpScore));
};
```

### 21.7 NAPI Bridge Interface

Three new NAPI functions exposed to ArkTS:

```typescript
// libcontext_engine/index.d.ts additions
export const trainStreamRL: (actionId: string, reward: number, contextJson: string) => void;
export const exportStreamRL: () => string;
export const importStreamRL: (json: string) => void;
```

Registered in `context_engine_napi.cpp`'s `Init()` function.

### 21.8 ArkTS Integration

#### 21.8.1 Feedback Chain

```
User thumbs up/down/ignore
  → FeedbackService.recordFeedback(actionId, reward)
    → ContextEngine.feedback(actionId, reward, snapshot)
      → nativeUpdateReward(...)        // MAB + LinUCB update (unchanged)
      → nativeTrainStreamRL(...)       // Stream RL online training (new)
      → persistStreamRL()             // JSON persistence to Preferences
```

#### 21.8.2 State Persistence

- **Save timing**: After each user feedback via `persistStreamRL()`
- **Restore timing**: During app startup `init()` from Preferences
- **Storage key**: `stream_rl_state`
- **Data format**: JSON (consistent with LinUCB persistence)

#### 21.8.3 ContextRecommendation Extension

Add `snapshot` field to `ContextRecommendation` interface:

```typescript
export interface ContextRecommendation {
    rule: ContextRule;
    action: UserAction;
    reason: string;
    exploreStateInfo?: string;
    snapshot?: ContextSnapshot;  // Context snapshot at recommendation time (for Stream RL training)
}
```

Set `rec.snapshot = snapshot` in `evaluateAndDeliver()` to ensure FeedbackService can pass context to Stream RL training.

### 21.9 File Manifest and Implementation Order

#### File Operations

| File | Operation | Description |
|------|-----------|-------------|
| `entry/src/main/cpp/context_engine/stream_mlp.h` | **New** | StreamMLP + StreamRLEngine class definitions |
| `entry/src/main/cpp/context_engine/stream_mlp.cpp` | **New** | Forward/backward propagation, ObGD, LayerNorm, serialization |
| `entry/src/main/cpp/context_engine/CMakeLists.txt` | Modify | Add `stream_mlp.cpp` to build sources |
| `entry/src/main/cpp/context_engine/context_engine.h` | Modify | Add `StreamRLEngine` member to RuleEngine |
| `entry/src/main/cpp/context_engine/rule_engine.cpp` | Modify | Hybrid scoring logic in `evaluate()` |
| `entry/src/main/cpp/context_engine/context_engine_napi.cpp` | Modify | Add 3 new NAPI functions |
| `entry/src/main/cpp/types/libcontext_engine/index.d.ts` | Modify | Add TypeScript type declarations |
| `entry/src/main/ets/service/context/ContextEngine.ets` | Modify | NAPI wrappers + persistence |
| `entry/src/main/ets/service/context/ContextAwarenessService.ets` | Modify | Add snapshot to ContextRecommendation |
| `entry/src/main/ets/service/context/FeedbackService.ets` | Modify | Pass snapshot to feedback |
| `tests/context_ai/unit/test_stream_mlp.js` | **New** | Stream MLP unit tests |

#### Implementation Order

| Phase | Steps | Content |
|-------|-------|---------|
| Phase 1 | Step 1-2 | C++ StreamMLP core implementation + CMake |
| Phase 2 | Step 3 | Integrate into RuleEngine evaluate() |
| Phase 3 | Step 4 | NAPI bridge (3 new functions) |
| Phase 4 | Step 5-7 | ArkTS layer integration + type declarations |
| Phase 5 | Step 6 | Fix feedback chain (snapshot passing) |
| Phase 6 | Step 8 | Unit tests |

### 21.10 Test Plan

| # | Test Case | Expected Result |
|---|-----------|-----------------|
| 1 | Forward pass (zero input) | All-zero input → output near 0 (sparse init) |
| 2 | Single-sample training | Train (ctx, +1.0) → predict(ctx) should increase |
| 3 | Multi-sample convergence | Train same context 50× with reward=1.0 → predict approaches 1.0 |
| 4 | Context discrimination | Train positive reward for morning, negative for evening → model differentiates |
| 5 | ObGD step-size limiting | Extreme reward (e.g., 1000) does not cause weight explosion |
| 6 | Cold-start fallback | samples < 5 → hybrid score equals pure rule score or LinUCB fallback |
| 7 | Serialization/deserialization | export → import → predict yields identical results |
| 8 | Observation normalization | Input features of different scales are correctly normalized |

---

## 22. Recommendation Action Execution System

### 22.1 Overview

Previously, when a user tapped "useful" (thumbs up) on a recommendation card, the system only recorded feedback and showed a generic toast message. The Action Execution System bridges the gap between **recommendation acceptance** and **actual system capability execution**.

**Design Goal:** When a user accepts a recommendation, the system should automatically execute the recommended action (e.g., read calendar events, open an app, switch a mode) and display the result in the chat window.

**Data Flow:**

```
User taps "有用" on recommendation card
    → NodeRuntime.handleA2UIAction(feedback='accept')
        → FeedbackService.onActionTaken(ruleId)       // existing reward path
        → ActionExecutor.execute(cachedRecommendation.action)  // NEW
            → CalendarPlugin.getUpcomingEvents()       // for calendar actions
            → CalendarPlugin.findConflicts()
            → CalendarPlugin.formatEventsMarkdown()
        → dispatchChatEvent('assistant', result.message)  // show in chat
```

### 22.2 ActionExecutor Design

**File:** `entry/src/main/ets/service/context/ActionExecutor.ets`

The `ActionExecutor` class acts as a router that dispatches actions by `type` to the appropriate system capability handler.

**ActionResult Interface:**

```typescript
export interface ActionResult {
  success: boolean;
  message: string;      // Markdown text for chat window display
  actionType: string;   // For telemetry and UI routing
}
```

**Routing Table:**

| action.type | Handler | Output |
|-------------|---------|--------|
| `show_info` | → `executeShowInfo()` → routes by `target`/`params.category` | Calendar info, generic info |
| `open_app` | Direct response | "🚀 正在打开 {target}..." |
| `set_mode` | Direct response | "⚙️ 已切换到 {target}" |
| `show_notification` | Direct response | "🔔 {params.info}" |
| (default) | Generic acknowledgment | "✅ 动作 \"{type}\" 已记录" |

**show_info Sub-routing:**

| Condition | Handler |
|-----------|---------|
| `target` contains "calendar" OR `params.category === 'calendar'` | `executeCalendarInfo()` |
| Otherwise | Generic info display |

**Error Handling:** All execution is wrapped in try-catch. On failure, returns `{ success: false, message: "执行失败: {error}" }`.

### 22.3 CalendarPlugin Extension

**File:** `entry/src/main/ets/service/context/plugins/CalendarPlugin.ets`

Three new public methods were added to the existing `CalendarPlugin`:

**1. getUpcomingEvents(hoursAhead?: number): Promise\<EventInfo[]\>**

Returns calendar events within the specified look-ahead window (default 8 hours). Uses the existing `calendarManager.getEvents()` API with a query filter for `startTime` in range `[now, now + hoursAhead * 3600000]`.

**2. findConflicts(events: EventInfo[]): EventConflict[]**

Detects overlapping event pairs using pairwise comparison:

```
For each pair (i, j) where i < j:
  overlapStart = max(events[i].startTime, events[j].startTime)
  overlapEnd   = min(events[i].endTime,   events[j].endTime)
  if overlapStart < overlapEnd → conflict found
    overlapMinutes = round((overlapEnd - overlapStart) / 60000)
```

**EventConflict interface:**

```typescript
export interface EventConflict {
  event1: EventInfo;
  event2: EventInfo;
  overlapMinutes: number;
}
```

**3. formatEventsMarkdown(events: EventInfo[], conflicts?: EventConflict[]): string**

Formats events into a human-readable Markdown string for chat display:

- Empty list → `"📅 接下来没有日程安排"`
- Non-empty → Header with count + numbered event list with time/location + optional conflict warnings

Example output:
```
📅 **接下来有 2 个日程**

1. **早会**
   🕐 09:00 - 10:00 📍 A101
2. **项目评审**
   🕐 11:00 - 12:00 📍 B201

⚠️ **发现 1 个时间冲突：**
   - "会议A" 与 "会议B" 重叠 30 分钟
```

### 22.4 NodeRuntime Integration

**File:** `entry/src/main/ets/service/gateway/NodeRuntime.ets`

**Modified: `handleA2UIAction()` accept branch**

After the existing `fbService.onActionTaken(ruleId)` call, the system now:
1. Looks up the cached recommendation by `ruleId`
2. If found and has an `action`, calls `ActionExecutor.execute(action)`
3. Dispatches the result message as an assistant chat event via `dispatchChatEvent()`

```typescript
// In handleA2UIAction(), feedback === 'accept' branch:
let cachedRec = this._activeRecommendations.get(ruleId);
if (cachedRec?.action) {
  await this.executeRecommendedAction(cachedRec.action);
}
```

**New method: `executeRecommendedAction(action)`**

Lazy-initializes the `ActionExecutor` (fetching `CalendarPlugin` from `ContextAwarenessService`) and executes the action. On success, dispatches the result message to the chat window.

### 22.5 Active Recommendation Cache

**File:** `entry/src/main/ets/service/gateway/NodeRuntime.ets`

A `Map<string, ContextRecommendation>` stores active recommendations keyed by `rule.id`.

**Lifecycle:**
- **Set:** When the recommendation listener fires and an A2UI card is pushed to the WebView
- **Expire:** Each entry has a 5-minute timeout (`setTimeout(() => delete, 5 * 60 * 1000)`) aligned with the FeedbackService card lifecycle
- **Consumed:** When the user accepts the recommendation and the action is executed

This cache ensures that when the user taps "useful" on a card, the original recommendation's `action` object is available for execution, even though the A2UI only carries serialized display data.

---

## 23. Stream Deep RL UI Display

### 23.1 Overview

The Stream Deep RL engine (Section 21) learns from user feedback to improve recommendation quality over time. However, this learning process was invisible to users. The RL UI Display feature makes the learning process transparent through three touchpoints:

1. **Recommendation Cards** — RL learning phase badge (探索中/学习中/已学习)
2. **Settings Page** — RL statistics panel with active models, sample counts, top arms
3. **Explore Mode** — RL phase info in explore state display

### 23.2 New NAPI Functions

**C++ Layer:** `entry/src/main/cpp/context_engine/stream_mlp.h/.cpp`

Added `getSummaryJson()` to `StreamRLEngine`:

```cpp
std::string StreamRLEngine::getSummaryJson() const {
    // Thread-safe (mutex-locked)
    // Returns: { "totalArms": N, "totalSamples": N,
    //            "arms": [{ "id": "...", "samples": N, "avgReward": X }, ...] }
}
```

Also added `avgReward()` public accessor to `StreamMLP` class to expose per-arm average reward.

**NAPI Bridge:** `entry/src/main/cpp/context_engine/context_engine_napi.cpp`

| Function | Signature | Description |
|----------|-----------|-------------|
| `GetStreamRLStats` | `() → string` | Returns JSON summary of all RL arms |
| `GetStreamRLArmSamples` | `(actionId: string) → number` | Returns sample count for a specific arm |

**TypeScript Declarations:** `entry/src/main/cpp/types/libcontext_engine/index.d.ts`

```typescript
export const getStreamRLStats: () => string;
export const getStreamRLArmSamples: (actionId: string) => number;
```

**ArkTS Wrapper:** `entry/src/main/ets/service/context/ContextEngine.ets`

Public methods `getStreamRLStats()` and `getStreamRLArmSamples(actionId)` added to `ContextEngineService`, with error handling that returns safe defaults (`"{}"` / `0`) if the native call fails.

### 23.3 Recommendation Card RL Labels

**File:** `entry/src/main/ets/service/gateway/NodeRuntime.ets`

When building A2UI JSON for recommendation cards (`buildContextRecommendationA2UI()` and `buildExploreStateA2UI()`), an RL label is appended to the card metadata.

**Label Logic (`getStreamRLLabel`):**

| Condition | Label | Meaning |
|-----------|-------|---------|
| `armSamples < 5` | `探索中` | Cold start — not enough data, exploring |
| `5 ≤ armSamples < 20` | `学习中 (N次)` | Active learning — accumulating feedback |
| `armSamples ≥ 20` | `已学习 (N次)` | Converged — stable prediction model |

The label appears as a `🧠` badge in the A2UI card metadata, giving users a sense of how well-trained the system is for each recommendation type.

### 23.4 ContextSettingsPage Stats Panel

**File:** `entry/src/main/ets/pages/ContextSettingsPage.ets`

A new "Stream Deep RL 学习状态" panel is added below the existing feedback statistics section.

**Displayed Information:**

| Field | Source | Description |
|-------|--------|-------------|
| Active models count | `rlStats.totalArms` | Number of distinct action types with RL models |
| Total training samples | `rlStats.totalSamples` | Cumulative feedback events processed |
| RL Phase | Derived from `totalSamples` | 冷启动 (<10) / 学习中 (10-49) / 已收敛 (≥50) |
| Top-5 arms table | `rlStats.arms` sorted by samples | Shows arm ID, sample count, average reward |

**Data Loading:** `refreshStreamRLStats()` is called during `aboutToAppear()` lifecycle. It calls `ContextEngineService.getStreamRLStats()`, parses the JSON, sorts arms by sample count descending, and takes the top 5.

### 23.5 Explore Mode RL Info

**File:** `entry/src/main/ets/service/context/ContextAwarenessService.ets`

In `buildExploreStateInfo()`, after the existing context state lines (time, location, sensors, rules, etc.), the system appends a global RL summary line:

```
🧠 RL: 学习中 (5模型, 42样本)
```

**Phase Thresholds:**

| totalSamples | Phase |
|-------------|-------|
| < 10 | 冷启动 |
| 10 – 49 | 学习中 |
| ≥ 50 | 已收敛 |

This gives the Explore mode panel a quick view of the overall RL engine maturity.

---

## 24. State Transition Modeling and Feature Expansion

The same current state can warrant very different recommendations depending on what state the user came from. For example, "at home after returning from the office" vs "at home after returning from the hospital" should trigger different suggestions. This section describes the state transition modeling system that captures this temporal context.

### 24.1 7-Dimension State Model

Every user situation can be described along 7 orthogonal dimensions:

| Dimension | Code | Values | Sensor Source |
|-----------|------|--------|---------------|
| WHERE | Location/Place | home, office, gym, cafe, mall, hospital, airport, school, park, transit, unknown | Geofence, WiFi fingerprint, GPS |
| DOING | Activity | stationary, walking, running, driving, transit, cycling, sleeping | Motion detector, step counter |
| WHEN | Time context | dawn, morning, afternoon, evening, night × weekday/weekend | System clock |
| BODY | Physical state | resting, normal, exercise, stressed | Heart rate, wearable |
| SCHEDULE | Calendar context | free, has_upcoming, in_meeting, post_meeting | Calendar plugin |
| DEVICE | Device state | charging, low_battery, connected_wifi, cellular_only | Battery, network |
| ENVIRONMENT | Ambient | quiet, noisy, outdoor, indoor | Ambient sound plugin |

These 7 dimensions define the state space. A "state" is a specific combination of values across these dimensions.

### 24.2 Scenario Enumeration (70 Scenarios)

Using the 7-dimension model, we enumerate 70 representative scenarios grouped by life domain:

**Work (17 scenarios)**
1. Morning commute (home→office, walking/driving)
2. Arrive at office (geofence enter)
3. Pre-meeting preparation (calendar: upcoming meeting)
4. In meeting (calendar: in_meeting, stationary)
5. Post-meeting summary (calendar: post_meeting)
6. Lunch break start (office, noon, walking)
7. Return from lunch (walking→stationary at office)
8. Afternoon focus time (office, afternoon, stationary)
9. Leave office (office geofence exit, evening)
10. Evening commute home (office→home, driving/transit)
11. Work from home (home, weekday, stationary, wifi)
12. Client visit (unknown location, weekday, walking)
13. Business trip departure (airport, has_upcoming)
14. Conference/event (unknown, weekday, stationary)
15. Late night work (office, night, stationary)
16. Weekend overtime (office, weekend)
17. Deadline crunch (office, evening+, stationary)

**Life (23 scenarios)**
18. Wake up at home (home, dawn/morning, stationary→walking)
19. Morning exercise (gym/park, morning, running/walking)
20. Breakfast preparation (home, morning, stationary)
21. Grocery shopping (mall, walking)
22. Cooking at home (home, evening, stationary)
23. Dinner out (restaurant/cafe, evening, stationary)
24. Evening relaxation (home, evening, stationary)
25. Bedtime routine (home, night, stationary)
26. Weekend morning (home, weekend, morning)
27. Weekend outing (park/mall, weekend, walking)
28. Hospital visit (hospital, stationary)
29. Post-hospital return home (hospital→home)
30. Family gathering (home, weekend, evening)
31. Home maintenance (home, weekend, stationary)
32. Pet walking (park, walking, short duration)
33. Childcare (home/school, walking/stationary)
34. Hair salon/spa (unknown, stationary, long duration)
35. Bank/government office (unknown, weekday, stationary)
36. Moving/relocating (transit, long duration)
37. Home delivery arrival (home, stationary)
38. Late night return home (home, night, walking→stationary)
39. Nap time (home, afternoon, stationary→sleeping)
40. Morning coffee ritual (cafe, morning, stationary)

**Study (9 scenarios)**
41. Library study (school/library, stationary, long duration)
42. Online course (home, stationary, wifi)
43. Group study (cafe/school, stationary)
44. Exam preparation (home/library, evening+night, stationary)
45. Class attendance (school, weekday, stationary)
46. Research fieldwork (outdoor, walking, variable)
47. Language practice commute (transit, walking)
48. Workshop/seminar (unknown, stationary)
49. Reading time (home, stationary, quiet)

**Entertainment (14 scenarios)**
50. Gym workout (gym, running/walking)
51. Swimming (gym, stationary→walking)
52. Outdoor jogging (park, running)
53. Movie theater (unknown, stationary, quiet)
54. Concert/event (unknown, stationary, noisy)
55. Gaming at home (home, stationary, night/evening)
56. Social media browsing (home, stationary)
57. Music listening (any, any)
58. Photography walk (outdoor, walking, weekend)
59. Hiking (outdoor, walking, long duration)
60. Cycling (outdoor, cycling)
61. Yoga/meditation (home/gym, stationary, quiet)
62. Bar/nightclub (unknown, night, noisy)
63. Sports game spectating (unknown, stationary)

**Transition (7 scenarios)**
64. Home→Office transition (commute)
65. Office→Home transition (return commute)
66. Home→Gym transition
67. Location→Hospital transition
68. Any→Airport transition (travel)
69. Home→School transition
70. Unknown→Home return (late arrival)

### 24.3 Input Dimension Coverage Analysis

We analyze how many input features are needed to distinguish these 70 scenarios:

| Tier | Dimensions | Cumulative Dim Count | Coverage | What it adds |
|------|-----------|---------------------|----------|-------------|
| **Tier 1** (Essential) | hour_sin, hour_cos, dayOfWeek_sin, dayOfWeek_cos, isWeekend, timeOfDay | 6 | ~80% | Time context separates morning/afternoon/evening/night × weekday/weekend |
| **Tier 2** (Motion+Battery) | batteryLevel, isCharging, motion_stationary, motion_walking, motion_running, motion_driving, hasGeofence | 13 | ~93% | Activity and location awareness |
| **Tier 3** (Connectivity) | wifiConnected, networkType_wifi, networkType_cellular | 16 | ~97% | Indoor/outdoor and connectivity context |
| **Tier 4** (Transition) | prev_geofence, geofence_changed, prev_motion (2), transition_duration, time_in_current, transitions_count, is_routine, direction | 25 | ~100% | Temporal transitions complete the picture |

**25-Dimension Feature Vector Mapping:**

| Index | Feature | Source | Encoding | Range |
|-------|---------|--------|----------|-------|
| 0 | hour_sin | System clock | sin(2π·h/24) | [-1, 1] |
| 1 | hour_cos | System clock | cos(2π·h/24) | [-1, 1] |
| 2 | dayOfWeek_sin | System clock | sin(2π·d/7) | [-1, 1] |
| 3 | dayOfWeek_cos | System clock | cos(2π·d/7) | [-1, 1] |
| 4 | isWeekend | System clock | binary | {0, 1} |
| 5 | timeOfDay | System clock | ordinal | [0.1, 0.9] |
| 6 | batteryLevel | Battery API | level/100 | [0, 1] |
| 7 | isCharging | Battery API | binary | {0, 1} |
| 8 | motion_stationary | Motion detector | one-hot | {0, 1} |
| 9 | motion_walking | Motion detector | one-hot | {0, 1} |
| 10 | motion_running | Motion detector | one-hot | {0, 1} |
| 11 | motion_driving | Motion detector | one-hot | {0, 1} |
| 12 | hasGeofence | Geofence service | binary | {0, 1} |
| 13 | wifiConnected | WiFi API | binary | {0, 1} |
| 14 | networkType_wifi | Network API | one-hot | {0, 1} |
| 15 | networkType_cellular | Network API | one-hot | {0, 1} |
| 16 | prev_geofence | StateTransitionTracker | binary (had prev?) | {0, 1} |
| 17 | geofence_changed | StateTransitionTracker | binary | {0, 1} |
| 18 | prev_motion_stationary | StateTransitionTracker | 2-hot | {0, 1} |
| 19 | prev_motion_moving | StateTransitionTracker | 2-hot | {0, 1} |
| 20 | transition_duration_min | StateTransitionTracker | min(dur/120, 1) | [0, 1] |
| 21 | time_in_current_min | StateTransitionTracker | min(dur/240, 1) | [0, 1] |
| 22 | transitions_last_hour | StateTransitionTracker | min(count/10, 1) | [0, 1] |
| 23 | is_routine_transition | StateTransitionTracker | binary | {0, 1} |
| 24 | transition_direction | StateTransitionTracker | (dir+1)/2 | [0, 1] |

### 24.4 State Transition Features (9 Dimensions)

The 9 transition features (indices 16–24) are organized into three groups:

**Group A: Previous State (4 dimensions)**

| Feature | Description | Value |
|---------|-------------|-------|
| `prev_geofence` | Whether the user was in a geofence before the transition | 0 (no) or 1 (yes) |
| `geofence_changed` | Whether the geofence changed during the transition | 0 or 1 |
| `prev_motionState` (×2) | 2-hot encoding of previous motion: was_stationary / was_moving | {0,1} each |

**Group B: Temporal Interval (3 dimensions)**

| Feature | Description | Encoding |
|---------|-------------|----------|
| `transition_duration_min` | How long the transition took | min(minutes/120, 1.0) |
| `time_in_current_state_min` | How long the user has been in the current state | min(minutes/240, 1.0) |
| `transitions_last_hour` | Number of state changes in the past hour | min(count/10, 1.0) |

**Group C: Sequence Pattern (2 dimensions)**

| Feature | Description | Encoding |
|---------|-------------|----------|
| `is_routine_transition` | Whether this exact transition path has been seen 3+ times at this time | 0 or 1 |
| `transition_direction` | Semantic direction: work→rest (-1), same-type (0), rest→work (+1) | (dir+1)/2 |

**Value Examples:**

| Scenario | Key Transition Features | Recommendation Impact |
|----------|------------------------|----------------------|
| Home → Office (morning commute) | prev_geofence=1, geofence_changed=1, direction=1.0, is_routine=1 | Show commute ETA, meeting prep |
| Office → Home (evening) | prev_geofence=1, geofence_changed=1, direction=0.0, is_routine=1 | Show traffic, dinner suggestions |
| Hospital → Home | prev_geofence=1, geofence_changed=1, direction=0.0, is_routine=0 | Show health tips, rest reminders |
| Stationary → Walking (at office) | geofence_changed=0, prev_motion_stationary=1, time_in_current=low | Maybe lunch break — suggest restaurants |
| Long stationary at home (night) | time_in_current=high, transitions_last_hour=low | Suggest bedtime routine |

### 24.5 StateTransitionTracker (C++)

```cpp
// File: entry/src/main/cpp/context_engine/state_transition.h

namespace context_engine {

struct StateSnapshot {
    std::string geofence;         // geofence ID or empty
    std::string geofenceLabel;    // human-readable name
    std::string geofenceIcon;     // emoji icon
    std::string motionState;      // stationary/walking/running/driving
    int64_t timestamp;            // ms since epoch
};

struct TransitionInfo {
    StateSnapshot prev;
    StateSnapshot current;
    double durationMin;           // transition duration in minutes
    double timeInCurrentMin;      // time spent in current state
    int transitionsLastHour;      // state changes in last 60 min
    bool isRoutine;               // seen this route 3+ times
    int direction;                // -1=work→rest, 0=same, +1=rest→work
    std::string patternLabel;     // e.g. "常规通勤 · 周一早晨"
};

class StateTransitionTracker {
public:
    bool update(const ContextMap& ctx);           // returns true if state changed
    void injectFeatures(ContextMap& ctx) const;   // inject 9 transition keys
    TransitionInfo getTransitionInfo() const;
    std::string getTransitionJson() const;        // JSON for NAPI → UI
    std::string exportJson() const;               // persistence
    void importJson(const std::string& json);
private:
    StateSnapshot current_, previous_;
    std::vector<int64_t> transitionTimestamps_;
    bool hasTransition_ = false;
    std::unordered_map<std::string, int> routeCounts_;
    static constexpr int ROUTINE_THRESHOLD = 3;
    bool detectStateChange(const ContextMap& ctx) const;
    int classifyDirection(const std::string& from, const std::string& to) const;
};

}  // namespace context_engine
```

**Key algorithms:**

1. **State Change Detection**: Compares current geofence and motionState against stored `current_` snapshot. A change in either triggers a transition.

2. **Routine Detection**: Maintains a counter map with key `"fromGeo|toGeo|hourBucket"` where hourBucket = hour/4 (0–5). When count >= `ROUTINE_THRESHOLD` (3), the transition is classified as routine.

3. **Direction Classification**:
   - "Rest" locations: home, cafe, gym, park
   - "Work" locations: office, school, hospital
   - Direction = +1 (rest→work), -1 (work→rest), 0 (same category or unknown)

4. **Geofence Icons**: home→🏠, office→🏢, gym→💪, cafe→☕, mall→🛍️, hospital→🏥, airport→✈️, school→🏫, park→🌳, transit→🚌

### 24.6 Network Architecture Update (25→128→64→1)

With the input dimension expanding from 16 to 25, the hidden layer sizes are proportionally increased:

| Layer | Old | New | Parameters |
|-------|-----|-----|-----------|
| Input → H1 | 16→64 | 25→128 | 25×128 + 128 = 3,328 |
| H1 → H2 | 64→32 | 128→64 | 128×64 + 64 = 8,256 |
| H2 → Output | 32→1 | 64→1 | 64×1 + 1 = 65 |
| **Total** | **3,169** | **11,649** | ~3.7× increase |

The architecture remains:
- **Sparse Initialization**: 90% zero weights (LeCun scaling for non-zero)
- **Layer Normalization**: Non-learnable, applied after each linear layer
- **LeakyReLU**: α = 0.01
- **ObGD**: Overshooting-Bounded Gradient Descent for stable online learning
- **Welford Normalization**: Online input/reward normalization

The ~3.7× parameter increase is acceptable for on-device inference (< 0.1ms per prediction) and provides sufficient capacity to learn the 9 additional transition features.

### 24.7 Recommendation Card Transition Path Bar

When a state transition is detected, recommendation cards display a transition path bar at the top:

**Visual Design:**
```
┌─────────────────────────────────────────┐
│ 🏠 家 ── 45min ──▶ 🏢 办公室           │  ← Path bar (green, bold)
│ 常规通勤 · 周一早晨                      │  ← Pattern label (gray, small)
├─────────────────────────────────────────┤
│ 🔍 检测到状态变化                        │  ← Existing state info
│ 位置: 办公室 | 运动: 静止                │
├─────────────────────────────────────────┤
│ ── 💡 推荐操作 ──                        │
│ [🥇 查看日程安排 (92%)]                  │
│ [🥈 打开通勤路线 (85%)]                  │
│ [🙈 忽略]                               │
└─────────────────────────────────────────┘
```

**A2UI JSON Structure:**
```json
{
  "type": "text",
  "text": "🏠 家 ── 45min ──▶ 🏢 办公室",
  "style": {"fontSize": 16, "fontWeight": "bold", "color": "#4CAF50"}
}
```

The path bar is conditionally shown only when `getTransitionInfo()` returns valid transition data with both `from` and `to` locations.

### 24.8 Future Roadmap

| Priority | Feature | Description |
|----------|---------|-------------|
| **P1** | Chat Status Bar | Lightweight status bar at top/bottom of chat interface showing current location + time in state |
| **P2** | Settings Page Timeline | Vertical timeline on ContextSettingsPage showing today's state transitions |
| **P1** | Sliding Window (N-step) | Track patterns like "3 meetings in last 2 hours" using a sliding window over recent transitions |
| **P2** | RNN/Transformer | Cloud-side full-sequence understanding for complex multi-step pattern recognition |

---

## 25. 7-Tuple Physical State & Scenario Intelligence

This section describes the 7-tuple physical state model and scenario-based intelligence system that builds on top of the state transition features (Section 24). While Section 24 introduced the concept of 7 state dimensions and transition tracking, this section implements a concrete **physical state classification layer** and a **deterministic scenario chain matcher** that together form a parallel recommendation pipeline alongside the existing rule engine.

**Core architecture flow**: Physical sensors → State (7-tuple) → State chains → Scenario → Scenario + Digital data → Recommendations → Action execution

### 25.1 Architecture Overview

The system introduces two new components:

1. **PhysicalStateBuilder** (ArkTS): Reads raw sensor data from DataTray and classifies it into a discrete 7-tuple `PhysicalState`
2. **ScenarioMatcher** (ArkTS): Matches the current `PhysicalState` against 72 predefined scenario chains to identify the user's current life situation

These components run in parallel with the existing C++ rule engine:

```
┌─────────────────────────────────────────────────────────┐
│                  periodicEvaluate()                      │
│                                                          │
│  DataTray (raw sensors)                                  │
│       │                                                  │
│       ├──▶ PhysicalStateBuilder.build()                  │
│       │         │                                        │
│       │         ▼                                        │
│       │    PhysicalState (7-tuple)                       │
│       │         │                                        │
│       │         ├──▶ ScenarioMatcher.match()             │
│       │         │         │                              │
│       │         │         ▼                              │
│       │         │    ScenarioMatchResult[]               │
│       │         │                                        │
│       │         └──▶ Inject ps_* into DataTray           │
│       │                     │                            │
│       └──▶ tray.getSnapshot() ──▶ C++ evaluate()        │
│                                       │                  │
│                                       ▼                  │
│                              MatchResult[] (rules)       │
│                                       │                  │
│                              mergeResults → deliver      │
└─────────────────────────────────────────────────────────┘
```

### 25.2 7-Tuple Physical State Model

Every user situation is described by 7 orthogonal physical dimensions:

| # | Dimension | Type | Values | Count |
|---|-----------|------|--------|-------|
| 1 | **Time** | `TimeSlot` | sleeping, dawn, morning, forenoon, lunch, afternoon, evening, night, late_night | 9 |
| 2 | **Location** | `LocationCategory` | home, work, commute, restaurant, gym, transit_hub, shopping, outdoor, cafe, unknown | 10 |
| 3 | **Motion** | `MotionCategory` | stationary, walking, running, cycling, driving, transit, unknown | 7 |
| 4 | **Phone** | `PhoneCategory` | in_use, on_desk, in_pocket, face_down, charging, unknown | 6 |
| 5 | **Light** | `LightCategory` | dark, dim, normal, bright | 4 |
| 6 | **Sound** | `SoundCategory` | silent, quiet, normal, noisy, unknown | 5 |
| 7 | **DayType** | `DayType` | workday, weekend, holiday | 3 |

**State space**: 9 × 10 × 7 × 6 × 4 × 5 × 3 = **226,800** theoretical combinations. Due to physical impossibilities (e.g., gym + driving, bright + sleeping), effective combinations are approximately **300–600**.

**Comparison with Section 24's 7 dimensions**:
- Section 24's dimensions (WHERE, DOING, WHEN, BODY, SCHEDULE, DEVICE, ENVIRONMENT) are conceptual categories mixing physical and digital signals
- This section's 7-tuple is purely physical-world state that can be directly measured from sensors
- Digital-world signals (calendar, battery, app usage) are handled as `digitalConditions` on scenario steps

### 25.3 PhysicalStateBuilder

**File**: `entry/src/main/ets/service/context/PhysicalStateBuilder.ets`

Reads DataTray sensor data and classifies each dimension:

| Dimension | DataTray Keys | Classification Logic |
|-----------|--------------|---------------------|
| Time | `hour` (system) | 0:00–5:00→sleeping, 5:00–7:00→dawn, 7:00–9:00→morning, 9:00–11:30→forenoon, 11:30–13:30→lunch, 13:30–17:00→afternoon, 17:00–19:30→evening, 19:30–22:00→night, 22:00–24:00→late_night |
| Location | `wifiGeofence`, `motionState`, `gpsSpeed` | WiFi geofence mapping (home/work/gym/restaurant/transit/shopping/cafe) → location; no geofence + motion=driving/transit → commute; no WiFi + GPS → outdoor; else → unknown |
| Motion | `motionState`, `transportMode` | Direct mapping; `transportMode=transit` → transit; `transportMode=cycling` → cycling |
| Phone | `isCharging`, `ambient_brightness`, `proximity`, `screen_on`, `phone_posture` | Priority: charging > pocket (dark+proximity) > face_down > in_use (screen_on) > on_desk (flat) > unknown |
| Light | `ambient_brightness` (lux) | <5→dark, 5–50→dim, 50–500→normal, >500→bright |
| Sound | `noise_level` (dB) | <25→silent, 25–40→quiet, 40–55→normal, >55→noisy |
| DayType | `dayOfWeek`, calendar holiday events | Holiday calendar event → holiday; Saturday/Sunday → weekend; else → workday |

**Static helpers**:
- `fingerprint(ps)` → `"time|location|motion|phone|light|sound|dayType"` (for deduplication)
- `equals(a, b)` → boolean comparison of all 7 dimensions

### 25.4 Scenario Chain Matching

**File**: `entry/src/main/ets/service/context/ScenarioMatcher.ets`

A scenario is a multi-step **state chain** — a sequence of expected PhysicalState patterns that describe a life situation progression. The ScenarioMatcher performs deterministic pattern matching (not RL) to identify which scenarios are currently active.

**Scenario definition** (JSON):
```json
{
  "id": "S07",
  "name": "早晨驾车通勤",
  "nameEn": "Morning Driving Commute",
  "category": "commute",
  "steps": [
    {
      "time": "morning",
      "location": "home",
      "motion": "walking",
      "phone": "in_pocket",
      "light": "normal",
      "sound": "quiet",
      "dayType": "*",
      "actions": [{ "id": "check_traffic", "type": "suggestion", "payload": "..." }]
    },
    {
      "time": "morning",
      "location": "commute",
      "motion": "driving",
      "phone": "*",
      "light": "normal",
      "sound": "*",
      "dayType": "*",
      "actions": [{ "id": "nav_to_work", "type": "suggestion", "payload": "..." }]
    }
  ],
  "timeoutMs": 7200000,
  "priority": 5,
  "enabled": true
}
```

**Matching algorithm**:
1. **`advanceActiveChains()`**: For each active chain, check if the next step matches the current PhysicalState. If yes, advance the chain position.
2. **`detectNewScenarios()`**: For all enabled scenarios not already active, check if Step 0 matches. If yes, start a new chain.
3. **`cleanupTimeouts()`**: Remove chains that haven't progressed within `timeoutMs` (default 2 hours).
4. **Step matching**: AND-match all 7 dimensions. `*` = wildcard (always matches). `A|B` = OR (matches either value). Confidence = number of specified (non-wildcard) dimensions / 7.
5. **Digital conditions**: Each step can optionally have `digitalConditions` (e.g., `{"batteryLevel": "lte 30"}`) checked against DataTray values.

### 25.5 72 Scenario Definitions

**File**: `entry/src/main/resources/rawfile/config/scenarios.json`

72 scenarios across 12 life categories:

| Category | Scenarios | IDs | Key Examples |
|----------|-----------|-----|-------------|
| Morning Routine | 6 | S01–S06 | Workday wake-up, weekend sleep-in, morning jog |
| Commute | 6 | S07–S12 | Driving/transit/cycling commute, late return |
| Work | 8 | S13–S20 | Focus work, meetings, lunch break, overtime |
| Home Life | 12 | S21–S32 | Cooking, TV, reading, housework, weekend rest |
| Sleep | 5 | S33–S37 | Bedtime, nap, insomnia, night waking |
| Exercise | 6 | S38–S43 | Gym, outdoor running, walking, cycling |
| Dining | 5 | S44–S48 | Restaurant lunch/dinner, cafe, takeout |
| Shopping | 3 | S49–S51 | Supermarket, mall, convenience store |
| Travel | 8 | S52–S59 | Airport, boarding, flight, train, taxi |
| Social | 3 | S60–S62 | Home visitors, outing, attending events |
| Health | 5 | S63–S67 | Sedentary alert, hydration, eye care, sleep reminder |
| Device | 5 | S68–S72 | Low battery, charging complete, BT vehicle, meeting start |

**Coverage analysis**: 55/72 (76%) fully covered by 7-tuple alone; 12/72 (17%) need digital conditions; 5/72 (7%) are pure digital triggers.

### 25.6 RL Feature Expansion

The 7-tuple state and scenario context are encoded as features for the RL models:

**Stream MLP** (25 → 34 dimensions):

| Index | Feature | Encoding |
|-------|---------|----------|
| 0–1 | hour sin/cos | sin/cos(2π·h/24) |
| 2–3 | dayType one-hot | weekend, holiday (workday = both 0) |
| 4–12 | location 9-dim one-hot | home, work, commute, restaurant, gym, transit_hub, shopping, outdoor, cafe |
| 13–18 | motion 6-dim one-hot | stationary, walking, running, cycling, driving, transit |
| 19–23 | phone 5-dim one-hot | in_use, on_desk, in_pocket, charging, unknown |
| 24–25 | light | ordinal (0/0.33/0.67/1) + dark_flag |
| 26–27 | sound | ordinal (0/0.25/0.5/1) + has_voice |
| 28 | has_active_scenario | binary |
| 29 | chain_position | step/total (0–1) |
| 30 | scenario_category_hash | category → ordinal (0.05–0.95) |
| 31 | is_routine | from StateTransitionTracker |
| 32 | time_in_state_norm | min(minutes/120, 1) |
| 33 | battery_norm | batteryLevel/100 |

**Network**: 34 → 128 → 64 → 1 (11,649 parameters per arm, up from 3,328)

**LinUCB** (8 → 14 dimensions):

| Index | Feature |
|-------|---------|
| 0–1 | hour sin/cos |
| 2 | battery/100 |
| 3 | isCharging |
| 4–5 | dayType one-hot (weekend, holiday) |
| 6–10 | motion 5-dim one-hot (stationary, walking, running, cycling, vehicle) |
| 11 | light ordinal |
| 12 | sound ordinal |
| 13 | has_scenario |

**Backward compatibility**: Both `buildFeatures()` functions include fallback paths (e.g., `ps_motion` falls back to `motionState`). `StreamMLP::importJson()` checks `featDim` and skips import on dimension mismatch, causing graceful re-initialization.

### 25.7 Dual Pipeline Integration

The evaluation pipeline in `ContextAwarenessService.periodicEvaluate()` now runs two parallel pipelines:

```
Pipeline 1 (Rules):    tray → snapshot → C++ evaluate() → MatchResult[]
Pipeline 2 (Scenarios): tray → PhysicalStateBuilder → ScenarioMatcher → ScenarioMatchResult[]
```

**PhysicalState fields injected into DataTray** (consumed by both pipelines):
- `ps_time`, `ps_location`, `ps_motion`, `ps_phone`, `ps_light`, `ps_sound`, `ps_dayType`
- `ps_scenario` (top scenario name), `ps_scenarioCategory`, `ps_chainPosition`, `ps_scenarioConfidence`

These `ps_*` keys are available to the C++ rule engine's `buildFeatures()` for RL scoring, enabling the Stream MLP and LinUCB to learn from the 7-tuple state without any changes to the C++ evaluation logic.

### 25.8 UI Display

**File**: `entry/src/main/ets/pages/ContextSettingsPage.ets`

A new card appears below the status overview, showing:
- 7 dimension labels with current values in a 2-column grid
- Active scenario name, step progress (e.g., "2/3"), and count

**File**: `entry/src/main/ets/common/I18n.ets`

Added I18n labels for all dimension values in both Chinese and English:
- `ps.title` → "Physical State" / "物理状态"
- `ps.time.sleeping` → "Sleeping" / "深夜睡眠"
- `ps.location.home` → "Home" / "家"
- etc. (all 7 dimensions × all values)

### 25.9 File Manifest

| File | Action | Description |
|------|--------|-------------|
| `ContextModels.ets` | Edit | Added `TimeSlot`, `LocationCategory`, `MotionCategory`, `PhoneCategory`, `LightCategory`, `SoundCategory`, `DayType`, `PhysicalState`, `Scenario`, `ScenarioStep`, `ScenarioAction`, `ScenarioState`, `ScenarioMatchResult`, `ScenarioCategory` |
| `PhysicalStateBuilder.ets` | New | Sensor → 7-tuple classification (7 classify methods + fingerprint/equals) |
| `ScenarioMatcher.ets` | New | Deterministic scenario chain matcher (72 scenarios, init/match/advance/cleanup) |
| `scenarios.json` | New | 72 scenario definitions in JSON (rawfile/config/) |
| `ContextAwarenessService.ets` | Edit | Pipeline integration: build PhysicalState, run ScenarioMatcher, inject ps_* fields |
| `ContextEngine.ets` | Edit | Added ps_* fields to ContextSnapshot interface |
| `stream_mlp.h` | Edit | `STREAM_FEAT_DIM` 25→34, updated feature layout comment |
| `stream_mlp.cpp` | Edit | `buildFeatures()` rewritten for 34-dim (7-tuple + scenario context) |
| `context_engine.h` | Edit | `LINUCB_DIM` 8→14 |
| `linucb.cpp` | Edit | `buildFeatureVec()` rewritten for 14-dim |
| `ContextSettingsPage.ets` | Edit | 7-tuple PhysicalState display card |
| `I18n.ets` | Edit | Chinese + English labels for all dimension values |

---

## Appendix: TODO Items

### High Priority

| # | Item | Status |
|---|------|--------|
| 1 | C++ module NAPI bindings (motion_detector, sampling_strategy, place_learner, sleep_pattern, feedback_learner, training_sync) | Completed |
| 2 | Wearable device data retrieval (Health Kit) | Partially completed |
| 3 | Rule matching issue | Fixed |
| 4 | Feedback learning system integration (card buttons, context recording, parameter adjustment) | Partially completed |

### Medium Priority

| # | Item | Status |
|---|------|--------|
| 5 | CellID retrieval (low-power location detection) | Limited (API does not provide CellID) |
| 6 | App usage record learning | Limited (permission does not exist) |
| 7 | Silent mode enhancement (key information extraction + emotion detection) | Partially completed (LLM action item extraction implemented) |
| 8 | Phone pickup detection (avoid false GPS triggers) | Pending implementation |

### Low Priority

| # | Item | Status |
|---|------|--------|
| 9 | Architecture diagrams / data flow diagrams / API documentation | Covered in this document |
| 10 | C++ module unit tests | 21-scenario remote testing completed |

---

*End of document*
