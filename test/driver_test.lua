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

realWrite(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
