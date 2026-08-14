# Frigate Event Snapshots in Push Notifications — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a Control4 push notification fires for a camera detection, attach the Frigate snapshot of the event that triggered it instead of the camera's live view at render time.

**Architecture:** The NVR driver already subscribes to `frigate/events` and parses that JSON for loitering detection. It will additionally extract the event `id` and `has_snapshot`, and forward them to the camera driver via a new `FRIGATE_EVENT` command over the existing `C4:SendToDevice` path. The camera driver caches the last event in memory and, when Control4 pulls the notification attachment URL, returns that event's snapshot URL if the event is recent enough — otherwise the live snapshot URL it uses today.

**Tech Stack:** Lua 5.1 (Control4 DriverWorks), Frigate HTTP API, MQTT. Tests are a standalone Lua script that mocks the `C4` global; no test framework.

**Spec:** `docs/superpowers/specs/2026-08-14-frigate-snapshot-thumbnails-design.md`

## Global Constraints

- **Target runtime is Lua 5.1** (Control4 Director). Do not use `goto`, integer division `//`, or `<const>`. The local `luac` is 5.5 and will reject some valid 5.1 code — `luac -p` failures on `nvr-driver/driver.lua:718` (`attempt to assign to const variable 'devId'`) are pre-existing and expected; ignore that one specifically.
- **Every release bumps three things in one commit:** `<version>` and `<modified>` in each `driver.xml`, `DRIVER_RELEASE` in `nvr-driver/driver.lua`, and a `CHANGELOG.md` entry.
- **The driver has external users.** Any behaviour change needs a safe default and an explicit CHANGELOG note.
- **Valid Composer property types** are `STRING`, `LIST`, `NUMBER`, `PASSWORD`, `BUTTON`. Both drivers use only `LIST` and `STRING`.
- **`C4:RecordHistory` uses the four-argument form** — `(severity, eventType, category, subcategory)`. Passing the documented fifth metadata table stops records being stored on OS 3.4.3.
- **Recorded history `(category, subcategory, type)` must match the `C4:RegisterEvents` registration** or Navigator will not display it. Category `Cameras`, subcategory `Frigate`.
- Current versions at plan time: camera driver **v42**, NVR driver **v47**, release **v0.8.15-beta**.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `test/driver_test.lua` | Standalone regression harness — mocks the `C4` API, drives the camera driver, asserts on captured calls | Create (move from scratch) |
| `test/nvr_test.lua` | Standalone harness for the NVR driver's `frigate/events` JSON parsing | Create |
| `.github/workflows/build.yml` | CI — run both harnesses before building | Modify |
| `nvr-driver/driver.lua` | Extract `id` / `has_snapshot`, send `FRIGATE_EVENT` | Modify `handleEventJSON()` (line 319) |
| `camera-driver/driver.lua` | Cache last event; select the notification URL | Modify `GetNotificationAttachmentURL()` (line ~583) and `ExecuteCommand()` |
| `camera-driver/driver.xml` | New `Notification Image Freshness (seconds)` property | Modify `<properties>`, bump `<version>` |
| `nvr-driver/driver.xml` | Version bump only | Modify |
| `CHANGELOG.md`, `README.md` | Release notes and user documentation | Modify |

Two separate test files because the two drivers need incompatible `C4` mocks — the camera harness calls `OnDriverLateInit()` and asserts on variables and history; the NVR harness must not, and needs `C4:PersistGetValue` returning a managed-camera table.

---

### Task 1: Commit the regression harness and wire it into CI

The harness that proved issues #24 and #27 exists only in a scratch directory and will be lost. Committing it first means every later task has somewhere to add tests, and the three bugs fixed in v0.8.12–v0.8.15 are protected from regression.

**Files:**
- Create: `test/driver_test.lua`
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: nothing
- Produces: `test/driver_test.lua`, run as `lua test/driver_test.lua camera-driver/driver.lua`. Exits `0` on success, `1` on any failure. Defines the globals `rejectTable` (boolean, default `true` — when true the mock `C4:RecordHistory` refuses the metadata-table form, modelling OS 3.4.3) and the capture tables `vars`, `events`, `history`, `props`.

- [ ] **Step 1: Create the harness file**

Create `test/driver_test.lua`:

```lua
-- Standalone regression harness for the Frigate camera driver.
--
-- Mocks the DriverWorks C4 API with the behaviours observed on real hardware
-- (OS 3.4.3), so that the bugs fixed in v0.8.12-v0.8.15 cannot regress:
--   * C4:AddVariable returns a BOOLEAN, not a variable id (issue #27)
--   * C4:SetVariable raises unless the identifier is a number/string (#27)
--   * C4:RecordHistory does NOT store when passed the metadata table (#24)
--   * Navigator only renders history matching a C4:RegisterEvents registration (#24)
--
-- Usage: lua test/driver_test.lua camera-driver/driver.lua
-- Exit code 0 = all pass, 1 = one or more failures.

local driverPath = arg[1] or error("usage: lua test/driver_test.lua <driver.lua>")

vars, events, history, props = {}, {}, {}, {}
registeredCategory, registeredSubcategory, registeredTypes = nil, nil, {}

-- When true, the metadata-table form of RecordHistory does not store, as on
-- OS 3.4.3. Flip to false to model firmware that accepts it.
rejectTable = true

C4 = {}
function C4:AddVariable(name, value, vtype)
    assert(type(name) == "string", "AddVariable name must be a string")
    vars[name] = value
    return true                      -- firmware returns a boolean, NOT an id
end
function C4:SetVariable(id, value)
    if type(id) ~= "number" and type(id) ~= "string" then
        error("identifier should be a number/string", 2)
    end
    if vars[id] == nil then error("unknown variable: " .. tostring(id), 2) end
    vars[id] = value
end
function C4:FireEvent(name) events[#events + 1] = name end
function C4:RecordHistory(severity, etype, category, subcategory, meta)
    if meta ~= nil and rejectTable then return nil end
    history[#history + 1] = {severity = severity, etype = etype, category = category,
                             subcategory = subcategory, meta = meta}
    return "hist-evnt-recd-uuid"
end
function C4:RegisterEvents(xml)
    registeredCategory    = xml:match('<category name="([^"]+)"')
    registeredSubcategory = xml:match('<subcategory name="([^"]+)"')
    for t in xml:gmatch('<type name="([^"]+)"') do registeredTypes[t] = true end
    return 0
end
function C4:UpdateProperty(name, value) props[name] = value end
function C4:GetProxyDevices() return {[827] = "camera"} end
function C4:GetDeviceID() return 1586 end
function C4:XmlEscapeString(s) return s end
function C4:ErrorLog(msg) end
function C4:AddDynamicBinding() end
function C4:SendToProxy() end
function C4:SendToDevice() end
function C4:urlEncode(s) return s end
function C4:urlGet() return 0 end
function C4:GetDriverConfigInfo() return "" end
function C4:AllowExecuteDeviceCommand() end
function C4:SetTimer() return 0 end
function C4:KillTimer() end
function C4:GetTime() return "12:00:00" end
function C4:UpdateBoundDevice() end

Properties = {
    ["Camera Name"]  = "bbq",
    ["Frigate Host"] = "192.168.1.50",
    ["Log Level"]    = "1 - Error",
    ["Log Mode"]     = "Off",
}

local realWrite = io.write
print = function() end               -- silence driver logging during load
dofile(driverPath)
OnDriverLateInit()

local failures = 0
function check(desc, ok, detail)
    realWrite(string.format("%-58s %s\n", desc, ok and "PASS" or ("FAIL  " .. tostring(detail))))
    if not ok then failures = failures + 1 end
end

------------------------------------------------------------------------
-- Person detected: variables, events, history, Last Event
------------------------------------------------------------------------
events, history = {}, {}
local ok, err = pcall(ExecuteCommand, "FRIGATE_DETECTION",
    { object_type = "person", count = 1, event_type = "new" })

check("handleDetection(person, new) does not raise", ok, err)
check("PERSON_DETECTED == true", vars.PERSON_DETECTED == "true", vars.PERSON_DETECTED)
check("PERSON_COUNT == 1", vars.PERSON_COUNT == "1", vars.PERSON_COUNT)
check("PERSON_LAST_SEEN populated", (vars.PERSON_LAST_SEEN or "") ~= "")

local fired = {}
for _, e in ipairs(events) do fired[e] = true end
check("fired 'Person Detected'", fired["Person Detected"] == true)
check("fired 'Object Detected'", fired["Object Detected"] == true)

local h = history[1]
check("recorded a history entry", h ~= nil)
check("history severity == Info", h and h.severity == "Info", h and h.severity)
check("history type == 'Person Detected'", h and h.etype == "Person Detected", h and h.etype)
check("history category == 'Cameras'", h and h.category == "Cameras", h and h.category)
check("history subcategory == 'Frigate'", h and h.subcategory == "Frigate", h and h.subcategory)
check("stored via the plain four-argument form", h and h.meta == nil, h and type(h.meta))
check("recorded category matches RegisterEvents",
      h and h.category == registeredCategory, registeredCategory)
check("recorded subcategory matches RegisterEvents",
      h and h.subcategory == registeredSubcategory, registeredSubcategory)
check("recorded type is a registered type",
      h and registeredTypes[h.etype] == true, h and h.etype)
check("Last Event property updated", (props["Last Event"] or "") ~= "")

------------------------------------------------------------------------
-- Person left
------------------------------------------------------------------------
events = {}
ok, err = pcall(ExecuteCommand, "FRIGATE_DETECTION",
    { object_type = "person", count = 0, event_type = "end" })
fired = {}
for _, e in ipairs(events) do fired[e] = true end
check("handleDetection(person, end) does not raise", ok, err)
check("PERSON_DETECTED == false", vars.PERSON_DETECTED == "false", vars.PERSON_DETECTED)
check("fired 'Person Left'", fired["Person Left"] == true)

------------------------------------------------------------------------
-- Motion, delivered as the string "True" the way C4 serialises it
------------------------------------------------------------------------
events = {}
ok, err = pcall(ExecuteCommand, "FRIGATE_MOTION", { active = "True" })
fired = {}
for _, e in ipairs(events) do fired[e] = true end
check("handleMotion(active='True') does not raise", ok, err)
check("MOTION_DETECTED == true", vars.MOTION_DETECTED == "true", vars.MOTION_DETECTED)
check("fired 'Motion Detected'", fired["Motion Detected"] == true)

events = {}
ok, err = pcall(ExecuteCommand, "FRIGATE_MOTION", { active = "false" })
fired = {}
for _, e in ipairs(events) do fired[e] = true end
check("handleMotion(active='false') does not raise", ok, err)
check("MOTION_DETECTED == false", vars.MOTION_DETECTED == "false", vars.MOTION_DETECTED)
check("fired 'Motion Stopped'", fired["Motion Stopped"] == true)

------------------------------------------------------------------------
-- Audio, loitering, health
------------------------------------------------------------------------
ok, err = pcall(ExecuteCommand, "FRIGATE_AUDIO", { audio_type = "speech" })
check("handleAudio(speech) does not raise", ok, err)
check("SPEECH_LAST_HEARD populated", (vars.SPEECH_LAST_HEARD or "") ~= "")

ok, err = pcall(ExecuteCommand, "FRIGATE_LOITERING", { zone = "driveway" })
check("handleLoitering does not raise", ok, err)
check("LOITERING_DETECTED == true", vars.LOITERING_DETECTED == "true", vars.LOITERING_DETECTED)

ok, err = pcall(ExecuteCommand, "FRIGATE_HEALTH", { online = false })
check("handleHealth does not raise", ok, err)
check("CAMERA_ONLINE == false", vars.CAMERA_ONLINE == "false", vars.CAMERA_ONLINE)

realWrite(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run it against the current driver**

Run: `lua test/driver_test.lua camera-driver/driver.lua`
Expected: every line `PASS`, final line `ALL PASS`, exit code 0.

If anything fails, the harness is wrong — the driver is known-good at v42. Fix the harness, not the driver.

- [ ] **Step 3: Add the test step to CI**

In `.github/workflows/build.yml`, insert this step between `actions/checkout@v4` and the `Build .c4z drivers` step:

```yaml
      - name: Install Lua
        run: sudo apt-get update && sudo apt-get install -y lua5.4

      - name: Run driver regression tests
        run: lua test/driver_test.lua camera-driver/driver.lua
```

- [ ] **Step 4: Commit**

```bash
git add test/driver_test.lua .github/workflows/build.yml
git commit -m "test: commit the driver regression harness and run it in CI

Protects the three defects fixed in v0.8.12-v0.8.15 from regressing:
variables addressed by name, history recorded under the registered
category, and the four-argument C4:RecordHistory form.

The harness mocks the C4 API with the behaviours observed on OS 3.4.3,
including C4:AddVariable returning a boolean and C4:RecordHistory
refusing the documented metadata table."
```

---

### Task 2: NVR extracts the event ID and forwards it

**Files:**
- Create: `test/nvr_test.lua`
- Modify: `nvr-driver/driver.lua` — `handleEventJSON()` at line 319
- Modify: `.github/workflows/build.yml`

**Interfaces:**
- Consumes: nothing from Task 1 (separate harness, separate mocks)
- Produces: the NVR sends `C4:SendToDevice(deviceId, "FRIGATE_EVENT", { event_id = <string>, has_snapshot = <boolean>, label = <string> })` whenever a `frigate/events` payload contains an event id. Task 3 consumes this command.

- [ ] **Step 1: Write the failing test**

Create `test/nvr_test.lua`:

```lua
-- Standalone harness for the NVR driver's frigate/events JSON parsing.
--
-- Separate from driver_test.lua because the NVR needs different C4 mocks and
-- must NOT have OnDriverLateInit() called (that would start MQTT and timers).
--
-- Usage: lua test/nvr_test.lua nvr-driver/driver.lua

local driverPath = arg[1] or error("usage: lua test/nvr_test.lua <driver.lua>")

sent = {}          -- captured C4:SendToDevice calls

C4 = {}
function C4:SendToDevice(deviceId, command, params)
    sent[#sent + 1] = { deviceId = deviceId, command = command, params = params }
end
-- The NVR resolves a camera name to a device id through its persisted
-- managed-cameras table; seed it so sendToCamera() finds "bbq".
function C4:PersistGetValue(key)
    if key == "managed_cameras" then
        return { bbq = { deviceId = 1586, proxyId = 5001 } }
    end
    return nil
end
function C4:PersistSetValue(key, value) end
function C4:UpdateProperty(name, value) end
function C4:GetDeviceID() return 1000 end
function C4:ErrorLog(msg) end
function C4:AddTimer() return 0 end
function C4:KillTimer() end
function C4:urlGet() return 0 end
function C4:GetDriverConfigInfo() return "" end
function C4:AddDevice() return 0 end
function C4:RenameDevice() end
function C4:RoomGetId() return 0 end
function C4:GetDevicesByC4iName() return {} end
function C4:CreateTCPClient() return { OnConnect = function() end,
                                       OnError = function() end,
                                       Connect = function() end } end
function C4:MQTT() return nil end
function C4:FileExists() return false end
function C4:FileSetDir() return 0 end
function C4:FileOpen() return nil end
function C4:FileWrite() end
function C4:FileClose() end
function C4:FileDelete() end
function C4:FileSetPos() end
function C4:Base() return {} end

Properties = {
    ["Frigate Host"] = "192.168.1.50",
    ["Log Level"]    = "1 - Error",
    ["Log Mode"]     = "Off",
}

local realWrite = io.write
print = function() end
dofile(driverPath)

local failures = 0
local function check(desc, ok, detail)
    realWrite(string.format("%-58s %s\n", desc, ok and "PASS" or ("FAIL  " .. tostring(detail))))
    if not ok then failures = failures + 1 end
end

local function findSent(command)
    for _, s in ipairs(sent) do if s.command == command then return s end end
    return nil
end

------------------------------------------------------------------------
-- A realistic frigate/events payload. Note has_snapshot is false in
-- `before` and true in `after` — reading it from `before` is the bug this
-- test exists to catch.
------------------------------------------------------------------------
local payload = [[
{"type":"update",
 "before":{"id":"1755012345.678901-abc123","camera":"bbq","label":"person",
           "current_zones":["driveway"],"has_snapshot":false,"has_clip":false},
 "after":{"id":"1755012345.678901-abc123","camera":"bbq","label":"person",
          "current_zones":["driveway"],"has_snapshot":true,"has_clip":true}}
]]

sent = {}
local ok, err = pcall(handleEventJSON, payload)
check("handleEventJSON does not raise", ok, err)

local ev = findSent("FRIGATE_EVENT")
check("sends FRIGATE_EVENT", ev ~= nil)
check("routed to the camera's device id", ev and ev.deviceId == 1586, ev and ev.deviceId)
check("event_id extracted", ev and ev.params.event_id == "1755012345.678901-abc123",
      ev and ev.params.event_id)
check("has_snapshot read from `after`, not `before`",
      ev and ev.params.has_snapshot == true, ev and tostring(ev.params.has_snapshot))
check("label forwarded", ev and ev.params.label == "person", ev and ev.params.label)

------------------------------------------------------------------------
-- has_snapshot false in BOTH objects must forward false
------------------------------------------------------------------------
sent = {}
pcall(handleEventJSON, [[
{"type":"new",
 "before":{"id":"1755000000.0-nosnap","camera":"bbq","label":"car","has_snapshot":false},
 "after":{"id":"1755000000.0-nosnap","camera":"bbq","label":"car","has_snapshot":false}}
]])
ev = findSent("FRIGATE_EVENT")
check("has_snapshot false forwarded as false",
      ev and ev.params.has_snapshot == false, ev and tostring(ev.params.has_snapshot))

------------------------------------------------------------------------
-- Malformed and empty payloads must not raise and must not send
------------------------------------------------------------------------
sent = {}
ok = pcall(handleEventJSON, "not json at all")
check("malformed payload does not raise", ok)
check("malformed payload sends nothing", findSent("FRIGATE_EVENT") == nil)

sent = {}
ok = pcall(handleEventJSON, "")
check("empty payload does not raise", ok)
check("empty payload sends nothing", findSent("FRIGATE_EVENT") == nil)

------------------------------------------------------------------------
-- Regression: loitering detection still works from the same payload
------------------------------------------------------------------------
sent = {}
pcall(handleEventJSON, [[
{"type":"update",
 "before":{"id":"1755999999.0-loiter","camera":"bbq","label":"person",
           "current_zones":["driveway"],"loitering":false,"has_snapshot":true},
 "after":{"id":"1755999999.0-loiter","camera":"bbq","label":"person",
          "current_zones":["driveway"],"loitering":true,"has_snapshot":true}}
]])
local loiter = findSent("FRIGATE_LOITERING")
check("loitering still detected", loiter ~= nil)
check("loitering zone forwarded", loiter and loiter.params.zone == "driveway",
      loiter and loiter.params.zone)

realWrite(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua test/nvr_test.lua nvr-driver/driver.lua`
Expected: FAIL on `sends FRIGATE_EVENT` and every assertion that depends on it, because `handleEventJSON` does not send that command yet. The loitering checks should already PASS.

- [ ] **Step 3: Add an `after`-scoped JSON helper**

In `nvr-driver/driver.lua`, immediately after `jsonBool` (line 256), add:

```lua
--- Extract the `after` object from a frigate/events payload.
--- Event payloads carry both `before` and `after`; fields that change as the
--- event matures (notably has_snapshot) must be read from `after`. The plain
--- json* helpers match the FIRST occurrence, which falls inside `before`.
local function jsonAfterObject(json)
    return json:match('"after"%s*:%s*(%b{})')
end
```

- [ ] **Step 4: Extract the id and send the command**

In `handleEventJSON()`, after the `current_zones` block and before the `if loitering` block, add:

```lua
    -- Forward the Frigate event id so the camera driver can attach this
    -- event's snapshot to push notifications (#25).
    local eventId = jsonString(payload, "id")
    if eventId then
        local after = jsonAfterObject(payload)
        local hasSnapshot = after and jsonBool(after, "has_snapshot") or false
        sendToCamera(camera, "FRIGATE_EVENT", {
            event_id     = eventId,
            has_snapshot = hasSnapshot,
            label        = label or "object",
        })
        log(LOG_TRACE, "Event " .. eventId .. " on " .. camera
            .. " (snapshot=" .. tostring(hasSnapshot) .. ")")
    end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `lua test/nvr_test.lua nvr-driver/driver.lua`
Expected: `ALL PASS`, exit code 0.

- [ ] **Step 6: Add to CI and commit**

In `.github/workflows/build.yml`, extend the test step added in Task 1:

```yaml
      - name: Run driver regression tests
        run: |
          lua test/driver_test.lua camera-driver/driver.lua
          lua test/nvr_test.lua nvr-driver/driver.lua
```

```bash
git add test/nvr_test.lua nvr-driver/driver.lua .github/workflows/build.yml
git commit -m "feat(nvr): forward Frigate event id to the camera driver (#25)

handleEventJSON already parses frigate/events for loitering; it now also
extracts the event id and has_snapshot and sends FRIGATE_EVENT to the
camera, so the camera can attach the triggering event's snapshot to push
notifications.

has_snapshot is read from the \`after\` object specifically: it flips
false to true as Frigate writes the snapshot, and the json helpers match
the first occurrence, which is inside \`before\`."
```

---

### Task 3: Camera caches the last event

**Files:**
- Modify: `camera-driver/driver.lua` — add state near the `VAR` table (line ~121), add a handler in `ExecuteCommand()` (line ~712)
- Modify: `test/driver_test.lua`

**Interfaces:**
- Consumes: `FRIGATE_EVENT { event_id, has_snapshot, label }` from Task 2
- Produces: module-level `lastEvent = { id, timestamp, hasSnapshot }`, where `timestamp` is `os.time()` at receipt. Task 4 reads it. Exposed for tests as the global `__lastEvent` via a getter — see Step 3.

- [ ] **Step 1: Write the failing test**

Append to `test/driver_test.lua`, immediately before the final `realWrite(...)` summary line:

```lua
------------------------------------------------------------------------
-- FRIGATE_EVENT caches the last event (#25)
------------------------------------------------------------------------
ok, err = pcall(ExecuteCommand, "FRIGATE_EVENT",
    { event_id = "1755012345.678901-abc123", has_snapshot = true, label = "person" })
check("FRIGATE_EVENT does not raise", ok, err)

local le = __lastEvent()
check("cached the event id", le.id == "1755012345.678901-abc123", le.id)
check("cached hasSnapshot", le.hasSnapshot == true, tostring(le.hasSnapshot))
check("stamped a timestamp", type(le.timestamp) == "number" and le.timestamp > 0, le.timestamp)

-- has_snapshot arrives as the STRING "false" over SendToDevice, which is
-- truthy in Lua — the classic C4 serialisation trap.
ok, err = pcall(ExecuteCommand, "FRIGATE_EVENT",
    { event_id = "1755000000.0-nosnap", has_snapshot = "false", label = "car" })
le = __lastEvent()
check("string 'false' has_snapshot treated as false", le.hasSnapshot == false,
      tostring(le.hasSnapshot))

-- A missing event_id must not clobber the cache.
pcall(ExecuteCommand, "FRIGATE_EVENT", { has_snapshot = true })
le = __lastEvent()
check("missing event_id leaves the cache intact", le.id == "1755000000.0-nosnap", le.id)
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua test/driver_test.lua camera-driver/driver.lua`
Expected: FAIL — `attempt to call a nil value (global '__lastEvent')`.

- [ ] **Step 3: Add the cache and its test accessor**

In `camera-driver/driver.lua`, immediately after the closing `}` of the `VAR` table (line ~121), add:

```lua
-- Last Frigate event seen for this camera, used to attach that event's
-- snapshot to push notifications (#25). In-memory only: a driver reload
-- falls back to the live snapshot until the next detection.
local lastEvent = { id = nil, timestamp = 0, hasSnapshot = false }

--- Test accessor. The driver's own code uses the local directly.
function __lastEvent() return lastEvent end
```

- [ ] **Step 4: Handle the command**

In `ExecuteCommand()`, add this branch immediately after the `FRIGATE_DETECTION` branch:

```lua
    elseif sCommand == "FRIGATE_EVENT" then
        local p = tParams or {}
        if p.event_id and p.event_id ~= "" then
            -- SendToDevice serialises booleans as strings; "false" is truthy
            -- in Lua, so check explicitly (see c4-conventions §2).
            local raw = p.has_snapshot
            local hasSnapshot = (raw ~= false and raw ~= "false" and raw ~= "False"
                                 and raw ~= 0 and raw ~= "0" and raw ~= nil)
            lastEvent.id          = p.event_id
            lastEvent.hasSnapshot = hasSnapshot
            lastEvent.timestamp   = os.time()
            log(LOG_DEBUG, "Cached event " .. p.event_id
                .. " (snapshot=" .. tostring(hasSnapshot) .. ")")
        end
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `lua test/driver_test.lua camera-driver/driver.lua`
Expected: `ALL PASS`, exit code 0.

- [ ] **Step 6: Commit**

```bash
git add camera-driver/driver.lua test/driver_test.lua
git commit -m "feat(camera): cache the last Frigate event (#25)

Handles the new FRIGATE_EVENT command and remembers the event id, its
has_snapshot flag and a local receipt timestamp, so the notification
attachment can reference the event that actually triggered it.

has_snapshot is checked against the string 'false' as well as the
boolean: SendToDevice serialises params as strings and 'false' is truthy
in Lua."
```

---

### Task 4: Select the notification URL

**Files:**
- Modify: `camera-driver/driver.lua` — `GetNotificationAttachmentURL()` (line ~583), property constants (line ~33)
- Modify: `camera-driver/driver.xml` — `<properties>`
- Modify: `test/driver_test.lua`

**Interfaces:**
- Consumes: `lastEvent` from Task 3; the `Notification Image Freshness (seconds)` property
- Produces: `GetNotificationAttachmentURL(idBinding, tParams)` returns the event snapshot URL when an event is fresh and has a snapshot, otherwise the live snapshot URL, otherwise `""` when host or camera is unset.

- [ ] **Step 1: Write the failing test**

Append to `test/driver_test.lua`, before the final summary line:

```lua
------------------------------------------------------------------------
-- Notification attachment URL selection (#25)
------------------------------------------------------------------------
local EVENT_URL = "http://192.168.1.50:5000/api/events/1755012345.678901-abc123/snapshot.jpg?bbox=1&h=480"
local LIVE_URL  = "http://192.168.1.50:5000/api/bbq/latest.jpg"

local function setEvent(id, hasSnapshot, ageSeconds)
    local le = __lastEvent()
    le.id, le.hasSnapshot = id, hasSnapshot
    le.timestamp = os.time() - (ageSeconds or 0)
end

Properties["Notification Image Freshness (seconds)"] = "60"

setEvent("1755012345.678901-abc123", true, 0)
check("fresh event returns the event snapshot URL",
      GetNotificationAttachmentURL(1001, {}) == EVENT_URL, GetNotificationAttachmentURL(1001, {}))

setEvent("1755012345.678901-abc123", true, 60)
check("event exactly at the window is still fresh",
      GetNotificationAttachmentURL(1001, {}) == EVENT_URL, GetNotificationAttachmentURL(1001, {}))

setEvent("1755012345.678901-abc123", true, 61)
check("event past the window falls back to live",
      GetNotificationAttachmentURL(1001, {}) == LIVE_URL, GetNotificationAttachmentURL(1001, {}))

setEvent("1755012345.678901-abc123", false, 0)
check("event without a snapshot falls back to live",
      GetNotificationAttachmentURL(1001, {}) == LIVE_URL, GetNotificationAttachmentURL(1001, {}))

setEvent(nil, false, 0)
check("no event at all falls back to live",
      GetNotificationAttachmentURL(1001, {}) == LIVE_URL, GetNotificationAttachmentURL(1001, {}))

Properties["Notification Image Freshness (seconds)"] = "Off"
setEvent("1755012345.678901-abc123", true, 0)
check("freshness Off always returns live",
      GetNotificationAttachmentURL(1001, {}) == LIVE_URL, GetNotificationAttachmentURL(1001, {}))

Properties["Notification Image Freshness (seconds)"] = nil
setEvent("1755012345.678901-abc123", true, 0)
check("absent property defaults to 60s and uses the event",
      GetNotificationAttachmentURL(1001, {}) == EVENT_URL, GetNotificationAttachmentURL(1001, {}))

Properties["Notification Image Freshness (seconds)"] = "60"
local savedHost = Properties["Frigate Host"]
Properties["Frigate Host"] = ""
check("unset host returns empty string", GetNotificationAttachmentURL(1001, {}) == "")
Properties["Frigate Host"] = savedHost
```

- [ ] **Step 2: Run it to verify it fails**

Run: `lua test/driver_test.lua camera-driver/driver.lua`
Expected: FAIL — the first check returns `.../api/bbq/latest.jpg` instead of the event URL.

- [ ] **Step 3: Add the property constant**

In `camera-driver/driver.lua`, after `local PROP_LOG_LEVEL` (line 33), add:

```lua
local PROP_NOTIFY_FRESHNESS = "Notification Image Freshness (seconds)"
```

- [ ] **Step 4: Replace the URL builder**

Replace the body of `GetNotificationAttachmentURL()` with:

```lua
function GetNotificationAttachmentURL(idBinding, tParams)
    local host = Properties[PROP_HOST] or ""
    local cam = cameraName()
    log(LOG_DEBUG, "GetNotificationAttachmentURL called (binding=" .. tostring(idBinding)
        .. " cam=" .. tostring(cam) .. ")")
    if host == "" or not cam then return "" end

    local base = "http://" .. host .. ":" .. PORT_HTTP

    -- "Off" disables event snapshots; an absent or unparseable value defaults
    -- to 60s. Composer does not enforce type constraints, so parse defensively.
    local raw = Properties[PROP_NOTIFY_FRESHNESS]
    local window = (raw == "Off") and 0 or (tonumber(raw) or 60)

    if window > 0 and lastEvent.id and lastEvent.hasSnapshot
       and (os.time() - lastEvent.timestamp) <= window then
        local url = base .. "/api/events/" .. lastEvent.id .. "/snapshot.jpg?bbox=1&h=480"
        log(LOG_DEBUG, "Notification image: event snapshot " .. url)
        return url
    end

    local url = base .. "/api/" .. cam .. "/latest.jpg"
    log(LOG_DEBUG, "Notification image: live snapshot " .. url)
    return url
end
```

- [ ] **Step 5: Add the property to driver.xml**

In `camera-driver/driver.xml`, inside `<properties>`, immediately after the `Log Mode` property's closing `</property>`, add:

```xml
      <property>
        <name>Notification Image Freshness (seconds)</name>
        <type>LIST</type>
        <default>60</default>
        <readonly>false</readonly>
        <items>
          <item>Off</item>
          <item>30</item>
          <item>60</item>
          <item>120</item>
          <item>300</item>
        </items>
      </property>
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `lua test/driver_test.lua camera-driver/driver.lua`
Expected: `ALL PASS`, exit code 0.

- [ ] **Step 7: Commit**

```bash
git add camera-driver/driver.lua camera-driver/driver.xml test/driver_test.lua
git commit -m "feat(camera): attach the triggering event's snapshot to notifications (#25)

GetNotificationAttachmentURL returns the Frigate event snapshot
(bbox=1&h=480) when the last event is within the freshness window and
has a snapshot, otherwise the live latest.jpg it returned before.

New 'Notification Image Freshness (seconds)' property, default 60. Off
restores the previous behaviour exactly, which matters for existing
users."
```

---

### Task 5: Release

**Files:**
- Modify: `camera-driver/driver.xml`, `nvr-driver/driver.xml` — `<version>` and `<modified>`
- Modify: `nvr-driver/driver.lua` — `DRIVER_RELEASE`
- Modify: `CHANGELOG.md`, `README.md`

**Interfaces:**
- Consumes: Tasks 1–4 complete and passing
- Produces: v0.8.16-beta, camera driver v43, NVR driver v48

- [ ] **Step 1: Bump versions**

```bash
sed -i '' 's|<version>42</version>|<version>43</version>|' camera-driver/driver.xml
sed -i '' 's|<version>47</version>|<version>48</version>|' nvr-driver/driver.xml
sed -i '' "s|<modified>[0-9-]*</modified>|<modified>$(date +%Y-%m-%d)</modified>|" camera-driver/driver.xml
sed -i '' "s|<modified>[0-9-]*</modified>|<modified>$(date +%Y-%m-%d)</modified>|" nvr-driver/driver.xml
sed -i '' 's|local DRIVER_RELEASE  = "v0.8.15-beta"|local DRIVER_RELEASE  = "v0.8.16-beta"|' nvr-driver/driver.lua
```

Verify: `grep -n "<version>" camera-driver/driver.xml nvr-driver/driver.xml && grep -n 'DRIVER_RELEASE  =' nvr-driver/driver.lua`

- [ ] **Step 2: Add the CHANGELOG entry**

Insert above the `## [0.8.15-beta]` heading:

```markdown
## [0.8.16-beta] - YYYY-MM-DD   ← use the output of `date +%Y-%m-%d`

### Added

- **Push notifications now show the Frigate event that triggered them (#25).** The notification image was `/api/<camera>/latest.jpg` — the camera's live view at the moment the notification rendered, which by then is usually an empty scene. The driver now attaches the snapshot of the event that actually fired the notification, with Frigate's bounding box drawn around the detected object. The NVR forwards the event id from the `frigate/events` messages it already subscribes to, so there is no new MQTT traffic.

- **New camera property `Notification Image Freshness (seconds)`** — `Off`, `30`, `60` (default), `120`, `300`. Event snapshots are used only when the triggering event is within this window; anything older falls back to the live snapshot, so a motion notification never shows a person from twenty minutes ago. Set to `Off` to restore the previous behaviour exactly.

- **Regression test harness committed and running in CI.** `test/driver_test.lua` and `test/nvr_test.lua` mock the DriverWorks API with the behaviours observed on OS 3.4.3 and guard the defects fixed in v0.8.12–v0.8.15 — variables addressed by name, history recorded under the registered category, and the four-argument `C4:RecordHistory` form.

### Changed

- NVR driver bumped to v48, camera driver bumped to v43.
```

- [ ] **Step 3: Document the property in the README**

There is no camera-property table in the README — the two existing tables are the NVR setup table (line ~158) and the debugging table (line ~542). Add a new subsection immediately **before** `### Debugging` (line ~538):

```markdown
### Push notification images

When a notification fires, the driver attaches the Frigate snapshot of the event that triggered it — the full camera frame at the moment of detection, with a bounding box around the detected object. Without this, the image would be the camera's live view at the moment the notification renders, by which time the subject has usually left the frame.

| Property | Setting | Effect |
|----------|---------|--------|
| **Notification Image Freshness (seconds)** | `60` (default) | Use the event snapshot when the triggering event is at most 60s old |
| **Notification Image Freshness (seconds)** | `30` / `120` / `300` | Same, with a shorter or longer window |
| **Notification Image Freshness (seconds)** | `Off` | Always use the camera's live snapshot |

Events older than the window fall back to the live snapshot, so a motion notification never shows a person detected twenty minutes earlier. Motion, audio and camera-offline events have no Frigate event behind them and always use the live snapshot.

> **Note:** The snapshot URL points at the Frigate host on your LAN, exactly as the live snapshot URL always has. Whether images load in notifications received away from home is unchanged by this feature.
```

- [ ] **Step 4: Verify everything**

```bash
lua test/driver_test.lua camera-driver/driver.lua
lua test/nvr_test.lua nvr-driver/driver.lua
./build.sh all
```

Expected: both harnesses `ALL PASS`; build writes `dist/frigate-camera.c4z` and `dist/frigate-nvr.c4z`.

- [ ] **Step 5: Commit, tag, and deliver for testing**

```bash
git add -A
git commit -m "Frigate event snapshots in push notifications (#25)

Camera driver v43, NVR driver v48."
git push origin main
git tag -a v0.8.16-beta -m "v0.8.16-beta — Frigate event snapshots in push notifications (#25)"
git push origin v0.8.16-beta

D=~/Library/CloudStorage/OneDrive-Personal/Control4/control4-frigate/$(date +%Y-%m-%d_%H%M%S)
mkdir -p "$D" && cp dist/*.c4z "$D"/ && echo "$D"
```

Then write full release notes on GitHub (see the v0.8.15-beta release for the expected depth) and report the OneDrive path.

- [ ] **Step 6: Live verification**

Walk in front of a camera with a Composer notification programmed on `Person Detected`. The push notification should show the full frame from the moment of detection with a box around the person, not a later empty view. Then set `Notification Image Freshness (seconds)` to `Off` and confirm the notification reverts to the live snapshot.

Comment the result on #25 and close it only if it passes.

---

## Notes for the implementer

- **Do not call `C4:urlGet` inside `GetNotificationAttachmentURL()`.** It is asynchronous and the function must return a URL synchronously. This is why the event id is pushed to the camera in advance rather than fetched on demand.
- **`luac -p nvr-driver/driver.lua` fails on line 718** with `attempt to assign to const variable 'devId'`. Pre-existing, legal in Lua 5.1, rejected only by the newer local `luac`. Ignore it; use `luac -p camera-driver/driver.lua` for syntax checks of the camera driver.
- **Remote access is unverified.** The snapshot URL is LAN-only, exactly like the `latest.jpg` URL it replaces. If notifications currently show images away from home, these will too. Do not attempt to solve this here; file a separate issue if it turns out to be broken.
