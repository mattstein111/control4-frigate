# Config-driven detection labels

**Date:** 2026-08-14
**Issues:** [#28](https://github.com/mattstein111/control4-frigate/issues/28) (audio labels), [#29](https://github.com/mattstein111/control4-frigate/issues/29) (object labels)
**Status:** Design approved, pending implementation plan
**Baseline:** camera driver v44, NVR driver v49, release v0.9.0-rc.1

## Problem

The driver hardcodes the set of Frigate detection labels it listens for, in two places per detection kind — the MQTT subscription list and a handler-side whitelist. Frigate's actual labels come from its own configuration and differ per camera. The two drift, and every failure is silent.

Three symptoms of one root cause, all confirmed on a live 13-camera system:

**1. Object labels (#29) — losing events today.** `front_door` tracks `person` and `package`; the driver subscribes only to `person`, `car`, `dog`, `cat`. Package detections never reach Control4. Confirmed on the broker: `frigate/front_door/package/snapshot` is a live retained topic. Zones are affected identically, since zone subscriptions carry the same four labels.

**2. Audio labels (#28).** Frigate is configured to listen for `bark, fire_alarm, scream, speech, yell, glass, shatter, car_alarm`. The driver subscribes to `speech, bark, scream, yell, fire_alarm, glass_breaking, siren, car_horn, music`. Five of eight match; `glass`, `shatter` and `car_alarm` are lost. `siren` and `music` are subscribed but never published.

**3. History type strings.** `handleAudio()` builds its history type via `friendlyObject()`, which capitalises only the first character, producing `Audio: Fire alarm` while the History agent registration says `Audio: Fire Alarm`. Per the #24 finding, Navigator renders only history matching a registration, so those entries never appear in the app.

Each symptom is the same shape: a label transformed or enumerated in one place and hardcoded in another, with nothing asserting the two agree.

There is also dead code that documents the original intent. `handleDetection()` has a generic `else` branch firing `Object Detected` for unrecognised labels, and `friendlyObject()` title-cases arbitrary strings — but the branch can never execute, because the NVR filters to four labels before forwarding.

## Scope

In scope: deriving both subscription sets and the handler whitelist from Frigate's configuration; a single canonical label mapping; per-camera history registration; first-class support for `package` and `car_alarm`.

Out of scope: changing how detections are processed once routed, the notification-image feature, and anything in the deferred half of #25.

## Verified facts this design rests on

| Fact | Evidence |
|---|---|
| Object counts publish on `frigate/<camera>/<label>` | `frigate/<cam>/<label>/snapshot` retained for every tracked label |
| Zone counts publish on `frigate/<camera>/<zone>/<label>` | live retained topic `frigate/thelma/illegal_parking/car` |
| Audio publishes on `frigate/<camera>/audio/<label>` | live `rms` / `dBFS` on the same tree |
| `objects.track` is per-camera overridable | 5 of 13 cameras differ from the global list |
| `audio.listen` is per-camera overridable | schema exposes it per camera; 13/13 currently inherit |
| The driver already fetches `/api/config` | `nvr-driver/driver.lua:588` (discovery), `:667` (MQTT auto-populate) |
| Parsing cost is negligible | 0.173 ms for a 13-camera union over a 150 KB config, measured under LuaJIT |

## Design

### 1. Label resolution (NVR)

During discovery, parse from the config response already being fetched:

- global `objects.track` and `audio.listen`
- each camera's resolved `objects.track` and `audio.listen`

Produce two unions — object labels and audio labels — plus a per-camera record of that camera's own labels, which section 5 needs.

No additional network request. The parse reuses the existing `jsonString` / `%b{}` helpers.

### 2. Subscriptions and whitelist (NVR)

Build from the unions:

```
frigate/+/<object_label>            -- object counts
frigate/+/+/<object_label>          -- zone counts
frigate/+/audio/<audio_label>       -- audio detections
```

The handler-side whitelist is **generated from the same unions**, not written separately. This is the structural fix: the two lists cannot disagree because there is only one list.

The four-label filter in `onMQTTMessage` is removed. Any label that arrives was subscribed to deliberately.

Audio telemetry (`rms`, `dBFS`) remains excluded because subscriptions stay explicit per label — the #23 protection is preserved, and a regression test pins it.

### 3. One canonical mapping table

A single table maps each known Frigate label to its friendly name, event name and variable. It is the only source for the fired event, the recorded history type, and the registration — so the section-3 title-case class of bug becomes impossible rather than merely fixed.

```lua
OBJECT_LABELS = {
  person  = { friendly = "Person",  detected = "Person Detected",  left = "Person Left",
              var_bool = "PERSON_DETECTED", var_seen = "PERSON_LAST_SEEN", var_count = "PERSON_COUNT" },
  car     = { … },
  dog     = { … },
  cat     = { … },
  package = { friendly = "Package", detected = "Package Detected", left = "Package Left",
              var_bool = "PACKAGE_DETECTED", var_seen = "PACKAGE_LAST_SEEN" },
}

AUDIO_LABELS = {
  speech     = { friendly = "Speech",         event = "Audio: Speech",         var = "SPEECH_LAST_HEARD" },
  glass      = { friendly = "Glass Breaking", event = "Audio: Glass Breaking", var = "GLASS_BREAKING_LAST_HEARD" },
  shatter    = { friendly = "Glass Breaking", event = "Audio: Glass Breaking", var = "GLASS_BREAKING_LAST_HEARD" },
  car_alarm  = { friendly = "Car Alarm",      event = "Audio: Car Alarm",      var = "CAR_ALARM_LAST_HEARD" },
  …
}
```

`glass` and `shatter` deliberately share an event and variable — the distinction is acoustic, not meaningful. `car_alarm` is deliberately separate from `car_horn`: a car alarm is a security event, a horn is not.

Legacy labels (`glass_breaking`, `siren`, `music`, `car_horn`) stay in the table. They cost nothing and may be valid on other Frigate versions; removing them would break anyone whose config uses them.

### 4. Unmapped labels

A label absent from the table — `bicycle`, or a class Frigate adds later — is handled generically rather than dropped:

- friendly name = title-cased label with underscores replaced (`fire_hydrant` → `Fire Hydrant`)
- fires the generic `Object Detected` / `Object Left` or `Audio Detected`
- records history as `<Friendly> Detected` / `Audio: <Friendly>`
- updates `Last Event`
- no dedicated variable

This finally activates the generic branch that has always existed in `handleDetection()`.

### 5. Per-camera history registration

Navigator renders history only when the recorded `(category, subcategory, type)` matches a `C4:RegisterEvents` registration. Since labels are now dynamic, the registration must be too.

The NVR sends each camera its own resolved label list — extending the existing `SET_FRIGATE_CONFIG` command rather than adding a new one. The camera driver builds its registered type list from those labels via the canonical mapping (plus the static types: motion, zone, loitering, health, state changes) and registers exactly what it can emit.

`front_door` registers `Package Detected`; `bbq` does not.

**Registration timing.** `registerNotificationEvents()` currently runs once in `OnDriverLateInit()`. It must re-run when a label list arrives. Two behaviours are unverified and must be established during implementation, before relying on either:

1. whether a second `C4:RegisterEvents` call **replaces** the prior registration or **adds** to it; and
2. whether registering a type that is never emitted causes any harm.

**Default behaviour, safe under either semantics:** build the complete registration — static types plus every type derivable from the received labels — and send it in a **single** `C4:RegisterEvents` call each time the label list arrives. This is correct whether registration replaces or accumulates, so implementation is not blocked on answering the question.

Answer it opportunistically during hardware testing and record the result in `~/.claude/c4-conventions.md` — it is a reusable C4 truth, and if registration turns out to be additive, a later simplification becomes available.

Until a label list arrives, the camera registers the canonical static set, so a camera that never receives config still behaves as it does today.

### 6. New first-class labels

| Event | ID | Variables |
|---|---|---|
| `Package Detected` | 30 | `PACKAGE_DETECTED` (BOOL), `PACKAGE_LAST_SEEN` (STRING) |
| `Package Left` | 31 | — |
| `Audio: Car Alarm` | 32 | `CAR_ALARM_LAST_HEARD` (STRING) |

Packages persist, so they get boolean state — enabling "a package is present and nobody has been detected for 10 minutes". Audio types are momentary and follow the existing timestamp-only pattern.

`driver.xml` grows from 29 to 32 events and from 29 to 32 variables. (Note: the README badge claims 27 variables and is already stale — correct it to 32 in the same change.)

### 7. Fallback and failure handling

If the config fetch fails, is unparseable, or contains no `objects`/`audio` section, fall back to the current hardcoded lists and log a warning naming the consequence. Behaviour is then exactly today's — never worse.

A camera present in MQTT but absent from the config contributes nothing to the union; it still receives any label in the union, since subscriptions use the `+` wildcard for camera.

### 8. Observability

Log the resolved sets at INFO during discovery:

```
Subscribed to objects: car, package, person | audio: bark, car_alarm, fire_alarm, glass, scream, shatter, speech, yell
```

All three symptoms were invisible because nothing ever stated what the driver was listening for. This line makes the drift visible the moment it happens.

## Testing

Extends the committed harnesses, which run under LuaJIT in CI.

**NVR (`test/nvr_test.lua`):**

| Case | Expected |
|---|---|
| Union across cameras with differing `objects.track` | union includes every camera's labels |
| Per-camera `audio.listen` override | union includes the override's labels |
| Config with no `objects`/`audio` section | falls back to the hardcoded lists, warns |
| Malformed config | falls back, does not raise |
| Subscription list vs handler whitelist | identical sets — the drift assertion |
| `rms` / `dBFS` never subscribed | absent from the subscription list regardless of config |
| Unmapped label forwarded | reaches the camera rather than being filtered |

**Camera (`test/driver_test.lua`):**

| Case | Expected |
|---|---|
| `package` detection | fires `Package Detected` + `Object Detected`, sets both variables |
| Unmapped label `bicycle` | fires `Object Detected`, history reads `Bicycle Detected` |
| `glass` and `shatter` | both fire `Audio: Glass Breaking`, both set `GLASS_BREAKING_LAST_HEARD` |
| `car_alarm` | fires `Audio: Car Alarm`, sets `CAR_ALARM_LAST_HEARD` |
| Every emitted history type | present in the `RegisterEvents` registration — extends the existing cross-check to the dynamic label set |
| Title-case regression | `fire_alarm` records as `Audio: Fire Alarm`, matching registration |

The registration cross-check is the important one: it is what would have caught symptom 3, and it must now hold for dynamically resolved labels.

## Compatibility

The driver has external users on the `Beta` auto-update channel.

- Anyone whose Frigate tracks only `person`/`car`/`dog`/`cat` sees no behavioural change.
- Anyone tracking additional labels starts receiving events that were previously dropped — strictly additive, and the point of the change.
- `dog` and `cat` disappear from subscriptions where Frigate does not track them. No user-visible effect; their events remain declared in `driver.xml`.
- A config-fetch failure reproduces today's behaviour exactly.

No property changes and no migration required.

## Files affected

| File | Change |
|---|---|
| `nvr-driver/driver.lua` | Label resolution, config-derived subscriptions, whitelist generation, remove the four-label filter, extend `SET_FRIGATE_CONFIG`, resolved-set logging |
| `camera-driver/driver.lua` | Canonical mapping table, generic unmapped-label handling, package handling, dynamic registration from received labels |
| `camera-driver/driver.xml` | 3 events, 3 variables, `<version>` bump |
| `nvr-driver/driver.xml` | `<version>` bump |
| `test/nvr_test.lua`, `test/driver_test.lua` | Cases above |
| `CHANGELOG.md`, `README.md` | Release entry; document package/car-alarm events and config-driven behaviour |

## Success criteria

A package detected at `front_door` fires `Package Detected` in Composer, sets `PACKAGE_DETECTED`, and appears in the Control4 app's history. Adding a label to Frigate's config and re-running discovery makes that label's events flow without a driver release. The startup log states exactly which labels are subscribed. `Audio: Fire Alarm` history appears in the app, which it does not today.
