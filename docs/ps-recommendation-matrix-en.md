# ClawdBot 7-Tuple Physical State Recommendation Matrix

## Overview

This document defines the recommendation strategy matrix for ClawdBot under various physical state combinations.
The system describes the user's current physical state across 7 dimensions and generates contextual recommendations accordingly.

**Primary dimensions (matrix rows):** Time x Location x Motion x Phone x DayType
**Modifier dimensions (adjust confidence):** Light x Sound



---

## Action Catalog (ActionCatalog)

Each recommended action is encoded as a **2-character string** `[Cat][N]`: uppercase letter for category, digit for sequence number.

| Code | Standard Name | Category | Description |
|------|---------------|----------|-------------|
| **A - Transit Pass** | | | |
| A1 | Show subway pass | Transit | Display subway QR code |
| A2 | Show bus pass | Transit | Display bus QR code |
| A3 | Show payment code | Transit | Display payment QR code (Alipay/WeChat) |
| A4 | Show ticket | Transit | Display venue/park/event e-ticket |
| **B - Schedule & Reminders** | | | |
| B1 | View today's schedule | Schedule | View today's agenda/itinerary |
| B2 | View tomorrow's schedule | Schedule | View tomorrow's agenda |
| B3 | View afternoon schedule | Schedule | View afternoon/partial schedule |
| B4 | Set alarm | Schedule | Set next-day or timed alarm |
| B5 | Set travel reminder | Schedule | Departure/arrival reminder |
| B6 | Set show-end reminder | Schedule | Movie/event end reminder |
| B7 | Check itinerary/tickets | Schedule | View flight/train tickets/trip details |
| B8 | Remind check-in time | Schedule | Check-in/boarding countdown reminder |
| B9 | Off-work reminder | Schedule | Time to leave work reminder |
| **C - Weather & Environment** | | | |
| C1 | Check weather | Weather | Weather forecast & outfit suggestions |
| **D - Media & Entertainment** | | | |
| D1 | Play music | Media | Play music (incl. background music) |
| D2 | Play white noise | Media | White noise/sleep sounds |
| D3 | Play podcast | Media | Play podcast/audio program |
| D4 | View news | Media | News digest/information browsing |
| **E - Navigation & Location** | | | |
| E1 | Navigate home | Navigation | Navigate home/plan route home |
| E2 | Navigate to office | Navigation | Navigate to workplace |
| E3 | Navigate to restaurant | Navigation | Navigate to restaurant/nearby food |
| E4 | Navigate to store | Navigation | Navigate to shopping destination |
| E5 | Navigate to hub | Navigation | Navigate to station/airport/cinema internal location |
| E6 | Navigate attraction | Navigation | Attraction navigation & info |
| E7 | General navigation | Navigation | General destination navigation |
| E8 | Record parking spot | Navigation | Record parking location |
| **F - Transit & Transport** | | | |
| F1 | Check arrival time | Transport | Real-time public transit arrival info |
| F2 | Remind to get off | Transport | Stop-miss prevention reminder |
| F3 | Check ferry schedule | Transport | Ferry/boat timetable |
| F4 | Check showtime/seat | Transport | Movie/show time and seat info |
| **G - Health & Fitness** | | | |
| G1 | Sedentary reminder | Health | Stand up after sitting too long |
| G2 | Hydration reminder | Health | Reminder to drink water |
| G3 | Stretch reminder | Health | Stretch after exercise/sitting |
| G4 | Check step count | Health | Today's steps/exercise data |
| G5 | Rest reminder | Health | Reminder to rest/sleep |
| **H - Dining & Ordering** | | | |
| H1 | Dining suggestions | Dining | Recommend dishes/nearby food |
| **I - Social & Contacts** | | | |
| I1 | Contact reminder | Social | Remind to contact someone/check messages |
| **J - Device & System** | | | |
| J1 | Mute notifications | System | Enter DND/mute notifications |
| J2 | Silent mode confirm | System | Confirm phone is on silent |
| J3 | Watch belongings | System | Anti-theft/crowded area safety reminder |

> **Extension rule:** New actions continue numbering within their category. After 9 in a category, add a new letter category.

### Alias Consolidation Table

The following original texts are all consolidated to standard action names:

| Original Text | Consolidated To |
|---------------|-----------------|
| Today's schedule / Today's schedule overview / Today's itinerary | B1 View today's schedule |
| Set tomorrow's alarm / Set alarm | B4 Set alarm |
| Set travel reminder / Set reminder | B5 Set travel reminder |
| Check itinerary / Check itinerary/tickets | B7 Check itinerary/tickets |
| Check weather / Weather reminder / Check weather/outfit | C1 Check weather |
| Play music / Listen to music / Listen to music/podcast | D1 Play music |
| Listen to podcast / Listen to podcast/music | D3 Play podcast |
| News digest / View news / View news digest | D4 View news |
| Navigate / Navigate to destination | E7 General navigation |
| Check route home | E1 Navigate home |
| Navigate to waiting hall / Navigate to gate / Navigate to theater | E5 Navigate to hub |
| Navigate attraction / Navigate to attraction / View attraction info | E6 Navigate attraction |
| Show subway pass / Display subway code / Subway ride code | A1 Show subway pass |
| Show bus pass / Bus ride code | A2 Show bus pass |
| Show payment code / Payment code | A3 Show payment code |
| Show park ticket / Attraction code / E-ticket | A4 Show ticket |


---

## State Encoding (StateCode)

Each 7-tuple state can be encoded as a **7-character string** in the format:

```
[T][L][M][P][Li][S][D]
```

| Pos | Dimension | Meaning | Encoding Table |
|-----|-----------|---------|----------------|
| T | Time | time | 1=sleeping 2=dawn 3=morning 4=forenoon 5=lunch 6=afternoon 7=evening 8=night 9=late_night |
| L | Location | location | **0**=unknown; **1-9**: 1=home 2=work 3=commute 4=restaurant 5=gym 6=outdoor 7=airport 8=shopping 9=subway; **A-Z**: A=bus_stop B=ferry C=train_station D=cafe E=cinema F=park G-Z=reserved |
| M | Motion | motion | 1=stationary 2=walking 3=running 4=driving |
| P | Phone | phone | 1=in_use 2=holding_lying 3=on_desk 4=face_up 5=in_pocket 6=face_down 7=charging 8=unknown |
| Li | Light | light | 0=unspecified 1=dark 2=dim 3=normal 4=bright |
| S | Sound | sound | 0=unspecified 1=quiet 2=normal 3=noisy 4=unknown |
| D | DayType | dayType | 1=workday 2=weekend 3=holiday |

> **0 = unspecified** (dimension not detected or not applicable)

### Encoding Examples

| StateCode | Interpretation |
|-----------|---------------|
| `3D11002` | morning x cafe(D) x stationary x in_use x light unspecified x sound unspecified x weekend |
| `3D11332` | morning x cafe(D) x stationary x in_use x normal x noisy x weekend |
| `7111001` | evening x home(1) x stationary x in_use x unspecified x unspecified x workday |
| `4231001` | forenoon x work(2) x stationary x on_desk x unspecified x unspecified x workday (sedentary scenario) |
| `3321001` | morning x commute(3) x walking x in_use x unspecified x unspecified x workday |
| `6531002` | afternoon x gym(5) x running x on_desk x unspecified x unspecified x weekend |

> Each row's Code format in the matrix is `TLMPLiSD`; when light/sound columns are not explicitly listed, `0` is used as placeholder.

---
---

## Dimension Definitions

| Dimension | Enum Values | Description |
|-----------|-------------|-------------|
| **Time (time)** | sleeping / dawn / morning / forenoon / lunch / afternoon / evening / night / late_night | 0-5h / 5-7h / 7-9h / 9-12h / 12-14h / 14-17h / 17-20h / 20-23h / 23-24h |
| **Location (location)** | home / work / commute / restaurant / gym / outdoor / airport / shopping / subway / bus_stop / ferry / unknown | Home / Office / Commuting / Restaurant / Gym / Outdoor / Airport / Shopping / Subway / Bus Stop / Ferry / Unknown |
| **Motion (motion)** | stationary / walking / running / driving | Stationary / Walking / Running / Driving |
| **Phone (phone)** | in_use / holding_lying / on_desk / face_up / in_pocket / face_down / charging / unknown | Hand-held in use / Holding while lying / Flat on desk / Face up in dark / In pocket / Screen down / Charging / Unknown |
| **Light (light)** | dark / dim / normal / bright | Dark / Dim / Normal / Bright |
| **Sound (sound)** | quiet / normal / noisy / unknown | Quiet / Normal / Noisy / Unknown |
| **DayType (dayType)** | workday / weekend / holiday | Workday / Weekend / Holiday |

### Location Category Notes

| Location Value | Name | Typical Scenario |
|----------------|------|------------------|
| subway | Subway Station | Riding or waiting for subway |
| bus_stop | Bus Stop | Waiting for or riding bus |
| ferry | Ferry Terminal | Waiting for or riding ferry |

---

## Filter Rules (Invalid Combinations)

The following combinations are physically impossible or extremely unlikely; the system should exclude them directly:

| Rule # | Condition | Exclusion Reason |
|--------|-----------|------------------|
| F1 | motion=running -> phone not in {on_desk, face_up, face_down, charging, holding_lying} | Phone won't be on desk/charging/held lying while running |
| F2 | motion=driving -> phone != holding_lying | Can't hold phone lying down while driving |
| F3 | motion=stationary OR driving -> location != gym | Gym requires movement |
| F4 | time=sleeping -> motion = stationary | No walking/running/driving during sleep |
| F5 | time=sleeping -> light in {dark, dim} | Environment should be dark during sleep |
| F6 | time=sleeping -> location in {home, unknown} | Sleep only at home or unknown |
| F7 | time=sleeping -> phone != in_use | Not actively using phone during sleep |
| F8 | location=commute -> motion in {walking, driving} | Not stationary or running during commute |
| F9 | location=gym -> motion in {walking, running} | No driving at gym |
| F10 | location=airport -> motion in {stationary, walking} | No running or driving at airport |
| F11 | phone=holding_lying -> motion = stationary | Holding while lying only when stationary |
| F12 | phone=face_up -> motion = stationary | Face up in dark only when stationary |
| F13 | phone=face_down -> motion not in {running, walking} | Screen down not while running/walking |
| F14 | location in {subway, bus_stop, ferry} -> motion in {stationary, walking} | No driving or running at subway/bus stop/ferry |
| F15 | location=subway -> sound != quiet | Subway environment is usually noisy, exclude quiet |

**Low-weight rules (retained but overall confidence reduced by 15%):**
- LW1: time=dawn AND location=work -> Very few early-shift workers
- LW2: time=late_night AND location != home -> Late-night outings are uncommon

**Location-specific sound rules (modifier notes):**
- subway -> sound usually noisy; apply noisy modifier
- bus_stop -> sound usually normal or noisy (outdoor environment)
- ferry -> sound usually normal (cabin is relatively quiet)

---

## Main Recommendation Matrix

> **Confidence note:** Represents the probability that the user actually needs the recommendation in that context (0-100%)
> **Light/Sound modifiers** see modifier tables at end of document; they further adjust confidence

---

### sleeping (0-5h)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 1117001 | Workday bedtime charging | sleeping | home | stationary | charging | workday | Set alarm [B4] (88%) | View tomorrow's schedule [B2] (55%) | Check weather/outfit [C1] (42%) | Plugged in at bedtime; alarm is most important on workdays |
| 1112001 | Workday half-asleep holding | sleeping | home | stationary | holding_lying | workday | Set alarm [B4] (82%) | Rest reminder [G5] (52%) | View tomorrow's schedule [B2] (40%) | Half-asleep state holding phone |
| 1114001 | Workday dark room resting | sleeping | home | stationary | face_up | workday | Set alarm [B4] (78%) | Rest reminder [G5] (55%) | View tomorrow's schedule [B2] (38%) | Dark room, possibly tossing and turning |
| 1117002 | Weekend bedtime charging | sleeping | home | stationary | charging | weekend | Set alarm [B4] (58%) | Play white noise [D2] (45%) | Rest reminder [G5] (35%) | Weekend sleep; alarm priority lower |
| 1112002 | Weekend half-asleep lying | sleeping | home | stationary | holding_lying | weekend | Play white noise [D2] (48%) | Set alarm [B4] (42%) | Rest reminder [G5] (40%) | Weekend, may sleep in later |

---

### dawn (5-7h)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 2117001 | Workday morning charging | dawn | home | stationary | charging | workday | View today's schedule [B1] (90%) | Check weather/outfit [C1] (85%) | Set travel reminder [B5] (68%) | Just woke up charging; core morning scenario |
| 2111001 | Workday morning phone use | dawn | home | stationary | in_use | workday | View today's schedule [B1] (92%) | Check weather/outfit [C1] (88%) | View news digest [D4] (58%) | Actively using phone; high info demand |
| 2111002 | Weekend morning phone use | dawn | home | stationary | in_use | weekend | Check weather [C1] (72%) | View news digest [D4] (62%) | Set reminder [B5] (38%) | Weekend early riser; relaxed browsing mode |
| 2125001 | Workday morning walk | dawn | home | walking | in_pocket | workday | Check weather [C1] (75%) | Check step count [G4] (62%) | Play music [D1] (58%) | Indoor morning exercise or waking activity |
| 2345001 | Very early driving commute | dawn | commute | driving | in_pocket | workday | Navigate to destination [E7] (82%) | Play music [D1] (72%) | View today's schedule [B1] (52%) | Very early driving commute |
| 2325001 | Very early walking commute | dawn | commute | walking | in_pocket | workday | Play music [D1] (78%) | View today's schedule [B1] (62%) | Check weather [C1] (48%) | Very early walking commute |
| 2213001 | Very early at office | dawn | work | stationary | on_desk | workday | View today's schedule [B1] (61%) | Hydration reminder [G2] (47%) | Check weather [C1] (30%) | LW1 downweight: very few early-shift workers |
| 2625002 | Weekend dawn outdoor walk | dawn | outdoor | walking | in_pocket | weekend | Check weather [C1] (80%) | Check step count [G4] (68%) | Play music [D1] (62%) | Weekend morning walk |
| 2635002 | Weekend dawn morning run | dawn | outdoor | running | in_pocket | weekend | Check step count [G4] (85%) | Hydration reminder [G2] (78%) | Play music [D1] (68%) | Weekend morning run |
| 2525001 | Workday very early gym | dawn | gym | walking | in_pocket | workday | Check step count [G4] (82%) | Hydration reminder [G2] (75%) | Stretch reminder [G3] (60%) | Workday very early gym |

---

### morning (7-9h)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 3117001 | Workday morning charging | morning | home | stationary | charging | workday | View today's schedule [B1] (92%) | Check weather/outfit [C1] (88%) | Set travel reminder [B5] (72%) | Waking up for work; most core scenario |
| 3111001 | Workday morning phone use | morning | home | stationary | in_use | workday | View today's schedule [B1] (94%) | Check weather/outfit [C1] (90%) | View news digest [D4] (62%) | Morning active phone use; high info demand |
| 3113001 | Workday breakfast phone | morning | home | stationary | on_desk | workday | View today's schedule [B1] (88%) | Check weather/outfit [C1] (82%) | Set travel reminder [B5] (68%) | Phone on table; possibly having breakfast |
| 3111002 | Weekend morning phone use | morning | home | stationary | in_use | weekend | Check weather [C1] (82%) | View news digest [D4] (72%) | Set reminder [B5] (48%) | Weekend morning; relaxed browsing |
| 3117002 | Weekend morning charging | morning | home | stationary | charging | weekend | Check weather [C1] (78%) | View news digest [D4] (65%) | Play music [D1] (50%) | Weekend charging morning |
| 3325001 | Walking to work, pocket | morning | commute | walking | in_pocket | workday | Play music [D1] (88%) | View today's schedule [B1] (74%) | Check weather [C1] (52%) | Walking commute; phone in pocket |
| 3345001 | Driving to work, pocket | morning | commute | driving | in_pocket | workday | Navigate to office [E2] (90%) | Play music [D1] (78%) | View today's schedule [B1] (58%) | Driving to work; navigation priority |
| 3321001 | Walking commute, phone use | morning | commute | walking | in_use | workday | View today's schedule [B1] (82%) | View news digest [D4] (80%) | Play music [D1] (68%) | Walking commute actively using phone |
| 3341001 | Driving commute, phone use | morning | commute | driving | in_use | workday | Navigate to office [E2] (85%) | Play music [D1] (72%) | Record parking spot [E8] (55%) | Driving while using phone, lower non-nav recs |
| 3213001 | Arrived at office, schedule | morning | work | stationary | on_desk | workday | View today's schedule [B1] (94%) | Hydration reminder [G2] (58%) | View news digest [D4] (48%) | First thing at office; schedule check strongest |
| 3211001 | At work, phone use | morning | work | stationary | in_use | workday | View today's schedule [B1] (90%) | Contact reminder [I1] (62%) | Hydration reminder [G2] (52%) | Using phone at work |
| 3411001 | Workday breakfast, phone use | morning | restaurant | stationary | in_use | workday | Dining suggestions [H1] (85%) | View today's schedule [B1] (68%) | Contact reminder [I1] (42%) | Breakfast near office |
| 3413001 | Workday breakfast, on desk | morning | restaurant | stationary | on_desk | workday | Dining suggestions [H1] (80%) | View today's schedule [B1] (62%) | Hydration reminder [G2] (40%) | Breakfast phone on table |
| 3625002 | Weekend morning walk outdoor | morning | outdoor | walking | in_pocket | weekend | Check weather [C1] (84%) | Check step count [G4] (72%) | Play music [D1] (70%) | Weekend morning walk |
| 3635002 | Weekend morning run outdoor | morning | outdoor | running | in_pocket | weekend | Check step count [G4] (90%) | Hydration reminder [G2] (82%) | Play music [D1] (76%) | Weekend morning run |
| 3625003 | Holiday morning walk | morning | outdoor | walking | in_pocket | holiday | Check weather [C1] (82%) | Check step count [G4] (70%) | Play music [D1] (68%) | Holiday morning walk |
| 3525001 | Workday morning gym | morning | gym | walking | in_pocket | workday | Check step count [G4] (82%) | Hydration reminder [G2] (76%) | Stretch reminder [G3] (62%) | Workday morning exercise |
| 3535002 | Weekend morning gym run | morning | gym | running | in_pocket | weekend | Check step count [G4] (92%) | Hydration reminder [G2] (86%) | Play music [D1] (74%) | Weekend morning gym run |
| 3725001 | Catching flight, walking | morning | airport | walking | in_pocket | workday | Check itinerary [B7] (94%) | Navigate to gate [E5] (88%) | Check weather [C1] (58%) | Catching flight; itinerary is top priority |
| 3711001 | Airport waiting, phone use | morning | airport | stationary | in_use | workday | Check itinerary [B7] (96%) | Contact reminder [I1] (62%) | Play music [D1] (52%) | Airport waiting, actively using phone |

---

### forenoon (9-12h)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 4213001 | Workday forenoon office | forenoon | work | stationary | on_desk | workday | Sedentary reminder [G1] (90%) | Hydration reminder [G2] (82%) | View today's schedule [B1] (74%) | Morning work main scenario; sedentary most important |
| 4211001 | Forenoon work phone use | forenoon | work | stationary | in_use | workday | View today's schedule [B1] (82%) | Sedentary reminder [G1] (74%) | Hydration reminder [G2] (68%) | Using phone at work |
| 4216001 | Forenoon focused, screen down | forenoon | work | stationary | face_down | workday | Sedentary reminder [G1] (88%) | Hydration reminder [G2] (80%) | Stretch reminder [G3] (68%) | Screen down, focused work |
| 4213002 | Weekend overtime office | forenoon | work | stationary | on_desk | weekend | Sedentary reminder [G1] (78%) | Hydration reminder [G2] (70%) | Check weather [C1] (48%) | Weekend overtime |
| 4113001 | WFH forenoon | forenoon | home | stationary | on_desk | workday | Sedentary reminder [G1] (82%) | Hydration reminder [G2] (70%) | View today's schedule [B1] (62%) | Work from home; sedentary reminder important |
| 4111001 | WFH phone use | forenoon | home | stationary | in_use | workday | View today's schedule [B1] (78%) | Sedentary reminder [G1] (68%) | Hydration reminder [G2] (62%) | WFH phone use |
| 4111002 | Weekend home leisure | forenoon | home | stationary | in_use | weekend | Check weather [C1] (74%) | View news digest [D4] (68%) | Play music [D1] (58%) | Weekend home leisure |
| 4117002 | Weekend home charging | forenoon | home | stationary | charging | weekend | Check weather [C1] (70%) | News digest [D4] (62%) | Play music [D1] (55%) | Weekend charging leisure |
| 4525001 | Workday forenoon gym | forenoon | gym | walking | in_pocket | workday | Check step count [G4] (90%) | Hydration reminder [G2] (84%) | Stretch reminder [G3] (68%) | Workday gym |
| 4535002 | Weekend gym run | forenoon | gym | running | in_pocket | weekend | Check step count [G4] (94%) | Hydration reminder [G2] (90%) | Play music [D1] (74%) | Weekend gym run |
| 4525003 | Holiday gym | forenoon | gym | walking | in_pocket | holiday | Check step count [G4] (88%) | Hydration reminder [G2] (82%) | Stretch reminder [G3] (65%) | Holiday gym |
| 4625002 | Weekend outdoor walk | forenoon | outdoor | walking | in_pocket | weekend | Check step count [G4] (84%) | Check weather [C1] (70%) | Play music [D1] (65%) | Weekend outdoor walk |
| 4635002 | Weekend outdoor run | forenoon | outdoor | running | in_pocket | weekend | Check step count [G4] (92%) | Hydration reminder [G2] (88%) | Play music [D1] (72%) | Weekend outdoor run |
| 4625003 | Holiday outdoor tour | forenoon | outdoor | walking | in_pocket | holiday | Check step count [G4] (82%) | Check weather [C1] (68%) | Navigate [E7] (58%) | Holiday outdoor tour |
| 4825002 | Weekend shopping | forenoon | shopping | walking | in_pocket | weekend | Navigate to store [E4] (70%) | Check step count [G4] (58%) | Hydration reminder [G2] (48%) | Weekend shopping |
| 4825003 | Holiday shopping | forenoon | shopping | walking | in_pocket | holiday | Navigate to store [E4] (74%) | Check step count [G4] (60%) | Hydration reminder [G2] (50%) | Holiday shopping |
| 4411001 | Forenoon restaurant phone | forenoon | restaurant | stationary | in_use | workday | Dining suggestions [H1] (88%) | Contact reminder [I1] (52%) | View schedule [B3] (48%) | Post-meeting or breakfast time |
| 4325001 | Late walking commute | forenoon | commute | walking | in_pocket | workday | Play music [D1] (74%) | View schedule [B3] (62%) | Check step count [G4] (52%) | Late walking commute |
| 4725001 | Forenoon airport waiting | forenoon | airport | walking | in_pocket | workday | Check itinerary [B7] (92%) | Navigate to gate [E5] (82%) | Hydration reminder [G2] (58%) | Forenoon flight waiting |
| 4711001 | Airport waiting area | forenoon | airport | stationary | in_use | workday | Check itinerary [B7] (92%) | Play music [D1] (64%) | Contact reminder [I1] (58%) | Airport waiting area |
| 4013001 | Unknown location office | forenoon | unknown | stationary | on_desk | workday | Sedentary reminder [G1] (78%) | Hydration reminder [G2] (70%) | View schedule [B3] (62%) | Unknown location, likely working |
| 4025002 | Weekend outing | forenoon | unknown | walking | in_pocket | weekend | Check step count [G4] (74%) | Check weather [C1] (62%) | Play music [D1] (60%) | Weekend outing |

---

### lunch (12-14h)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 5411001 | Workday restaurant phone | lunch | restaurant | stationary | in_use | workday | Dining suggestions [H1] (94%) | Contact reminder [I1] (60%) | View afternoon schedule [B3] (52%) | Lunch dining; dining is strongest signal |
| 5413001 | Workday lunch, on desk | lunch | restaurant | stationary | on_desk | workday | Dining suggestions [H1] (90%) | Rest reminder [G5] (65%) | View afternoon schedule [B3] (50%) | Phone on table while eating |
| 5411002 | Weekend lunch out | lunch | restaurant | stationary | in_use | weekend | Dining suggestions [H1] (88%) | Contact reminder [I1] (68%) | Navigate [E7] (48%) | Weekend lunch out |
| 5411003 | Holiday lunch gathering | lunch | restaurant | stationary | in_use | holiday | Dining suggestions [H1] (86%) | Contact reminder [I1] (72%) | Navigate [E7] (52%) | Holiday lunch gathering |
| 5211001 | Office food delivery | lunch | work | stationary | in_use | workday | Dining suggestions [H1] (80%) | Rest reminder [G5] (72%) | View afternoon schedule [B3] (68%) | Ordering food delivery at office |
| 5213001 | Office lunch break, on desk | lunch | work | stationary | on_desk | workday | Sedentary reminder [G1] (74%) | Rest reminder [G5] (70%) | View afternoon schedule [B3] (62%) | Office lunch break |
| 5216001 | Office nap, screen down | lunch | work | stationary | face_down | workday | Rest reminder [G5] (78%) | Hydration reminder [G2] (65%) | View afternoon schedule [B3] (58%) | Office nap screen down |
| 5111001 | Home lunch, phone use | lunch | home | stationary | in_use | workday | View afternoon schedule [B3] (74%) | Dining suggestions [H1] (68%) | Rest reminder [G5] (60%) | Home lunch |
| 5111002 | Weekend lunch at home | lunch | home | stationary | in_use | weekend | Check weather [C1] (70%) | Dining suggestions [H1] (62%) | News digest [D4] (58%) | Weekend lunch at home |
| 5112002 | Weekend nap lying down | lunch | home | stationary | holding_lying | weekend | Play music [D1] (65%) | Rest reminder [G5] (58%) | Check weather [C1] (45%) | Weekend nap lying down |
| 5625001 | Out looking for food | lunch | outdoor | walking | in_pocket | workday | Navigate to restaurant [E3] (78%) | Check step count [G4] (60%) | Check weather [C1] (48%) | Out looking for food |
| 5625002 | Weekend looking for food | lunch | outdoor | walking | in_pocket | weekend | Navigate to restaurant [E3] (74%) | Check step count [G4] (62%) | Check weather [C1] (52%) | Weekend looking for restaurant |
| 5825002 | Shopping midday food | lunch | shopping | walking | in_pocket | weekend | Navigate to restaurant [E3] (72%) | Check step count [G4] (60%) | Hydration reminder [G2] (50%) | Shopping mall midday food break |
| 5345001 | Driving out for lunch | lunch | commute | driving | in_pocket | workday | Navigate to restaurant [E3] (82%) | Record parking spot [E8] (65%) | Play music [D1] (50%) | Driving out for lunch |
| 5525001 | Midday gym | lunch | gym | walking | in_pocket | workday | Check step count [G4] (85%) | Hydration reminder [G2] (80%) | Dining suggestions [H1] (48%) | Midday gym |

---

### afternoon (14-17h)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 6213001 | Afternoon office sedentary | afternoon | work | stationary | on_desk | workday | Sedentary reminder [G1] (94%) | Hydration reminder [G2] (84%) | View today's schedule [B1] (74%) | Afternoon work peak; sedentary most critical |
| 6211001 | Afternoon work phone use | afternoon | work | stationary | in_use | workday | View today's schedule [B1] (82%) | Sedentary reminder [G1] (76%) | Hydration reminder [G2] (70%) | Using phone at work |
| 6216001 | Afternoon focused, screen down | afternoon | work | stationary | face_down | workday | Sedentary reminder [G1] (90%) | Hydration reminder [G2] (80%) | Stretch reminder [G3] (68%) | Screen down, focused work |
| 6213002 | Weekend overtime afternoon | afternoon | work | stationary | on_desk | weekend | Sedentary reminder [G1] (80%) | Hydration reminder [G2] (72%) | Check weather [C1] (50%) | Weekend overtime |
| 6113001 | WFH afternoon | afternoon | home | stationary | on_desk | workday | Sedentary reminder [G1] (88%) | Hydration reminder [G2] (74%) | View schedule [B3] (62%) | WFH afternoon |
| 6111002 | Weekend home afternoon | afternoon | home | stationary | in_use | weekend | Check weather [C1] (70%) | Check step count [G4] (60%) | News digest [D4] (58%) | Weekend afternoon at home |
| 6112002 | Weekend afternoon lying | afternoon | home | stationary | holding_lying | weekend | Stretch reminder [G3] (72%) | Set reminder [B5] (58%) | Play music [D1] (52%) | Weekend post-nap lying down |
| 6117001 | WFH afternoon charging | afternoon | home | stationary | charging | workday | Sedentary reminder [G1] (82%) | Hydration reminder [G2] (70%) | View schedule [B3] (60%) | WFH afternoon charging |
| 6535001 | Workday afternoon run | afternoon | gym | running | in_pocket | workday | Check step count [G4] (92%) | Hydration reminder [G2] (90%) | Play music [D1] (78%) | Workday afternoon run |
| 6525001 | Workday afternoon gym | afternoon | gym | walking | in_pocket | workday | Check step count [G4] (88%) | Hydration reminder [G2] (84%) | Stretch reminder [G3] (70%) | Workday afternoon gym |
| 6535002 | Weekend afternoon run | afternoon | gym | running | in_pocket | weekend | Check step count [G4] (94%) | Hydration reminder [G2] (90%) | Play music [D1] (80%) | Weekend afternoon run |
| 6525003 | Holiday gym | afternoon | gym | walking | in_pocket | holiday | Check step count [G4] (88%) | Hydration reminder [G2] (82%) | Stretch reminder [G3] (68%) | Holiday gym |
| 6625001 | Workday outdoor | afternoon | outdoor | walking | in_pocket | workday | Check step count [G4] (80%) | Navigate [E7] (68%) | Check weather [C1] (58%) | Workday outing |
| 6625002 | Weekend afternoon walk | afternoon | outdoor | walking | in_pocket | weekend | Check step count [G4] (84%) | Check weather [C1] (68%) | Play music [D1] (62%) | Weekend afternoon walk |
| 6635002 | Weekend afternoon run | afternoon | outdoor | running | in_pocket | weekend | Check step count [G4] (90%) | Hydration reminder [G2] (86%) | Play music [D1] (74%) | Weekend afternoon run |
| 6625003 | Holiday outdoor tour | afternoon | outdoor | walking | in_pocket | holiday | Check step count [G4] (82%) | Navigate [E7] (70%) | Check weather [C1] (65%) | Holiday outdoor tour |
| 6825002 | Weekend shopping | afternoon | shopping | walking | in_pocket | weekend | Navigate to store [E4] (72%) | Check step count [G4] (60%) | Hydration reminder [G2] (50%) | Weekend shopping |
| 6825003 | Holiday shopping | afternoon | shopping | walking | in_pocket | holiday | Navigate to store [E4] (76%) | Check step count [G4] (62%) | Hydration reminder [G2] (54%) | Holiday shopping |
| 6345001 | Afternoon driving out | afternoon | commute | driving | in_pocket | workday | Navigate to destination [E7] (90%) | Play music [D1] (74%) | Record parking spot [E8] (64%) | Driving out for errands |
| 6325001 | Afternoon walking commute | afternoon | commute | walking | in_pocket | workday | Play music [D1] (78%) | Check step count [G4] (68%) | Navigate [E7] (60%) | Walking commute/outing |
| 6725001 | Afternoon flight waiting | afternoon | airport | walking | in_pocket | workday | Check itinerary [B7] (92%) | Navigate to gate [E5] (84%) | Hydration reminder [G2] (60%) | Afternoon flight waiting |
| 6711001 | Afternoon airport waiting | afternoon | airport | stationary | in_use | workday | Check itinerary [B7] (90%) | Play music [D1] (68%) | View news digest [D4] (58%) | Airport waiting area |
| 6725003 | Holiday travel | afternoon | airport | walking | in_pocket | holiday | Check itinerary [B7] (90%) | Navigate to gate [E5] (82%) | Contact reminder [I1] (60%) | Holiday travel |
| 6411002 | Weekend afternoon tea/meal | afternoon | restaurant | stationary | in_use | weekend | Dining suggestions [H1] (84%) | Contact reminder [I1] (64%) | Navigate [E7] (48%) | Weekend afternoon tea/meal |
| 6013001 | Unknown location work | afternoon | unknown | stationary | on_desk | workday | Sedentary reminder [G1] (80%) | Hydration reminder [G2] (72%) | View schedule [B3] (64%) | Unknown location, work hours |
| 6025002 | Weekend outing | afternoon | unknown | walking | in_pocket | weekend | Check step count [G4] (72%) | Check weather [C1] (62%) | Play music [D1] (58%) | Weekend outing |

---

### evening (17-20h)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 7345001 | Driving home from work | evening | commute | driving | in_pocket | workday | Navigate home [E1] (94%) | Play music [D1] (80%) | Record parking spot [E8] (68%) | Driving home; most typical commute |
| 7325001 | Walking home from work | evening | commute | walking | in_pocket | workday | Play music [D1] (84%) | Check step count [G4] (70%) | View news digest [D4] (60%) | Walking home from work |
| 7347001 | Driving commute, charging | evening | commute | driving | charging | workday | Navigate home [E1] (90%) | Play music [D1] (74%) | Record parking spot [E8] (62%) | Driving while charging |
| 7111001 | Home from work, phone use | evening | home | stationary | in_use | workday | View today's schedule [B1] (74%) | View news digest [D4] (70%) | Stretch reminder [G3] (60%) | Home from work |
| 7117001 | Home charging, relaxing | evening | home | stationary | charging | workday | Stretch reminder [G3] (74%) | View news digest [D4] (68%) | View tomorrow's schedule [B2] (62%) | Home charging relaxation |
| 7111002 | Weekend evening home | evening | home | stationary | in_use | weekend | Check weather [C1] (70%) | Play music [D1] (64%) | View news digest [D4] (60%) | Weekend evening at home |
| 7112002 | Weekend evening lying | evening | home | stationary | holding_lying | weekend | Play music [D1] (68%) | Stretch reminder [G3] (58%) | View news digest [D4] (50%) | Weekend evening lying down resting |
| 7111003 | Holiday evening home | evening | home | stationary | in_use | holiday | Check weather [C1] (68%) | Play music [D1] (62%) | View news digest [D4] (58%) | Holiday evening at home |
| 7411001 | After-work dinner phone | evening | restaurant | stationary | in_use | workday | Dining suggestions [H1] (90%) | Contact reminder [I1] (64%) | Check step count [G4] (48%) | After-work dinner |
| 7413001 | After-work dinner, on desk | evening | restaurant | stationary | on_desk | workday | Dining suggestions [H1] (86%) | Rest reminder [G5] (60%) | Check step count [G4] (45%) | After-work dinner phone on table |
| 7411002 | Weekend dinner phone | evening | restaurant | stationary | in_use | weekend | Dining suggestions [H1] (88%) | Contact reminder [I1] (70%) | Navigate home [E1] (50%) | Weekend dinner |
| 7411003 | Holiday dinner | evening | restaurant | stationary | in_use | holiday | Dining suggestions [H1] (84%) | Contact reminder [I1] (74%) | Check step count [G4] (52%) | Holiday dinner |
| 7535001 | After-work night run | evening | gym | running | in_pocket | workday | Check step count [G4] (92%) | Hydration reminder [G2] (88%) | Play music [D1] (80%) | After-work gym run |
| 7525001 | After-work gym | evening | gym | walking | in_pocket | workday | Check step count [G4] (88%) | Hydration reminder [G2] (84%) | Stretch reminder [G3] (70%) | After-work gym |
| 7535002 | Weekend evening run | evening | gym | running | in_pocket | weekend | Check step count [G4] (90%) | Hydration reminder [G2] (86%) | Play music [D1] (76%) | Weekend evening run |
| 7625001 | Workday evening walk | evening | outdoor | walking | in_pocket | workday | Check step count [G4] (80%) | Play music [D1] (68%) | Check weather [C1] (58%) | Workday evening walk |
| 7625002 | Weekend evening walk | evening | outdoor | walking | in_pocket | weekend | Check step count [G4] (84%) | Play music [D1] (72%) | Check weather [C1] (60%) | Weekend evening walk |
| 7625003 | Holiday evening outdoor | evening | outdoor | walking | in_pocket | holiday | Check step count [G4] (82%) | Play music [D1] (74%) | Navigate [E7] (58%) | Holiday evening outing |
| 7213001 | Overtime, check schedule | evening | work | stationary | on_desk | workday | View today's schedule [B1] (80%) | Sedentary reminder [G1] (72%) | Off-work reminder [B9] (68%) | Overtime; off-work reminder has value |
| 7211001 | Overtime, phone use | evening | work | stationary | in_use | workday | View today's schedule [B1] (74%) | Contact reminder [I1] (60%) | Off-work reminder [B9] (58%) | Overtime phone use |
| 7825002 | Weekend evening shopping | evening | shopping | walking | in_pocket | weekend | Navigate to store [E4] (72%) | Check step count [G4] (62%) | Hydration reminder [G2] (52%) | Weekend evening shopping |
| 7825003 | Holiday shopping | evening | shopping | walking | in_pocket | holiday | Navigate to store [E4] (76%) | Check step count [G4] (64%) | Hydration reminder [G2] (54%) | Holiday shopping |
| 7725001 | Evening flight | evening | airport | walking | in_pocket | workday | Check itinerary [B7] (92%) | Navigate to gate [E5] (84%) | Contact reminder [I1] (62%) | Evening flight |
| 7711001 | Evening airport waiting | evening | airport | stationary | in_use | workday | Check itinerary [B7] (90%) | Play music [D1] (68%) | Contact reminder [I1] (60%) | Evening airport waiting |
| 7045001 | Rush hour driving | evening | unknown | driving | in_pocket | workday | Navigate [E7] (86%) | Play music [D1] (72%) | Record parking spot [E8] (60%) | Rush hour driving |
| 7025001 | After-work unknown location | evening | unknown | walking | in_pocket | workday | Play music [D1] (78%) | Check step count [G4] (68%) | Navigate [E7] (60%) | After-work unknown location |

---

### night (20-23h)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 8111001 | Workday night prep | night | home | stationary | in_use | workday | Set alarm [B4] (88%) | View tomorrow's schedule [B2] (80%) | Stretch reminder [G3] (62%) | Workday night; preparing for tomorrow |
| 8112001 | Workday night lying phone | night | home | stationary | holding_lying | workday | Set alarm [B4] (90%) | View tomorrow's schedule [B2] (74%) | Rest reminder [G5] (68%) | Workday night lying with phone |
| 8117001 | Workday night charging | night | home | stationary | charging | workday | Set alarm [B4] (86%) | View tomorrow's schedule [B2] (72%) | Stretch reminder [G3] (60%) | Workday night charging |
| 8114001 | Workday night dark room | night | home | stationary | face_up | workday | Set alarm [B4] (85%) | Rest reminder [G5] (72%) | View tomorrow's schedule [B2] (65%) | Dark room, possibly preparing to sleep |
| 8111002 | Weekend night entertainment | night | home | stationary | in_use | weekend | Play music [D1] (72%) | Check step count [G4] (64%) | View news digest [D4] (60%) | Weekend night entertainment |
| 8112002 | Weekend night lying relaxing | night | home | stationary | holding_lying | weekend | Play music [D1] (70%) | View news digest [D4] (62%) | Set alarm [B4] (52%) | Weekend night lying relaxing |
| 8117002 | Weekend night charging | night | home | stationary | charging | weekend | Play music [D1] (65%) | News digest [D4] (58%) | Set alarm [B4] (50%) | Weekend night charging |
| 8111003 | Holiday night entertainment | night | home | stationary | in_use | holiday | Play music [D1] (70%) | Check step count [G4] (60%) | View news digest [D4] (58%) | Holiday night entertainment |
| 8411002 | Weekend late-night snack | night | restaurant | stationary | in_use | weekend | Dining suggestions [H1] (84%) | Contact reminder [I1] (70%) | Navigate home [E1] (55%) | Weekend late-night snack |
| 8411003 | Holiday night gathering | night | restaurant | stationary | in_use | holiday | Dining suggestions [H1] (82%) | Contact reminder [I1] (74%) | Navigate home [E1] (58%) | Holiday night gathering |
| 8535001 | Workday night run | night | gym | running | in_pocket | workday | Check step count [G4] (88%) | Hydration reminder [G2] (82%) | Play music [D1] (74%) | Workday night run |
| 8525002 | Weekend night gym | night | gym | walking | in_pocket | weekend | Check step count [G4] (84%) | Hydration reminder [G2] (80%) | Stretch reminder [G3] (68%) | Weekend night gym |
| 8625002 | Weekend night walk | night | outdoor | walking | in_pocket | weekend | Check step count [G4] (80%) | Play music [D1] (70%) | Navigate home [E1] (62%) | Weekend night walk |
| 8625003 | Holiday night outdoor | night | outdoor | walking | in_pocket | holiday | Check step count [G4] (78%) | Play music [D1] (72%) | Navigate home [E1] (65%) | Holiday night outdoor |
| 8825002 | Weekend night shopping | night | shopping | walking | in_pocket | weekend | Check step count [G4] (64%) | Navigate to store [E4] (60%) | Hydration reminder [G2] (45%) | Weekend night shopping |
| 8345001 | Overtime driving home | night | commute | driving | in_pocket | workday | Navigate home [E1] (88%) | Play music [D1] (74%) | Record parking spot [E8] (62%) | Overtime driving home |
| 8011001 | Night unknown location | night | unknown | stationary | in_use | workday | Set alarm [B4] (80%) | Rest reminder [G5] (68%) | View tomorrow's schedule [B2] (64%) | Night unknown location |
| 8025002 | Weekend night out | night | unknown | walking | in_pocket | weekend | Check step count [G4] (70%) | Navigate home [E1] (65%) | Play music [D1] (58%) | Weekend night out |

---

### late_night (23-24h)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 9112001 | Late night workday lying | late_night | home | stationary | holding_lying | workday | Set alarm [B4] (94%) | Rest reminder [G5] (88%) | View tomorrow's schedule [B2] (72%) | Late night workday; sleep prep most important |
| 9111001 | Late night phone browsing | late_night | home | stationary | in_use | workday | Set alarm [B4] (92%) | Rest reminder [G5] (85%) | View tomorrow's schedule [B2] (70%) | Late night still using phone |
| 9117001 | Late night charging for bed | late_night | home | stationary | charging | workday | Set alarm [B4] (90%) | Rest reminder [G5] (78%) | View tomorrow's schedule [B2] (65%) | Charging, preparing to sleep |
| 9114001 | Late night dark room resting | late_night | home | stationary | face_up | workday | Set alarm [B4] (88%) | Rest reminder [G5] (82%) | View tomorrow's schedule [B2] (60%) | Dark room, about to sleep |
| 9112002 | Weekend late night lying | late_night | home | stationary | holding_lying | weekend | Play music [D1] (68%) | Rest reminder [G5] (72%) | Set alarm [B4] (65%) | Weekend late night lying |
| 9111002 | Weekend late night browsing | late_night | home | stationary | in_use | weekend | Rest reminder [G5] (75%) | Set alarm [B4] (68%) | Play music [D1] (60%) | Weekend late night browsing |
| 9117002 | Weekend late night charging | late_night | home | stationary | charging | weekend | Rest reminder [G5] (70%) | Set alarm [B4] (65%) | Play white noise [D2] (52%) | Weekend late night charging |
| 9011001 | Late night unknown location | late_night | unknown | stationary | in_use | workday | Rest reminder [G5] (85%) | Set alarm [B4] (80%) | View tomorrow's schedule [B2] (60%) | LW2 downweight; late night unknown location |
| 9625002 | Late night outdoor walk | late_night | outdoor | walking | in_pocket | weekend | Navigate home [E1] (80%) | Check step count [G4] (62%) | Play music [D1] (55%) | Late night outdoor walk |

---

### subway (Subway Station)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 3921001 | Morning rush subway commute | morning | subway | walking | in_use | workday | Check arrival time [F1] (90%) | Listen to podcast/music [D3] (80%) | View today's schedule [B1] (70%) | Noisy environment, wearing earbuds |
| 7915001 | Evening rush subway return | evening | subway | stationary | in_pocket | workday | Check route home [E1] (88%) | Remind to get off [F2] (75%) | News digest [D4] (60%) | Crowded, phone in pocket |
| 3911001 | Workday subway morning use | morning | subway | stationary | in_use | workday | View today's schedule [B1] (88%) | View news digest [D4] (78%) | Check weather [C1] (62%) | Seated, browsing phone |
| 7925001 | Workday evening subway | evening | subway | walking | in_pocket | workday | Navigate home [E1] (82%) | Check step count [G4] (68%) | News digest [D4] (58%) | Walking during transfer |
| 5911001 | Workday midday subway | lunch | subway | stationary | in_use | workday | Dining suggestions [H1] (80%) | Navigate to restaurant [E3] (72%) | News digest [D4] (55%) | En route to lunch |
| 6911001 | Workday afternoon subway | afternoon | subway | stationary | in_use | workday | View afternoon schedule [B3] (82%) | News digest [D4] (70%) | Listen to podcast [D3] (60%) | Afternoon outing |
| 3911002 | Weekend subway outing | morning | subway | stationary | in_use | weekend | Navigate to destination [E7] (85%) | Check weather [C1] (72%) | Listen to podcast [D3] (65%) | Weekend outing |
| 7911002 | Weekend subway night return | evening | subway | stationary | in_use | weekend | Navigate home [E1] (80%) | Check step count [G4] (65%) | News digest [D4] (55%) | Weekend night return |
| 6925002 | Weekend afternoon subway | afternoon | subway | walking | in_pocket | weekend | Navigate to destination [E7] (80%) | Check step count [G4] (65%) | Listen to music [D1] (60%) | Transfer walking |
| 3911003 | Holiday subway outing | morning | subway | stationary | in_use | holiday | View attraction info [E6] (85%) | Navigate to destination [E7] (80%) | Check weather [C1] (68%) | Holiday travel, may be crowded |

---

### bus_stop (Bus Stop)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 3A11001 | Morning rush waiting for bus | morning | bus_stop | stationary | in_use | workday | Check arrival time [F1] (92%) | Today's itinerary [B1] (78%) | Weather reminder [C1] (65%) | Outdoor waiting |
| 7A11001 | Evening rush waiting for bus | evening | bus_stop | stationary | in_use | workday | Check route home [E1] (90%) | Check arrival time [F1] (82%) | News digest [D4] (60%) | After-work waiting |
| 3A25001 | Workday morning walk to stop | morning | bus_stop | walking | in_pocket | workday | Check arrival time [F1] (88%) | Listen to music [D1] (74%) | Today's schedule [B1] (60%) | Walking to bus stop |
| 7A25001 | Workday evening walk to stop | evening | bus_stop | walking | in_pocket | workday | Check route home [E1] (85%) | Check step count [G4] (68%) | News digest [D4] (55%) | Walking to bus stop |
| 6A11001 | Workday afternoon bus stop | afternoon | bus_stop | stationary | in_use | workday | Navigate to destination [E7] (85%) | Check weather [C1] (70%) | View schedule [B3] (58%) | Afternoon outing |
| 3A11002 | Weekend bus outing | morning | bus_stop | stationary | in_use | weekend | Check arrival time [F1] (88%) | Navigate to destination [E7] (78%) | Check weather [C1] (68%) | Weekend outing |
| 7A11002 | Weekend evening bus stop | evening | bus_stop | stationary | in_use | weekend | Navigate home [E1] (82%) | Check step count [G4] (65%) | News digest [D4] (55%) | Weekend return home |
| 6A11002 | Weekend afternoon bus stop | afternoon | bus_stop | stationary | in_use | weekend | Navigate to destination [E7] (80%) | Check weather [C1] (68%) | Check step count [G4] (58%) | Weekend outing |
| 3A11003 | Holiday bus outing | morning | bus_stop | stationary | in_use | holiday | Check arrival time [F1] (86%) | Navigate to attraction [E6] (82%) | Check weather [C1] (72%) | Holiday outing |
| 7A11003 | Holiday bus return | evening | bus_stop | stationary | in_use | holiday | Navigate home [E1] (84%) | Check step count [G4] (68%) | News digest [D4] (58%) | Holiday return |

---

### ferry (Ferry Terminal)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 3B11001 | Workday morning ferry | morning | ferry | stationary | in_use | workday | Check ferry schedule [F3] (90%) | Today's itinerary [B1] (80%) | Listen to podcast [D3] (65%) | Long wait time |
| 7B11001 | Workday evening ferry | evening | ferry | stationary | in_use | workday | Check route home [E1] (88%) | News digest [D4] (75%) | Listen to podcast [D3] (68%) | After-work ferry |
| 3B15001 | Workday ferry waiting | morning | ferry | stationary | in_pocket | workday | Check ferry schedule [F3] (85%) | Today's itinerary [B1] (72%) | Weather reminder [C1] (60%) | Dock waiting |
| 6B11001 | Workday afternoon ferry | afternoon | ferry | stationary | in_use | workday | Check ferry schedule [F3] (82%) | Today's schedule [B1] (70%) | Listen to podcast [D3] (62%) | Afternoon outing |
| 3B11002 | Weekend ferry outing | morning | ferry | stationary | in_use | weekend | Check ferry schedule [F3] (88%) | Check weather [C1] (80%) | Navigate to destination [E7] (70%) | Weekend outing |
| 7B11002 | Weekend ferry return | evening | ferry | stationary | in_use | weekend | Navigate home [E1] (85%) | Check step count [G4] (68%) | News digest [D4] (60%) | Weekend return |
| 3B11003 | Holiday ferry outing | morning | ferry | stationary | in_use | holiday | Check ferry schedule [F3] (90%) | View attraction info [E6] (82%) | Check weather [C1] (74%) | Holiday outing |
| 7B11003 | Holiday ferry return | evening | ferry | stationary | in_use | holiday | Navigate home [E1] (86%) | Check step count [G4] (70%) | News digest [D4] (62%) | Holiday return |

---

---

### train_station (Train Station / High-Speed Rail)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 3C21001 | Workday catching train | morning | train_station | walking | in_use | workday | Check itinerary/tickets [B7] (95%) | Navigate to waiting hall [E5] (86%) | Check weather [C1] (55%) | Rushing, itinerary top priority |
| 3C11001 | Workday waiting for train | morning | train_station | stationary | in_use | workday | Check itinerary/tickets [B7] (92%) | View today's schedule [B1] (78%) | Listen to podcast [D3] (62%) | Long wait time |
| 4C11001 | Forenoon train waiting | forenoon | train_station | stationary | in_use | workday | Check itinerary/tickets [B7] (90%) | View news digest [D4] (74%) | Listen to music [D1] (65%) | Forenoon departure waiting |
| 5C11001 | Midday train waiting | lunch | train_station | stationary | in_use | workday | Check itinerary/tickets [B7] (88%) | Navigate to station restaurant [E3] (72%) | Listen to music [D1] (58%) | Midday travel |
| 6C11001 | Afternoon train waiting | afternoon | train_station | stationary | in_use | workday | Check itinerary/tickets [B7] (88%) | Listen to music/podcast [D1] (72%) | View schedule [B3] (60%) | Afternoon departure |
| 7C21001 | Evening train departure | evening | train_station | walking | in_use | workday | Check itinerary/tickets [B7] (90%) | Navigate to waiting hall [E5] (80%) | Contact reminder [I1] (62%) | Evening departure, rushing |
| 7C11001 | Workday station pickup | evening | train_station | stationary | in_use | workday | Navigate [E7] (78%) | Contact reminder [I1] (88%) | Record parking spot [E8] (65%) | Pickup waiting |
| 8C11001 | Night train waiting | night | train_station | stationary | in_use | workday | Check itinerary/tickets [B7] (88%) | Navigate to waiting hall [E5] (74%) | Contact reminder [I1] (65%) | Late-night train |
| 3C21002 | Weekend train travel | morning | train_station | walking | in_use | weekend | Check itinerary/tickets [B7] (90%) | Navigate to waiting hall [E5] (80%) | Check weather [C1] (62%) | Weekend travel, rushing |
| 3C25003 | Holiday crowded station | morning | train_station | walking | in_pocket | holiday | Remind check-in time [B8] (90%) | Watch belongings [J3] (78%) | Navigate to gate [E5] (72%) | Holiday crowds |
| 6C11003 | Holiday train waiting | afternoon | train_station | stationary | in_use | holiday | Check itinerary/tickets [B7] (88%) | Navigate attraction [E6] (70%) | Listen to music [D1] (65%) | Holiday travel |


---

### cafe (Cafe)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 3D13001 | Workday cafe working | morning | cafe | stationary | on_desk | workday | View today's schedule [B1] (88%) | Sedentary reminder [G1] (72%) | Hydration reminder [G2] (65%) | Cafe working, sedentary reminder important |
| 3D11001 | Workday cafe phone use | morning | cafe | stationary | in_use | workday | View today's schedule [B1] (82%) | Dining suggestions [H1] (70%) | View news [D4] (58%) | Morning coffee time |
| 4D13001 | Forenoon cafe working | forenoon | cafe | stationary | on_desk | workday | Sedentary reminder [G1] (90%) | Hydration reminder [G2] (80%) | View schedule [B3] (68%) | WFH/business trip cafe working |
| 4D11002 | Forenoon cafe leisure | forenoon | cafe | stationary | in_use | weekend | Check weather [C1] (75%) | View news digest [D4] (68%) | Play music [D1] (58%) | Weekend cafe leisure |
| 5D11001 | Midday cafe | lunch | cafe | stationary | in_use | workday | Dining suggestions [H1] (86%) | View afternoon schedule [B3] (68%) | Hydration reminder [G2] (55%) | Lunch coffee |
| 6D13001 | Afternoon cafe working | afternoon | cafe | stationary | on_desk | workday | Sedentary reminder [G1] (88%) | Hydration reminder [G2] (78%) | View schedule [B3] (65%) | Afternoon cafe working |
| 6D11002 | Weekend afternoon cafe | afternoon | cafe | stationary | in_use | weekend | Check weather [C1] (72%) | Play music [D1] (65%) | Contact reminder [I1] (55%) | Weekend social coffee |
| 7D11002 | Evening cafe date | evening | cafe | stationary | in_use | weekend | Contact reminder [I1] (78%) | Dining suggestions [H1] (72%) | Navigate home [E1] (55%) | Weekend social gathering |
| 6D11003 | Holiday cafe | afternoon | cafe | stationary | in_use | holiday | Play music [D1] (70%) | Check weather [C1] (65%) | View news [D4] (58%) | Holiday relaxation |

---

### cinema (Movie Theater)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 6E11001 | Workday pre-movie | afternoon | cinema | stationary | in_use | workday | Check showtime/seat [F4] (92%) | Contact reminder [I1] (68%) | Navigate to theater [E5] (62%) | Pre-movie ticket check |
| 6E16001 | Workday during movie | afternoon | cinema | stationary | face_down | workday | Mute notifications [J1] (88%) | Set show-end reminder [B6] (75%) | Silent mode confirm [J2] (70%) | During movie, phone face down |
| 6E15001 | Workday movie, phone pocketed | afternoon | cinema | stationary | in_pocket | workday | Mute notifications [J1] (85%) | Set show-end reminder [B6] (72%) | Silent mode confirm [J2] (68%) | Crowded theater, phone in pocket |
| 6E11002 | Weekend pre-movie | afternoon | cinema | stationary | in_use | weekend | Check showtime/seat [F4] (94%) | Dining suggestions [H1] (74%) | Contact reminder [I1] (65%) | Weekend movie, may buy popcorn |
| 6E16002 | Weekend during movie | afternoon | cinema | stationary | face_down | weekend | Mute notifications [J1] (90%) | Set show-end reminder [B6] (78%) | Silent mode confirm [J2] (72%) | Movie etiquette |
| 7E11002 | Evening pre-movie | evening | cinema | stationary | in_use | weekend | Check showtime/seat [F4] (92%) | Contact reminder [I1] (72%) | Navigate home [E1] (55%) | Evening movie |
| 7E16002 | Evening during movie | evening | cinema | stationary | face_down | weekend | Mute notifications [J1] (88%) | Set show-end reminder [B6] (75%) | Navigate home [E1] (60%) | Evening movie, prep home navigation |
| 6E21003 | Holiday pre-movie | afternoon | cinema | walking | in_use | holiday | Check showtime/seat [F4] (92%) | Dining suggestions [H1] (76%) | Check step count [G4] (48%) | Holiday popular showing, arrive early |
| 6E15003 | Holiday during movie | afternoon | cinema | stationary | in_pocket | holiday | Mute notifications [J1] (90%) | Set show-end reminder [B6] (78%) | Silent mode confirm [J2] (72%) | Holiday crowded theater |

---

### park (Park)

| Code | Title | Time | Location | Motion | Phone | DayType | Rec 1 (Confidence%) | Rec 2 (Confidence%) | Rec 3 (Confidence%) | Notes |
|------|-------|------|----------|--------|-------|---------|---------------------|---------------------|---------------------|-------|
| 2F35001 | Workday dawn park run | dawn | park | running | in_pocket | workday | Check step count [G4] (90%) | Hydration reminder [G2] (82%) | Play music [D1] (74%) | Morning park run |
| 3F25001 | Workday park walk | morning | park | walking | in_pocket | workday | Check step count [G4] (86%) | Check weather [C1] (72%) | Play music [D1] (68%) | Pre-work park morning walk |
| 5F11001 | Midday park rest | lunch | park | stationary | in_use | workday | View afternoon schedule [B3] (78%) | Hydration reminder [G2] (70%) | Stretch reminder [G3] (60%) | Lunch break at park |
| 6F35001 | Afternoon park run | afternoon | park | running | in_pocket | workday | Check step count [G4] (92%) | Hydration reminder [G2] (88%) | Play music [D1] (78%) | Pre-off-work run |
| 7F25001 | Workday evening park | evening | park | walking | in_pocket | workday | Check step count [G4] (84%) | Play music [D1] (72%) | Check weather [C1] (60%) | After-work walk |
| 3F35002 | Weekend park morning run | morning | park | running | in_pocket | weekend | Check step count [G4] (94%) | Hydration reminder [G2] (88%) | Play music [D1] (80%) | Weekend morning run |
| 3F21002 | Weekend park stroll | morning | park | walking | in_use | weekend | Check step count [G4] (84%) | Check weather [C1] (72%) | View news digest [D4] (62%) | Weekend park stroll with phone |
| 6F11002 | Weekend park picnic | afternoon | park | stationary | in_use | weekend | Check weather [C1] (80%) | Contact reminder [I1] (70%) | Check step count [G4] (58%) | Weekend park leisure |
| 6F25003 | Holiday park tour | afternoon | park | walking | in_pocket | holiday | Check step count [G4] (86%) | Navigate attraction [E6] (74%) | Check weather [C1] (68%) | Holiday park |
| 3F35003 | Holiday park run | morning | park | running | in_pocket | holiday | Check step count [G4] (92%) | Hydration reminder [G2] (86%) | Play music [D1] (76%) | Holiday morning run |


## Light/Sound Modifier Tables

### Light Modifiers

| Light Value | Typical Scenario | Recommendation Adjustment Strategy |
|-------------|------------------|-----------------------------------|
| **dark** | Late night lights off, bedtime, dark room | 1. Add "reduce screen brightness reminder" (confidence 70%) 2. Sleep-related recs (set alarm/rest reminder) confidence +10% 3. Reading/browsing recs (news) confidence -15% (eye protection) |
| **dim** | Evening indoors, dim restaurant, bedside lamp | 1. Minor overall adjustments 2. If time in {night, late_night}, sleep recs +5% 3. Reading recs -8% |
| **normal** | Daytime indoors, lit office | Baseline state, no adjustments |
| **bright** | Sunny outdoors, bright mall, direct sunlight | 1. If location=outdoor, step count/weather recs +8% 2. Screen brightness-related reminders deprioritized 3. Outdoor navigation recs +5% |

### Sound Modifiers

| Sound Value | Typical Scenario | Recommendation Adjustment Strategy |
|-------------|------------------|-----------------------------------|
| **quiet** | Late night at home, library, focused work | 1. Play music rec confidence -20% (already quiet enough) 2. If time in {night, sleeping}, rest/sleep reminder +10% 3. Voice features suggest switching to silent/text mode |
| **normal** | Regular indoors, general environment | Baseline state, no adjustments |
| **noisy** | Noisy restaurant, gym, busy outdoor area, subway station | 1. Play music confidence -15% (poor in noisy environment) 2. Dining suggestions maintain highest priority 3. Navigation recs switch to visual-only mode (no voice guidance) 4. Call/contact reminder confidence -10% |
| **unknown** | No microphone data | No adjustments, use base recommendations |

### Combined Modifier Examples

| Typical Scenario | Light | Sound | Combined Adjustment Effect |
|------------------|-------|-------|---------------------------|
| Late night browsing in bed | dark | quiet | Rest reminder +20%; play music -20%; add screen brightness reminder |
| Gym running | normal | noisy | Play music -15%; hydration reminder maintained; navigation visual mode |
| Night driving home | dim | normal | Navigation maintains highest priority; sleep recs +5% |
| Sunny outdoor walk | bright | normal | Step count/weather recs +8%; outdoor navigation +5% |
| Noisy restaurant dining | normal | noisy | Dining suggestions maintain highest; contact reminder -10% |
| Dim restaurant at night | dim | noisy | Reading recs -8%; dining suggestions maintained; contact reminder -10% |
| Bright outdoor exercise | bright | normal | Step count recs +8%; hydration reminder maintained |
| Subway station morning rush | normal | noisy | Music -15%; arrival time maintains highest; navigation visual mode |

---

## Usage Guide

### Query Flow

```
1. Get user's current 7-tuple: (time, location, motion, phone, light, sound, dayType)
2. Check filter rules F1-F15; if matched, mark as invalid combination (skip)
3. Check low-weight rules LW1-LW2; if matched, reduce overall confidence by -15%
4. Look up matching row in main matrix by (time, location, motion, phone, dayType)
5. Get base recommendation list and confidence values
6. Apply light modifier to adjust confidence
7. Apply sound modifier to adjust confidence
8. Sort by final confidence descending, take top 3 as recommendation output
```

### Fuzzy Matching Fallback Strategy

When no exact match is found, progressively fall back by priority:

| Level | Match Dimensions | Description |
|-------|-----------------|-------------|
| L1 (Exact) | time + location + motion + phone + dayType | Fully exact match |
| L2 | time + location + motion + phone | Ignore day type |
| L3 | time + location + motion | Ignore phone state |
| L4 (Fallback) | time + location | Only time + location coarse match |

### Confidence Thresholds

| Confidence Range | Behavior Strategy |
|-----------------|-------------------|
| **>=75%** | Proactive push (no user query needed, pop up card directly) |
| **50-74%** | Candidate recommendation (display in recommendation list, await user selection) |
| **25-49%** | Low priority (only shown when user actively asks) |
| **<25%** | Not recommended (confidence too low, skip) |
