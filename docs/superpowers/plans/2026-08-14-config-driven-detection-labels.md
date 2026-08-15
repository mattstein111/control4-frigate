# Config-Driven Detection Labels Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Derive the driver's MQTT detection-label subscriptions from Frigate's own per-camera configuration instead of hardcoding them, so labels can never silently drift out of sync again.

**Architecture:** The NVR driver parses `objects.track` and `audio.listen` — global and per camera — out of the `/api/config` response it already fetches during discovery, builds a union, and generates both its MQTT subscriptions and its handler whitelist from that single source. Each camera driver is told its own label list and registers exactly the history types it can emit. A single canonical mapping table in the camera driver maps every known label to its friendly name, event and variable; unknown labels fall through to the generic `Object Detected` / `Audio Detected` path that already exists but is currently unreachable.

**Tech Stack:** Lua 5.1 / LuaJIT (Control4 DriverWorks), Frigate HTTP API, MQTT. Tests are standalone Lua scripts mocking the `C4` global; no framework.

**Spec:** `docs/superpowers/specs/2026-08-14-config-driven-detection-labels-design.md`

## Global Constraints

- **Target runtime is LuaJIT / Lua 5.1** (Control4 Director). No `goto`, no `//` integer division, no `<const>`.
- **Run every test with `luajit`** (`/opt/homebrew/bin/luajit`), never the system `lua` (5.5, different semantics).
- **`C4:SendToDevice` serialises all params as strings.** A Lua table will not survive the boundary — label lists cross as comma-separated strings. Booleans arrive as the strings `"true"` / `"false"`, and `"false"` is truthy in Lua.
- **`C4:RecordHistory` takes four arguments** — `(severity, eventType, category, subcategory)`. The documented fifth metadata table stops records being stored on OS 3.4.3.
- **Recorded history `(category, subcategory, type)` must match a `C4:RegisterEvents` registration** or Navigator will not display it. Category `Cameras`, subcategory `Frigate`.
- **`C4:RegisterEvents` may be called in or after `OnDriverLateInit`**; failures auto-retry every 30s; returns `0` success, `-1` fail, `-6` history DB not ready.
- **Never subscribe to `frigate/+/audio/rms` or `.../dBFS`** — telemetry at ~26 msg/s that floods `Last Event` (issue #23).
- **The driver has external users.** This release contains a breaking change that must be prominent in the release notes.
- Baseline at plan time: camera driver **v44**, NVR driver **v49**, release **v0.9.0-rc.1**.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `nvr-driver/driver.lua` | Parse labels from config; build subscriptions and whitelist from the union; forward per-camera labels | Modify |
| `camera-driver/driver.lua` | Canonical label mapping; generic unmapped handling; package/car-alarm; dynamic registration | Modify |
| `camera-driver/driver.xml` | +3 events / +3 variables, −3 events / −3 variables | Modify |
| `nvr-driver/driver.xml` | Version bump | Modify |
| `test/nvr_test.lua` | Label resolution, subscription/whitelist parity, telemetry exclusion | Modify |
| `test/driver_test.lua` | Mapping, generic path, package, registration parity | Modify |
| `CHANGELOG.md`, `README.md` | Release entry with breaking change; document new events | Modify |

Tasks 1–3 are NVR-side and independently testable. Tasks 4–6 are camera-side. Task 7 releases.

---

### Task 1: Parse detection labels from Frigate config

Pure parsing, no behaviour change yet. Nothing subscribes differently until Task 2.

**Files:**
- Modify: `nvr-driver/driver.lua` (add functions near the JSON helpers, ~line 256)
- Modify: `test/nvr_test.lua`

**Interfaces:**
- Consumes: nothing
- Produces: two globals used by Tasks 2 and 3.
  - `parseDetectionLabels(payload)` → returns `objectUnion, audioUnion, perCamera` where the unions are **sorted arrays of strings** and `perCamera` is a table keyed by camera name with `{ objects = {…}, audio = {…} }` (each a sorted array). Returns `nil` if the payload has no parseable `cameras` block.

- [ ] **Step 1: Write the failing test**

Append to `test/nvr_test.lua`, immediately before the final `realWrite(...)` summary line:

```lua
------------------------------------------------------------------------
-- Label parsing from Frigate config (#28, #29)
------------------------------------------------------------------------
local CFG = [[
{"objects":{"track":["person"]},
 "audio":{"enabled":true,"listen":["bark","speech"]},
 "cameras":{
   "bbq":{"objects":{"track":["person"]},"audio":{"enabled":true,"listen":["bark","speech"]}},
   "front_door":{"objects":{"track":["person","package"]},"audio":{"enabled":true,"listen":["bark","speech","glass"]}},
   "gate":{"objects":{"track":["person","car"]},"audio":{"enabled":true,"listen":["bark","speech"]}}}}
]]

local function joined(t) return table.concat(t, ",") end

local objU, audU, perCam = parseDetectionLabels(CFG)
check("parseDetectionLabels returns a result", objU ~= nil)
check("object union spans all cameras", joined(objU) == "car,package,person", objU and joined(objU))
check("audio union spans all cameras", joined(audU) == "bark,glass,speech", audU and joined(audU))
check("per-camera objects for front_door",
      perCam and joined(perCam.front_door.objects) == "package,person",
      perCam and perCam.front_door and joined(perCam.front_door.objects))
check("per-camera audio for bbq excludes glass",
      perCam and joined(perCam.bbq.audio) == "bark,speech",
      perCam and perCam.bbq and joined(perCam.bbq.audio))

-- A camera with no audio block still contributes its objects.
local CFG2 = [[
{"objects":{"track":["person"]},"audio":{"listen":["bark"]},
 "cameras":{"cam1":{"objects":{"track":["person","dog"]}}}}
]]
local o2, a2, p2 = parseDetectionLabels(CFG2)
check("camera without audio block still parses", o2 ~= nil)
check("its objects are included", o2 and joined(o2) == "dog,person", o2 and joined(o2))

-- Malformed and empty payloads return nil rather than raising.
local ok3 = pcall(parseDetectionLabels, "not json")
check("malformed payload does not raise", ok3)
check("malformed payload returns nil", select(1, parseDetectionLabels("not json")) == nil)
check("empty payload returns nil", select(1, parseDetectionLabels("")) == nil)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/nvr_test.lua nvr-driver/driver.lua`
Expected: FAIL — `attempt to call a nil value (global 'parseDetectionLabels')`.

- [ ] **Step 3: Implement the parser**

In `nvr-driver/driver.lua`, immediately after the `jsonAfterObject` helper (added in the v0.8.16 work, ~line 256), add:

```lua
--- Extract a JSON string array like "listen":["a","b"] into a Lua array.
local function jsonStringArray(json, key)
    local body = json:match('"' .. key .. '"%s*:%s*%[([^%]]*)%]')
    if not body then return nil end
    local out = {}
    for v in body:gmatch('"([^"]+)"') do out[#out + 1] = v end
    return out
end

--- Parse the detection labels Frigate is configured to produce.
--- Returns objectUnion, audioUnion, perCamera — unions are sorted arrays;
--- perCamera maps camera name to { objects = {...}, audio = {...} }.
--- Returns nil if the payload has no parseable cameras block (#28, #29).
function parseDetectionLabels(payload)
    if type(payload) ~= "string" or payload == "" then return nil end

    local camerasBlock = payload:match('"cameras"%s*:%s*(%b{})')
    if not camerasBlock then return nil end

    local objSet, audSet, perCamera = {}, {}, {}

    for camName, camBody in camerasBlock:gmatch('"([%w_%-]+)"%s*:%s*(%b{})') do
        local objBlock = camBody:match('"objects"%s*:%s*(%b{})')
        local audBlock = camBody:match('"audio"%s*:%s*(%b{})')
        local objs = objBlock and jsonStringArray(objBlock, "track") or {}
        local auds = audBlock and jsonStringArray(audBlock, "listen") or {}

        for _, l in ipairs(objs) do objSet[l] = true end
        for _, l in ipairs(auds) do audSet[l] = true end
        perCamera[camName] = { objects = objs, audio = auds }
    end

    local function sortedKeys(set)
        local out = {}
        for k in pairs(set) do out[#out + 1] = k end
        table.sort(out)
        return out
    end

    for _, info in pairs(perCamera) do
        table.sort(info.objects)
        table.sort(info.audio)
    end

    return sortedKeys(objSet), sortedKeys(audSet), perCamera
end
```

Note: only per-camera values are unioned. Frigate resolves inheritance before serving `/api/config`, so every camera's block already carries its effective list; reading the global as well would add nothing and could wrongly include labels no camera tracks.

- [ ] **Step 4: Run the test to verify it passes**

Run: `luajit test/nvr_test.lua nvr-driver/driver.lua`
Expected: `ALL PASS`.

- [ ] **Step 5: Commit**

```bash
git add nvr-driver/driver.lua test/nvr_test.lua
git commit -m "feat(nvr): parse detection labels from Frigate config (#28, #29)

Adds parseDetectionLabels(), which extracts objects.track and
audio.listen per camera from the /api/config payload the driver already
fetches, returning sorted unions plus a per-camera breakdown.

Frigate resolves config inheritance before serving /api/config, so each
camera's block already carries its effective list — only per-camera
values are unioned.

No behaviour change yet; nothing consumes this until the subscription
work lands."
```

---

### Task 2: Build subscriptions and whitelist from the resolved labels

**Files:**
- Modify: `nvr-driver/driver.lua` — `subscribeFrigateTopics()` (~line 278), `onMQTTMessage()` object/zone branches (~line 417), `AUDIO_DETECTION_TYPES` (line 272), `fetchCameras()` (~line 580)
- Modify: `test/nvr_test.lua`

**Interfaces:**
- Consumes: `parseDetectionLabels(payload)` from Task 1
- Produces:
  - `RESOLVED_OBJECT_LABELS` / `RESOLVED_AUDIO_LABELS` — module-level arrays, defaulting to the fallback lists, replaced when config parses successfully
  - `buildSubscriptionTopics(objectLabels, audioLabels)` → sorted array of topic strings
  - `setResolvedLabels(objectUnion, audioUnion)` — assigns the two globals and rebuilds the audio whitelist

- [ ] **Step 1: Write the failing test**

Append to `test/nvr_test.lua` before the summary line:

```lua
------------------------------------------------------------------------
-- Subscriptions derived from resolved labels (#28, #29)
------------------------------------------------------------------------
local function has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end

local topics = buildSubscriptionTopics({"person","package"}, {"bark","glass"})
check("subscribes to object counts", has(topics, "frigate/+/person") and has(topics, "frigate/+/package"))
check("subscribes to zone counts", has(topics, "frigate/+/+/person") and has(topics, "frigate/+/+/package"))
check("subscribes to audio labels", has(topics, "frigate/+/audio/bark") and has(topics, "frigate/+/audio/glass"))
check("still subscribes to frigate/events", has(topics, "frigate/events"))
check("still subscribes to motion", has(topics, "frigate/+/motion"))

-- The #23 protection: telemetry must never be subscribed to, whatever the config says.
check("never subscribes to audio rms", not has(topics, "frigate/+/audio/rms"))
check("never subscribes to audio dBFS", not has(topics, "frigate/+/audio/dBFS"))
local dirty = buildSubscriptionTopics({"person"}, {"bark","rms","dBFS"})
check("telemetry labels are filtered out of audio subscriptions",
      not has(dirty, "frigate/+/audio/rms") and not has(dirty, "frigate/+/audio/dBFS"))
check("no bare wildcard subscription", not has(topics, "frigate/+/+") and not has(topics, "frigate/#"))

-- Whitelist and subscriptions come from one source and cannot disagree.
setResolvedLabels({"person","package"}, {"bark","glass"})
check("whitelist matches resolved audio labels",
      AUDIO_DETECTION_TYPES.bark == true and AUDIO_DETECTION_TYPES.glass == true)
check("whitelist excludes unresolved audio labels", AUDIO_DETECTION_TYPES.speech == nil)
check("whitelist never contains telemetry",
      AUDIO_DETECTION_TYPES.rms == nil and AUDIO_DETECTION_TYPES.dBFS == nil)

-- An object label outside the old four must now be forwarded.
sent = {}
handleMQTTForTest("frigate/front_door/package", "1")
local pk = findSent("FRIGATE_DETECTION")
check("package count message is forwarded", pk ~= nil)
check("forwarded with the right object type", pk and pk.params.object_type == "package",
      pk and pk.params.object_type)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/nvr_test.lua nvr-driver/driver.lua`
Expected: FAIL — `attempt to call a nil value (global 'buildSubscriptionTopics')`.

- [ ] **Step 3: Add the resolved-label state and topic builder**

Replace the `AUDIO_DETECTION_TYPES` block (line 272) with:

```lua
-- Audio telemetry that must never be subscribed to: Frigate publishes these
-- ~1/second per camera and they would flood Last Event (issue #23).
local AUDIO_TELEMETRY = { rms = true, dBFS = true, state = true }

-- Fallback label sets, used when the Frigate config cannot be read. These
-- reproduce the pre-config-driven behaviour exactly.
local FALLBACK_OBJECT_LABELS = { "person", "car", "dog", "cat" }
local FALLBACK_AUDIO_LABELS  = { "speech", "bark", "scream", "yell", "fire_alarm" }

RESOLVED_OBJECT_LABELS = FALLBACK_OBJECT_LABELS
RESOLVED_AUDIO_LABELS  = FALLBACK_AUDIO_LABELS

-- Derived from RESOLVED_AUDIO_LABELS by setResolvedLabels(); never edited
-- directly, so it cannot drift from the subscription list.
AUDIO_DETECTION_TYPES = {}

--- Assign the resolved label sets and rebuild the derived whitelist.
function setResolvedLabels(objectLabels, audioLabels)
    if objectLabels and #objectLabels > 0 then RESOLVED_OBJECT_LABELS = objectLabels end
    if audioLabels  and #audioLabels  > 0 then RESOLVED_AUDIO_LABELS  = audioLabels  end
    AUDIO_DETECTION_TYPES = {}
    for _, l in ipairs(RESOLVED_AUDIO_LABELS) do
        if not AUDIO_TELEMETRY[l] then AUDIO_DETECTION_TYPES[l] = true end
    end
end
setResolvedLabels(FALLBACK_OBJECT_LABELS, FALLBACK_AUDIO_LABELS)

--- Build the full MQTT topic list for the given resolved labels.
function buildSubscriptionTopics(objectLabels, audioLabels)
    local topics = {
        "frigate/available",
        "frigate/events",
        "frigate/+/motion",
        "frigate/+/detect/state",
        "frigate/+/recordings/state",
    }
    for _, l in ipairs(objectLabels or {}) do
        topics[#topics + 1] = "frigate/+/" .. l          -- object counts
        topics[#topics + 1] = "frigate/+/+/" .. l        -- zone counts
    end
    for _, l in ipairs(audioLabels or {}) do
        if not AUDIO_TELEMETRY[l] then
            topics[#topics + 1] = "frigate/+/audio/" .. l
        end
    end
    return topics
end
```

- [ ] **Step 4: Use the builder in `subscribeFrigateTopics()`**

Replace the hardcoded `local topics = { … }` table inside `subscribeFrigateTopics()` with:

```lua
    local topics = buildSubscriptionTopics(RESOLVED_OBJECT_LABELS, RESOLVED_AUDIO_LABELS)
```

Then, after the subscribe loop and before the existing closing log line, add:

```lua
    log(LOG_INFO, "Subscribed to objects: " .. table.concat(RESOLVED_OBJECT_LABELS, ", ")
        .. " | audio: " .. table.concat(RESOLVED_AUDIO_LABELS, ", "))
```

- [ ] **Step 5: Remove the four-label filter**

In `onMQTTMessage()`, the object-count branch currently reads:

```lua
    if #segments == 3 then
        local objType = segments[3]
        if objType == "person" or objType == "car" or objType == "dog" or objType == "cat" then
```

Replace that inner condition with a check against the resolved set:

```lua
    if #segments == 3 then
        local objType = segments[3]
        local tracked = false
        for _, l in ipairs(RESOLVED_OBJECT_LABELS) do
            if l == objType then tracked = true break end
        end
        if tracked then
```

Apply the identical change to the zone branch (`#segments == 4`), which has the same four-label condition on `segments[4]`.

- [ ] **Step 6: Resolve labels during discovery**

In `fetchCameras()`, inside the `C4:urlGet` callback where `strData` is known good (after the `responseCode ~= 200` guard), add before the existing camera parsing:

```lua
        local objU, audU = parseDetectionLabels(strData)
        if objU then
            setResolvedLabels(objU, audU)
        else
            log(LOG_WARNING, "Could not read detection labels from Frigate config — "
                .. "falling back to the built-in label list; some detections may not reach Control4")
        end
```

- [ ] **Step 7: Add the test shim for MQTT routing**

The test drives `onMQTTMessage`, which is a local. Add this at the end of `nvr-driver/driver.lua`, alongside the other test accessors:

```lua
--- Test accessor: route a raw MQTT message the way the broker callback does.
function handleMQTTForTest(topic, payload)
    return onMQTTMessage(nil, 0, topic, payload, 1, false)
end
```

If `onMQTTMessage` is declared `local function onMQTTMessage(...)` above this point it is in scope as an upvalue; no other change is needed.

- [ ] **Step 8: Run the tests to verify they pass**

Run: `luajit test/nvr_test.lua nvr-driver/driver.lua`
Expected: `ALL PASS`.

- [ ] **Step 9: Commit**

```bash
git add nvr-driver/driver.lua test/nvr_test.lua
git commit -m "feat(nvr): derive subscriptions and whitelist from Frigate config (#28, #29)

Subscriptions and the audio whitelist are now generated from one
resolved label set, so they cannot drift apart — the defect behind both
issues. The four-label filter on object and zone messages is replaced by
a check against the resolved set, so package and any other configured
label now reach the camera drivers.

Audio telemetry (rms, dBFS, state) is filtered out of the subscription
list unconditionally, preserving the issue #23 protection whatever the
config says. A failed config read falls back to the previous hardcoded
lists and warns.

Logs the resolved sets at INFO — all three symptoms were invisible
because nothing ever stated what the driver was listening for."
```

---

### Task 3: Forward each camera's own labels

**Files:**
- Modify: `nvr-driver/driver.lua` — the two `SET_FRIGATE_CONFIG` send sites (~line 781 and ~line 823), `fetchCameras()`
- Modify: `test/nvr_test.lua`

**Interfaces:**
- Consumes: `parseDetectionLabels` (Task 1), `setResolvedLabels` (Task 2)
- Produces: `SET_FRIGATE_CONFIG` gains two params, both **comma-separated strings** because `SendToDevice` cannot carry tables:
  - `object_labels` e.g. `"package,person"`
  - `audio_labels` e.g. `"bark,glass,speech"`
  - Also produces `RESOLVED_PER_CAMERA` — module-level table keyed by camera name, `{ objects = {…}, audio = {…} }`, empty until discovery runs.

- [ ] **Step 1: Write the failing test**

Append to `test/nvr_test.lua` before the summary line:

```lua
------------------------------------------------------------------------
-- Per-camera label forwarding (#28, #29)
------------------------------------------------------------------------
RESOLVED_PER_CAMERA = {
    bbq        = { objects = {"person"},          audio = {"bark","speech"} },
    front_door = { objects = {"package","person"}, audio = {"bark","glass","speech"} },
}

sent = {}
sendCameraConfigForTest("front_door", 1586)
local cfg = findSent("SET_FRIGATE_CONFIG")
check("sends SET_FRIGATE_CONFIG", cfg ~= nil)
check("object_labels is a comma-separated string",
      cfg and cfg.params.object_labels == "package,person", cfg and cfg.params.object_labels)
check("audio_labels is a comma-separated string",
      cfg and cfg.params.audio_labels == "bark,glass,speech", cfg and cfg.params.audio_labels)
check("existing params still present",
      cfg and cfg.params.camera_name == "front_door" and cfg.params.host ~= nil)

-- A camera absent from the resolved map must still get a usable config.
sent = {}
sendCameraConfigForTest("unknown_cam", 1600)
local cfg2 = findSent("SET_FRIGATE_CONFIG")
check("unknown camera still receives config", cfg2 ~= nil)
check("unknown camera gets empty label lists",
      cfg2 and cfg2.params.object_labels == "" and cfg2.params.audio_labels == "",
      cfg2 and cfg2.params.object_labels)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/nvr_test.lua nvr-driver/driver.lua`
Expected: FAIL — `attempt to call a nil value (global 'sendCameraConfigForTest')`.

- [ ] **Step 3: Add the per-camera state and a single send helper**

Near `RESOLVED_OBJECT_LABELS` (added in Task 2), add:

```lua
-- Per-camera resolved labels, populated during discovery. Keyed by camera name.
RESOLVED_PER_CAMERA = {}
```

Then, immediately above the first `SET_FRIGATE_CONFIG` send site (~line 778), add a helper so both sites share one implementation:

```lua
--- Send configuration to a camera driver, including that camera's own
--- detection labels. SendToDevice serialises params as strings, so the
--- label lists cross as comma-separated strings, not tables.
local function sendCameraConfig(camName, devId)
    local info = RESOLVED_PER_CAMERA[camName] or { objects = {}, audio = {} }
    C4:SendToDevice(devId, "SET_FRIGATE_CONFIG", {
        host           = Properties[PROP_HOST] or "",
        camera_name    = camName,
        use_sub_stream = Properties[PROP_SUB] or "Yes",
        object_labels  = table.concat(info.objects or {}, ","),
        audio_labels   = table.concat(info.audio   or {}, ","),
    })
end

--- Test accessor.
function sendCameraConfigForTest(camName, devId) return sendCameraConfig(camName, devId) end
```

- [ ] **Step 4: Use the helper at both send sites**

Replace the inline `C4:SendToDevice(devId, "SET_FRIGATE_CONFIG", { … })` block at the orphan-adoption site (~line 781) with:

```lua
    sendCameraConfig(camName, devId)
```

Replace the equivalent block in the discovery loop (~line 823) with:

```lua
                    sendCameraConfig(camName, devId)
```

Both previously built `host` / `camera_name` / `use_sub_stream` locally; those locals may now be unused at those sites — delete any that become unused, leaving anything still referenced by surrounding code.

- [ ] **Step 5: Populate the per-camera map during discovery**

In `fetchCameras()`, extend the block added in Task 2 Step 6:

```lua
        local objU, audU, perCam = parseDetectionLabels(strData)
        if objU then
            setResolvedLabels(objU, audU)
            RESOLVED_PER_CAMERA = perCam or {}
        else
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `luajit test/nvr_test.lua nvr-driver/driver.lua`
Expected: `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add nvr-driver/driver.lua test/nvr_test.lua
git commit -m "feat(nvr): send each camera its own detection labels (#28, #29)

SET_FRIGATE_CONFIG now carries object_labels and audio_labels for the
specific camera, so each camera driver can register exactly the history
types it is able to emit.

The lists cross as comma-separated strings because SendToDevice
serialises params as strings and will not carry a table. Both send sites
now share one helper rather than duplicating the param table."
```

---

### Task 4: Canonical label mapping and the generic path

**Files:**
- Modify: `camera-driver/driver.lua` — `AUDIO_EVENTS` (line 509), `handleAudio()` (line 523), `handleDetection()` (~line 308)
- Modify: `test/driver_test.lua`

**Interfaces:**
- Consumes: nothing from earlier tasks
- Produces:
  - `OBJECT_LABELS` / `AUDIO_LABELS` — module-level canonical mapping tables
  - `labelInfo(label, kind)` → for `kind` `"object"`: `{ friendly, detected, left, var_bool, var_seen, var_count }`; for `"audio"`: `{ friendly, event, var }`. Returns a generated entry for unmapped labels, never `nil`.
  - `friendlyLabel(label)` → title-cased, underscores to spaces (`fire_hydrant` → `Fire Hydrant`)

- [ ] **Step 1: Write the failing test**

Append to `test/driver_test.lua` before the summary line:

```lua
------------------------------------------------------------------------
-- Canonical label mapping and the generic path (#28, #29)
------------------------------------------------------------------------
check("friendlyLabel title-cases every word", friendlyLabel("fire_hydrant") == "Fire Hydrant",
      friendlyLabel("fire_hydrant"))
check("friendlyLabel handles a single word", friendlyLabel("bicycle") == "Bicycle")

local gi = labelInfo("glass", "audio")
check("glass maps to Audio: Glass Breaking", gi.event == "Audio: Glass Breaking", gi.event)
check("glass uses the glass-breaking variable", gi.var == "GLASS_BREAKING_LAST_HEARD", gi.var)
local sh = labelInfo("shatter", "audio")
check("shatter shares the glass event", sh.event == "Audio: Glass Breaking", sh.event)
check("shatter shares the glass variable", sh.var == "GLASS_BREAKING_LAST_HEARD", sh.var)
local ca = labelInfo("car_alarm", "audio")
check("car_alarm is its own event", ca.event == "Audio: Car Alarm", ca.event)
check("car_alarm has its own variable", ca.var == "CAR_ALARM_LAST_HEARD", ca.var)

check("removed label siren is no longer mapped", labelInfo("siren", "audio").event == "Audio Detected",
      labelInfo("siren", "audio").event)
local unk = labelInfo("didgeridoo", "audio")
check("unmapped audio falls back to the generic event", unk.event == "Audio Detected", unk.event)
check("unmapped audio has a friendly name", unk.friendly == "Didgeridoo", unk.friendly)
check("unmapped audio has no variable", unk.var == nil)

local bike = labelInfo("bicycle", "object")
check("unmapped object gets a generated detected name", bike.detected == "Bicycle Detected", bike.detected)
check("unmapped object gets a generated left name", bike.left == "Bicycle Left", bike.left)
check("unmapped object has no variables", bike.var_bool == nil and bike.var_seen == nil)

-- Title-case regression: fire_alarm history must match its registration exactly.
events, history = {}, {}
pcall(ExecuteCommand, "FRIGATE_AUDIO", { audio_type = "fire_alarm" })
local fh = history[1]
check("fire_alarm history type is title-cased", fh and fh.etype == "Audio: Fire Alarm", fh and fh.etype)
check("fire_alarm history type is registered", fh and registeredTypes[fh.etype] == true, fh and fh.etype)

-- An unmapped object must reach the generic branch that was previously dead code.
events, history = {}, {}
pcall(ExecuteCommand, "FRIGATE_DETECTION",
      { object_type = "bicycle", count = 1, event_type = "new" })
local fired = {}
for _, e in ipairs(events) do fired[e] = true end
check("unmapped object fires the generic event", fired["Object Detected"] == true)
check("unmapped object records a named history entry",
      history[1] and history[1].etype == "Bicycle Detected", history[1] and history[1].etype)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/driver_test.lua camera-driver/driver.lua`
Expected: FAIL — `attempt to call a nil value (global 'friendlyLabel')`.

- [ ] **Step 3: Add the mapping tables and lookup**

Replace the whole `AUDIO_EVENTS` table (lines 508–519) with:

```lua
--- Title-case a Frigate label: "fire_hydrant" -> "Fire Hydrant".
function friendlyLabel(label)
    if not label or label == "" then return "Object" end
    local words = {}
    for w in tostring(label):gmatch("[^_%s]+") do
        words[#words + 1] = w:sub(1, 1):upper() .. w:sub(2)
    end
    return table.concat(words, " ")
end

--- Canonical mapping from Frigate label to friendly name, event and variable.
--- This is the ONLY source for the fired event, the recorded history type and
--- the registration, so those three cannot disagree (#28, #29).
OBJECT_LABELS = {
    person  = { friendly = "Person",  detected = "Person Detected",  left = "Person Left",
                var_bool = "PERSON_DETECTED",  var_seen = "PERSON_LAST_SEEN",  var_count = "PERSON_COUNT" },
    car     = { friendly = "Car",     detected = "Car Detected",     left = "Car Left",
                var_bool = "CAR_DETECTED",     var_seen = "CAR_LAST_SEEN",     var_count = "CAR_COUNT" },
    dog     = { friendly = "Dog",     detected = "Dog Detected",     left = "Object Left",
                var_bool = "DOG_DETECTED",     var_seen = "DOG_LAST_SEEN" },
    cat     = { friendly = "Cat",     detected = "Cat Detected",     left = "Object Left",
                var_bool = "CAT_DETECTED",     var_seen = "CAT_LAST_SEEN" },
    package = { friendly = "Package", detected = "Package Detected", left = "Package Left",
                var_bool = "PACKAGE_DETECTED", var_seen = "PACKAGE_LAST_SEEN" },
}

AUDIO_LABELS = {
    speech     = { friendly = "Speech",         event = "Audio: Speech",         var = "SPEECH_LAST_HEARD" },
    bark       = { friendly = "Bark",           event = "Audio: Bark",           var = "BARK_LAST_HEARD" },
    scream     = { friendly = "Scream",         event = "Audio: Scream",         var = "SCREAM_LAST_HEARD" },
    yell       = { friendly = "Yell",           event = "Audio: Yell",           var = "YELL_LAST_HEARD" },
    fire_alarm = { friendly = "Fire Alarm",     event = "Audio: Fire Alarm",     var = "FIRE_ALARM_LAST_HEARD" },
    glass      = { friendly = "Glass Breaking", event = "Audio: Glass Breaking", var = "GLASS_BREAKING_LAST_HEARD" },
    shatter    = { friendly = "Glass Breaking", event = "Audio: Glass Breaking", var = "GLASS_BREAKING_LAST_HEARD" },
    car_alarm  = { friendly = "Car Alarm",      event = "Audio: Car Alarm",      var = "CAR_ALARM_LAST_HEARD" },
}

--- Look up a label. Never returns nil: unmapped labels get a generated entry
--- routed to the generic event, so a detection is never silently dropped.
function labelInfo(label, kind)
    if kind == "audio" then
        local e = AUDIO_LABELS[label]
        if e then return e end
        return { friendly = friendlyLabel(label), event = "Audio Detected" }
    end
    local e = OBJECT_LABELS[label]
    if e then return e end
    local f = friendlyLabel(label)
    return { friendly = f, detected = f .. " Detected", left = f .. " Left" }
end
```

- [ ] **Step 4: Rewrite `handleAudio()` to use the mapping**

Replace the body of `handleAudio()` with:

```lua
local function handleAudio(tParams)
    local audioType = tParams.audio_type or "unknown"
    local info = labelInfo(audioType, "audio")
    local ts = timestamp()

    setVar(VAR.AUDIO_LAST_HEARD, ts)
    if info.var and VAR[info.var] then setVar(VAR[info.var], ts) end

    if info.event ~= "Audio Detected" then fireEvent(info.event) end
    fireEvent("Audio Detected")

    local label = "Audio: " .. info.friendly
    recordHistory(label, "Info", label)
    C4:UpdateProperty(PROP_LAST_EVENT, label .. " — " .. ts)
end
```

The history type is now `info.friendly`, taken from the same table that names the event and feeds the registration — which is what fixes the `Audio: Fire alarm` vs `Audio: Fire Alarm` mismatch.

- [ ] **Step 5: Route unmapped objects through the generic branch**

In `handleDetection()`, replace the `else` branch (the "Generic object" case) with one that uses the mapping:

```lua
    else
        local info = labelInfo(objType, "object")
        if count > 0 and eventType == "new" then
            fireEvent("Object Detected")
            recordHistory(info.detected, "Info", info.detected)
        elseif count == 0 then
            fireEvent("Object Left")
            recordHistory(info.left, "Info", info.left)
        end
    end
```

Leave the `person` / `car` / `dog` / `cat` branches unchanged in this task; Task 5 folds `package` in.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `luajit test/driver_test.lua camera-driver/driver.lua`
Expected: `ALL PASS`.

- [ ] **Step 7: Commit**

```bash
git add camera-driver/driver.lua test/driver_test.lua
git commit -m "feat(camera): canonical label mapping and generic label handling (#28, #29)

One table now maps each Frigate label to its friendly name, event and
variable, and is the only source for the fired event, the recorded
history type and the registration. That structurally fixes the
title-case mismatch where handleAudio recorded 'Audio: Fire alarm'
against a registration reading 'Audio: Fire Alarm', so those entries
never rendered in the app.

glass and shatter deliberately share one event and variable; car_alarm
is separate from car_horn. Unmapped labels get a generated friendly name
and route to the generic Object/Audio Detected path — which activates
the generic branch in handleDetection that has existed since v0.7.0 and
could never previously execute."
```

---

### Task 5: Package and car alarm as first-class detections

**Files:**
- Modify: `camera-driver/driver.lua` — `VAR` table (~line 84), `initVariables()` (~line 174), `handleDetection()` (~line 308), `registerNotificationEvents()` types list
- Modify: `camera-driver/driver.xml` — events and properties
- Modify: `test/driver_test.lua`

**Interfaces:**
- Consumes: `labelInfo` from Task 4
- Produces: variables `PACKAGE_DETECTED`, `PACKAGE_LAST_SEEN`, `CAR_ALARM_LAST_HEARD`; events `Package Detected` (30), `Package Left` (31), `Audio: Car Alarm` (32)

- [ ] **Step 1: Write the failing test**

Append to `test/driver_test.lua` before the summary line:

```lua
------------------------------------------------------------------------
-- Package and car alarm (#28, #29)
------------------------------------------------------------------------
events, history = {}, {}
local okp = pcall(ExecuteCommand, "FRIGATE_DETECTION",
    { object_type = "package", count = 1, event_type = "new" })
check("package detection does not raise", okp)
check("PACKAGE_DETECTED set true", vars.PACKAGE_DETECTED == "true", vars.PACKAGE_DETECTED)
check("PACKAGE_LAST_SEEN populated", (vars.PACKAGE_LAST_SEEN or "") ~= "")
local pf = {}
for _, e in ipairs(events) do pf[e] = true end
check("fires Package Detected", pf["Package Detected"] == true)
check("also fires Object Detected", pf["Object Detected"] == true)
check("package history type is 'Package Detected'",
      history[1] and history[1].etype == "Package Detected", history[1] and history[1].etype)

events, history = {}, {}
pcall(ExecuteCommand, "FRIGATE_DETECTION", { object_type = "package", count = 0, event_type = "end" })
pf = {}
for _, e in ipairs(events) do pf[e] = true end
check("PACKAGE_DETECTED set false", vars.PACKAGE_DETECTED == "false", vars.PACKAGE_DETECTED)
check("fires Package Left", pf["Package Left"] == true)

events, history = {}, {}
pcall(ExecuteCommand, "FRIGATE_AUDIO", { audio_type = "car_alarm" })
pf = {}
for _, e in ipairs(events) do pf[e] = true end
check("fires Audio: Car Alarm", pf["Audio: Car Alarm"] == true)
check("CAR_ALARM_LAST_HEARD populated", (vars.CAR_ALARM_LAST_HEARD or "") ~= "")
check("car alarm history type is 'Audio: Car Alarm'",
      history[1] and history[1].etype == "Audio: Car Alarm", history[1] and history[1].etype)

-- Removed events must no longer be registered by the static set.
check("Audio: Siren is no longer registered", registeredTypes["Audio: Siren"] == nil)
check("Audio: Car Horn is no longer registered", registeredTypes["Audio: Car Horn"] == nil)
check("Audio: Music is no longer registered", registeredTypes["Audio: Music"] == nil)

-- NOTE for Task 6: registration of package/car-alarm types moves from the
-- static list to the per-camera label list. These three "no longer
-- registered" assertions stay valid; the assertions above deliberately check
-- the recorded type string rather than its registration, so they survive
-- that change. Do not convert them to registeredTypes lookups.
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/driver_test.lua camera-driver/driver.lua`
Expected: FAIL — `PACKAGE_DETECTED set true` fails with `nil` (the variable does not exist).

- [ ] **Step 3: Add the new variables, remove the retired ones**

In the `VAR` table, add:

```lua
    PACKAGE_DETECTED  = "PACKAGE_DETECTED",
    PACKAGE_LAST_SEEN = "PACKAGE_LAST_SEEN",
    CAR_ALARM_LAST_HEARD = "CAR_ALARM_LAST_HEARD",
```

and delete these three entries:

```lua
    SIREN_LAST_HEARD          = "SIREN_LAST_HEARD",
    CAR_HORN_LAST_HEARD       = "CAR_HORN_LAST_HEARD",
    MUSIC_LAST_HEARD          = "MUSIC_LAST_HEARD",
```

In `initVariables()`, add:

```lua
    C4:AddVariable(VAR.PACKAGE_DETECTED,     "false", "BOOL")
    C4:AddVariable(VAR.PACKAGE_LAST_SEEN,    "", "STRING")
    C4:AddVariable(VAR.CAR_ALARM_LAST_HEARD, "", "STRING")
```

and delete the three `C4:AddVariable` lines for `SIREN_LAST_HEARD`, `CAR_HORN_LAST_HEARD` and `MUSIC_LAST_HEARD`.

- [ ] **Step 4: Handle package in `handleDetection()`**

Add a branch alongside the existing `dog` / `cat` branches:

```lua
    elseif objType == "package" then
        setVar(VAR.PACKAGE_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.PACKAGE_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Package Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Package Left")
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
```

- [ ] **Step 5: Update the registered type list**

In `registerNotificationEvents()`, in the `types` array: add `"Package Detected"`, `"Package Left"` and `"Audio: Car Alarm"`; remove `"Audio: Siren"`, `"Audio: Car Horn"` and `"Audio: Music"`.

- [ ] **Step 6: Update `driver.xml`**

Add three events inside `<events>`, matching the existing block format:

```xml
    <event>
      <id>30</id>
      <name>Package Detected</name>
      <description>A package was detected by Frigate object detection.</description>
    </event>
    <event>
      <id>31</id>
      <name>Package Left</name>
      <description>A previously detected package is no longer present.</description>
    </event>
    <event>
      <id>32</id>
      <name>Audio: Car Alarm</name>
      <description>A car alarm was detected by Frigate audio detection.</description>
    </event>
```

Delete the `<event>` blocks with ids **22** (`Audio: Siren`), **23** (`Audio: Car Horn`) and **24** (`Audio: Music`). **Leave ids 22–24 vacant — do not renumber any remaining event**, since renumbering risks re-pointing Composer programming bound by identity.

Do not bump `<version>`; Task 7 owns version bumps.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `luajit test/driver_test.lua camera-driver/driver.lua`
Expected: `ALL PASS`.

- [ ] **Step 8: Commit**

```bash
git add camera-driver/driver.lua camera-driver/driver.xml test/driver_test.lua
git commit -m "feat(camera): package and car alarm as first-class detections (#28, #29)

Adds Package Detected / Package Left with PACKAGE_DETECTED and
PACKAGE_LAST_SEEN, and Audio: Car Alarm with CAR_ALARM_LAST_HEARD.
Packages persist, so they get boolean state; audio stays timestamp-only.

BREAKING: removes Audio: Siren, Audio: Car Horn and Audio: Music and
their variables. /api/labels shows Frigate has never emitted any of
them; they were invented rather than observed. Detections of those
labels, if any user has them configured, still surface via the generic
Audio Detected path with correct history, but programming bound to the
three removed events stops firing.

Event ids 22-24 are left vacant rather than reused, so no existing event
identity moves."
```

---

### Task 6: Register history per camera from the received labels

**Files:**
- Modify: `camera-driver/driver.lua` — `ExecuteCommand` `SET_FRIGATE_CONFIG` branch (line 821), `registerNotificationEvents()`
- Modify: `test/driver_test.lua`

**Interfaces:**
- Consumes: `object_labels` / `audio_labels` comma-separated strings from Task 3; `labelInfo` from Task 4
- Produces: `registerNotificationEvents()` gains optional arguments `(objectLabels, audioLabels)` — Lua arrays; called with no arguments it registers the static set exactly as today

- [ ] **Step 1: Write the failing test**

Append to `test/driver_test.lua` before the summary line:

```lua
------------------------------------------------------------------------
-- Per-camera history registration (#28, #29)
------------------------------------------------------------------------
registeredTypes = {}
pcall(ExecuteCommand, "SET_FRIGATE_CONFIG", {
    host = "192.168.1.50", camera_name = "front_door", use_sub_stream = "Yes",
    object_labels = "package,person", audio_labels = "bark,glass",
})

check("registers the camera's object labels",
      registeredTypes["Package Detected"] == true and registeredTypes["Person Detected"] == true)
check("registers the camera's audio labels",
      registeredTypes["Audio: Bark"] == true and registeredTypes["Audio: Glass Breaking"] == true)
check("does not register labels this camera lacks", registeredTypes["Car Detected"] == nil)
check("still registers static types",
      registeredTypes["Motion Detected"] == true and registeredTypes["Camera Offline"] == true)
check("registration category is unchanged", registeredCategory == "Cameras", registeredCategory)
check("registration subcategory is unchanged", registeredSubcategory == "Frigate", registeredSubcategory)

-- Empty label lists must not wipe the static registration.
registeredTypes = {}
pcall(ExecuteCommand, "SET_FRIGATE_CONFIG", {
    host = "192.168.1.50", camera_name = "bbq", use_sub_stream = "Yes",
    object_labels = "", audio_labels = "",
})
check("empty labels still register the static set", registeredTypes["Motion Detected"] == true)

-- An unmapped label registers its generated type, so its history can render.
registeredTypes = {}
pcall(ExecuteCommand, "SET_FRIGATE_CONFIG", {
    host = "192.168.1.50", camera_name = "yard", use_sub_stream = "Yes",
    object_labels = "bicycle", audio_labels = "",
})
check("unmapped label's generated type is registered", registeredTypes["Bicycle Detected"] == true)
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `luajit test/driver_test.lua camera-driver/driver.lua`
Expected: FAIL — `registers the camera's object labels`, because `SET_FRIGATE_CONFIG` does not re-register.

- [ ] **Step 3: Make `registerNotificationEvents()` accept labels**

Change its signature and build the type list from the static set plus the supplied labels:

```lua
--- Register the history event types this camera can emit.
--- Called with no arguments at init (static set only); called again with the
--- camera's own labels when the NVR sends them, so registration matches what
--- this specific camera can actually produce (#28, #29).
--- The complete set is always sent in ONE call, which is correct whether
--- C4:RegisterEvents replaces or accumulates.
local function registerNotificationEvents(objectLabels, audioLabels)
```

Replace the hardcoded `types` array with:

```lua
    local seen, types = {}, {}
    local function addType(t)
        if t and t ~= "" and not seen[t] then seen[t] = true; types[#types + 1] = t end
    end

    -- Static types, always registered.
    addType("Object Detected")   addType("Object Left")
    addType("Motion Detected")   addType("Motion Stopped")
    addType("Zone Entered")      addType("Zone Exited")
    addType("Loitering Detected")
    addType("Camera Online")     addType("Camera Offline")
    addType("Audio Detected")
    addType("Detection Enabled")  addType("Detection Disabled")
    addType("Recording Enabled")  addType("Recording Disabled")

    -- This camera's own labels.
    for _, l in ipairs(objectLabels or {}) do
        local info = labelInfo(l, "object")
        addType(info.detected)
        addType(info.left)
    end
    for _, l in ipairs(audioLabels or {}) do
        local info = labelInfo(l, "audio")
        addType("Audio: " .. info.friendly)
    end
```

The rest of the function — building `typeList` from `types`, the XML, and the `C4:RegisterEvents` call — is unchanged.

- [ ] **Step 4: Re-register when labels arrive**

In `ExecuteCommand`'s `SET_FRIGATE_CONFIG` branch, after the existing `updateProxy()` call, add:

```lua
            local function splitLabels(s)
                local out = {}
                for v in tostring(s or ""):gmatch("[^,]+") do out[#out + 1] = v end
                return out
            end
            local objL = splitLabels(tParams.object_labels)
            local audL = splitLabels(tParams.audio_labels)
            log(LOG_DEBUG, "Labels for this camera — objects: " .. tostring(tParams.object_labels)
                .. " | audio: " .. tostring(tParams.audio_labels))
            registerNotificationEvents(objL, audL)
```

`registerNotificationEvents` is a `local function` declared earlier in the file, so it is in scope here as an upvalue. If the linter reports it as unknown, move its declaration above `ExecuteCommand` rather than making it global.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `luajit test/driver_test.lua camera-driver/driver.lua`
Expected: `ALL PASS`.

- [ ] **Step 6: Commit**

```bash
git add camera-driver/driver.lua test/driver_test.lua
git commit -m "feat(camera): register history types per camera (#28, #29)

registerNotificationEvents now takes the camera's own object and audio
labels and registers the static types plus exactly what this camera can
emit — front_door registers Package Detected, bbq does not.

The complete set is always sent in a single C4:RegisterEvents call,
which is correct whether registration replaces or accumulates, so the
change does not depend on resolving that question first. The DriverWorks
reference documents that the API may be called after OnDriverLateInit
and that failures auto-retry every 30s.

Unmapped labels register their generated type, so their history renders
in the app rather than being stored and never displayed."
```

---

### Task 7: Release v0.9.0-rc.2

**Files:**
- Modify: `camera-driver/driver.xml`, `nvr-driver/driver.xml`, `nvr-driver/driver.lua`, `CHANGELOG.md`, `README.md`

**Interfaces:**
- Consumes: Tasks 1–6 complete and passing
- Produces: v0.9.0-rc.2, camera driver v45, NVR driver v50

- [ ] **Step 1: Bump versions**

```bash
sed -i '' 's|<version>44</version>|<version>45</version>|' camera-driver/driver.xml
sed -i '' 's|<version>49</version>|<version>50</version>|' nvr-driver/driver.xml
sed -i '' "s|<modified>[0-9-]*</modified>|<modified>$(date +%Y-%m-%d)</modified>|" camera-driver/driver.xml
sed -i '' "s|<modified>[0-9-]*</modified>|<modified>$(date +%Y-%m-%d)</modified>|" nvr-driver/driver.xml
sed -i '' 's|local DRIVER_RELEASE  = "v0.9.0-rc.1"|local DRIVER_RELEASE  = "v0.9.0-rc.2"|' nvr-driver/driver.lua
```

Verify: `grep -o "<version>[0-9]*</version>" camera-driver/driver.xml nvr-driver/driver.xml && grep -n 'DRIVER_RELEASE  =' nvr-driver/driver.lua`

- [ ] **Step 2: Add the CHANGELOG entry**

Insert above the `## [0.9.0-rc.1]` heading, using the output of `date +%Y-%m-%d` for the date:

```markdown
## [0.9.0-rc.2] - YYYY-MM-DD

### Removed

- **BREAKING: the `Audio: Siren`, `Audio: Car Horn` and `Audio: Music` events and their `SIREN_LAST_HEARD`, `CAR_HORN_LAST_HEARD` and `MUSIC_LAST_HEARD` variables have been removed.** These labels were never emitted by Frigate — `/api/labels` on a live system lists only labels with recorded events, and none of the three appeared. They were invented rather than observed. If your Frigate configuration does listen for one of them, the detection still reaches Control4 through the generic `Audio Detected` event with a correctly named history entry, but **any Composer programming bound to the three removed events will stop firing** and must be repointed at `Audio Detected`.

### Fixed

- **Detections configured in Frigate but not hardcoded in the driver were silently discarded (#28, #29).** The driver hardcoded which detection labels it subscribed to — four object types and nine audio types — while Frigate's actual labels come from its own per-camera configuration. On a live 13-camera system this meant `package`, `glass`, `shatter` and `car_alarm` detections never reached Control4 at all: no event, no history, no log line. Both subscription sets and the handler whitelist are now derived from Frigate's config at discovery, so they cannot drift. Any label Frigate is configured to detect now reaches Control4; unrecognised labels fire the generic `Object Detected` / `Audio Detected` events with a properly named history entry rather than being dropped.

- **Three audio history entries never appeared in the Control4 app.** `handleAudio()` built its history type by capitalising only the first letter, recording `Audio: Fire alarm` while the History agent registration said `Audio: Fire Alarm`. Navigator renders only history matching a registration, so `fire_alarm`, `glass_breaking` and `car_horn` entries were stored and never displayed. Event names, history types and registrations now all come from one canonical table and cannot disagree.

### Added

- **`Package Detected` and `Package Left` events**, with `PACKAGE_DETECTED` (boolean) and `PACKAGE_LAST_SEEN` (timestamp) variables. Packages persist, so the boolean supports conditions like "a package is present and nobody has been detected for ten minutes".
- **`Audio: Car Alarm` event** with `CAR_ALARM_LAST_HEARD`. Kept separate from the car-horn concept: a car alarm is a security event.
- **`glass` and `shatter` both map to `Audio: Glass Breaking`** and share `GLASS_BREAKING_LAST_HEARD` — the distinction is acoustic rather than meaningful.
- **The resolved label sets are logged at INFO on startup**, e.g. `Subscribed to objects: car, package, person | audio: bark, car_alarm, ...`. All three defects above were invisible because nothing ever stated what the driver was listening for.

### Changed

- Detection labels are read from Frigate at discovery. After changing `objects.track` or `audio.listen` in Frigate, restart Frigate and run **Discover Cameras** in Composer to pick up the change. If the config cannot be read, the driver falls back to the previous built-in label list and logs a warning.
- NVR driver bumped to v50, camera driver bumped to v45.
```

- [ ] **Step 3: Update the README**

Two edits.

First, correct the stale variable badge — it reads 27 and the real count is 29:

```bash
grep -n "Variables-27" README.md
sed -i '' 's|Variables-27|Variables-29|' README.md
```

Second, in the variables table (around line 379, where `PERSON_DETECTED` and friends are listed), add rows for the new variables and delete any rows for `SIREN_LAST_HEARD`, `CAR_HORN_LAST_HEARD` or `MUSIC_LAST_HEARD` if present:

```markdown
| `PACKAGE_DETECTED` | Boolean | "If package detected, send notification" |
| `PACKAGE_LAST_SEEN` | String | "Show when a package last arrived" |
| `CAR_ALARM_LAST_HEARD` | String | "Show when a car alarm last sounded" |
```

Then add a short subsection immediately before `### Debugging` explaining config-driven labels:

```markdown
### Which detections reach Control4

The driver subscribes to exactly the detection labels your Frigate is configured to produce — it reads `objects.track` and `audio.listen` from Frigate's own config, including per-camera overrides, when it discovers cameras.

If you add a label in Frigate (say `package` on a porch camera), restart Frigate and then run **Discover Cameras** in Composer to pick it up. The driver logs what it resolved at startup:

```
Subscribed to objects: car, package, person | audio: bark, car_alarm, fire_alarm, glass, scream, shatter, speech, yell
```

Labels with a dedicated event — `person`, `car`, `dog`, `cat`, `package`, and the audio types — fire that event. Any other label fires the generic `Object Detected` / `Audio Detected` event and records history under its own name, so nothing is lost.
```

- [ ] **Step 4: Verify everything**

```bash
luajit test/driver_test.lua camera-driver/driver.lua
luajit test/nvr_test.lua nvr-driver/driver.lua
./build.sh all
```

Expected: both harnesses `ALL PASS`; build writes both `.c4z` files.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Config-driven detection labels (#28, #29)

Camera driver v45, NVR driver v50 — v0.9.0-rc.2.

BREAKING: Audio: Siren, Audio: Car Horn and Audio: Music removed."
```

Do **not** tag or push a release in this task — the branch needs its whole-branch review first, and the release is cut afterwards.

---

## Notes for the implementer

- **`SendToDevice` cannot carry tables.** Label lists cross as comma-separated strings and are split on receipt. Do not "improve" this to a table — the params are serialised as strings and a table will not survive.
- **Never subscribe to `frigate/+/audio/rms` or `dBFS`.** Frigate publishes these roughly once a second per camera; subscribing to them flooded `Last Event` (#23). `AUDIO_TELEMETRY` filters them regardless of what the config says, and a test pins it.
- **Registration must always include the static types.** A camera that receives empty label lists must still register motion, zone, health and state types, or its existing history stops rendering.
- **`luac -p nvr-driver/driver.lua` fails at line 718** on the local Lua 5.5 — this was fixed in the v0.8.16 work, so if it reappears, something regressed. Prefer `luajit -bl <file> >/dev/null` for a syntax check.
- **Do not renumber events 22–24.** They are deliberately vacant.
