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
-- Inverted payload: has_snapshot true in `before`, false in `after`.
-- This is the one shape that discriminates a scoped `after`-only read
-- from an unscoped whole-payload read (jsonBool matches only "key":true,
-- so it would find the `before` true and forward the wrong value).
------------------------------------------------------------------------
sent = {}
pcall(handleEventJSON, [[
{"type":"update",
 "before":{"id":"1755000001.0-inverted","camera":"bbq","label":"car","has_snapshot":true},
 "after":{"id":"1755000001.0-inverted","camera":"bbq","label":"car","has_snapshot":false}}
]])
ev = findSent("FRIGATE_EVENT")
check("has_snapshot read from `after` when `before` is true and `after` is false",
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
-- Uses "bbq", the only camera registered in the C4:PersistGetValue mock above;
-- an unmanaged camera name would be dropped by sendToCamera regardless of label.
sent = {}
handleMQTTForTest("frigate/bbq/package", "1")
local pk = findSent("FRIGATE_DETECTION")
check("package count message is forwarded", pk ~= nil)
check("forwarded with the right object type", pk and pk.params.object_type == "package",
      pk and pk.params.object_type)

-- The zone branch (frigate/<camera>/<zone>/<object>) has the same
-- resolved-set filter as the object branch above but was previously
-- untested end to end — a mutation there would pass silently otherwise.
sent = {}
handleMQTTForTest("frigate/bbq/driveway/package", "1")
local zn = findSent("FRIGATE_ZONE")
check("zone count message is forwarded", zn ~= nil)
check("forwarded with the right zone", zn and zn.params.zone == "driveway", zn and zn.params.zone)
check("forwarded with the right object type", zn and zn.params.object_type == "package",
      zn and zn.params.object_type)

-- The fallback label sets are what the driver uses when Frigate's config
-- cannot be read — pin their contents so a future edit can't silently
-- narrow them back (that exact regression, dropping "package", is #29).
local fbObj, fbAud = getFallbackLabels()
check("fallback objects include package", has(fbObj, "package"))
check("fallback objects include the original four",
      has(fbObj, "person") and has(fbObj, "car") and has(fbObj, "dog") and has(fbObj, "cat"))
check("fallback audio includes glass, shatter, car_alarm",
      has(fbAud, "glass") and has(fbAud, "shatter") and has(fbAud, "car_alarm"))
check("fallback audio includes the original five",
      has(fbAud, "speech") and has(fbAud, "bark") and has(fbAud, "scream")
      and has(fbAud, "yell") and has(fbAud, "fire_alarm"))
check("fallback audio never contains telemetry",
      not has(fbAud, "rms") and not has(fbAud, "dBFS"))

realWrite(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
