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

realWrite(failures == 0 and "\nALL PASS\n" or ("\n" .. failures .. " FAILURE(S)\n"))
os.exit(failures == 0 and 0 or 1)
