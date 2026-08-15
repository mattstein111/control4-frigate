--[[
  Frigate Camera Driver for Control4
  Phase 3 — Streams + detection events + history + variables

  Streams:
    MJPEG:    http://<host>:1984/api/stream.mjpeg?src=<cam>[_sub]
    RTSP:     rtsp://<host>:8554/<cam>_sub  (H.264)
    Snapshot: http://<host>:5000/api/<cam>/latest.jpg

  Events received from NVR parent driver via C4:SendToDevice():
    SET_FRIGATE_CONFIG  { host, camera_name, use_sub_stream }
    FRIGATE_DETECTION   { object_type, count, zone, event_type }
    FRIGATE_MOTION      { active }
    FRIGATE_ZONE        { zone, object_type, count }
    FRIGATE_HEALTH      { online }

  Variables exposed for Composer programming:
    PERSON_DETECTED, CAR_DETECTED, DOG_DETECTED, CAT_DETECTED (bool)
    MOTION_DETECTED (bool), CAMERA_ONLINE (bool)
    PERSON_COUNT, CAR_COUNT (int)
    PERSON_LAST_SEEN, CAR_LAST_SEEN, DOG_LAST_SEEN, CAT_LAST_SEEN, MOTION_LAST_SEEN, LOITERING_LAST_SEEN (string)
    AUDIO_LAST_HEARD, SPEECH_LAST_HEARD, BARK_LAST_HEARD, etc. (string)
]]

-- Property name constants
local PROP_VERSION     = "Driver Version"
local PROP_HOST        = "Frigate Host"
local PROP_CAMERA      = "Camera Name"
local PROP_SUB_STREAM  = "Use Sub Stream"
local PROP_STATUS      = "Camera Status"
local PROP_LAST_EVENT  = "Last Event"
local PROP_LAST_MOTION = "Last Motion"
local PROP_LOG_LEVEL   = "Log Level"
local PROP_NOTIFY_FRESHNESS = "Notification Image Freshness (seconds)"

-- Log levels
local LOG_FATAL   = 0
local LOG_ERROR   = 1
local LOG_WARNING = 2
local LOG_INFO    = 3
local LOG_DEBUG   = 4
local LOG_TRACE   = 5

local LOG_LEVEL_MAP = {
    ["0 - Fatal"]   = LOG_FATAL,
    ["1 - Error"]   = LOG_ERROR,
    ["2 - Warning"] = LOG_WARNING,
    ["3 - Info"]    = LOG_INFO,
    ["4 - Debug"]   = LOG_DEBUG,
    ["5 - Trace"]   = LOG_TRACE,
}

local PROP_LOG_MODE    = "Log Mode"

local function log(level, msg)
    local current = LOG_LEVEL_MAP[Properties[PROP_LOG_LEVEL] or "2 - Warning"] or LOG_WARNING
    if level > current then return end
    local mode = Properties[PROP_LOG_MODE] or "Off"
    if mode == "Off" then return end

    local cam = Properties[PROP_CAMERA] or "?"
    local fullMsg = "[Frigate Camera][" .. cam .. "] " .. msg

    if mode == "Print" or mode == "Print and Log" then
        print(fullMsg)
    end
    if mode == "Log" or mode == "Print and Log" then
        C4:ErrorLog(fullMsg)
    end
end

-- Ports
-- MJPEG and snapshots both served by Frigate API on port 5000
-- go2rtc MJPEG (1984) doesn't start sources on-demand — unusable for Control4
local PORT_HTTP     = 5000
local PORT_RTSP     = 8554

-- Proxy binding ID (must match driver.xml)
local PROXY_ID = 5001

-- Variable names. C4:SetVariable is called by name, NOT with the return
-- value of C4:AddVariable — that return is a boolean, not an identifier,
-- and passing it to SetVariable raises "identifier should be a
-- number/string" (issue #27).
local VAR = {
    -- Boolean
    PERSON_DETECTED    = "PERSON_DETECTED",
    CAR_DETECTED       = "CAR_DETECTED",
    DOG_DETECTED       = "DOG_DETECTED",
    CAT_DETECTED       = "CAT_DETECTED",
    MOTION_DETECTED    = "MOTION_DETECTED",
    CAMERA_ONLINE      = "CAMERA_ONLINE",

    -- Numeric
    PERSON_COUNT       = "PERSON_COUNT",
    CAR_COUNT          = "CAR_COUNT",

    -- State
    DETECTION_ENABLED  = "DETECTION_ENABLED",
    RECORDING_ENABLED  = "RECORDING_ENABLED",
    LOITERING_DETECTED = "LOITERING_DETECTED",

    -- Last-seen timestamps (object/motion/loitering)
    PERSON_LAST_SEEN    = "PERSON_LAST_SEEN",
    CAR_LAST_SEEN       = "CAR_LAST_SEEN",
    DOG_LAST_SEEN       = "DOG_LAST_SEEN",
    CAT_LAST_SEEN       = "CAT_LAST_SEEN",
    MOTION_LAST_SEEN    = "MOTION_LAST_SEEN",
    LOITERING_LAST_SEEN = "LOITERING_LAST_SEEN",

    -- Last-heard timestamps (audio)
    AUDIO_LAST_HEARD          = "AUDIO_LAST_HEARD",
    SPEECH_LAST_HEARD         = "SPEECH_LAST_HEARD",
    BARK_LAST_HEARD           = "BARK_LAST_HEARD",
    SCREAM_LAST_HEARD         = "SCREAM_LAST_HEARD",
    YELL_LAST_HEARD           = "YELL_LAST_HEARD",
    FIRE_ALARM_LAST_HEARD     = "FIRE_ALARM_LAST_HEARD",
    GLASS_BREAKING_LAST_HEARD = "GLASS_BREAKING_LAST_HEARD",
    SIREN_LAST_HEARD          = "SIREN_LAST_HEARD",
    CAR_HORN_LAST_HEARD       = "CAR_HORN_LAST_HEARD",
    MUSIC_LAST_HEARD          = "MUSIC_LAST_HEARD",
}

-- Last Frigate event seen for this camera, used to attach that event's
-- snapshot to push notifications (#25). In-memory only: a driver reload
-- falls back to the live snapshot until the next detection.
local lastEvent = { id = nil, timestamp = 0, hasSnapshot = false }

--- Test accessor. The driver's own code uses the local directly.
function __lastEvent() return lastEvent end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function streamName()
    local cam = Properties[PROP_CAMERA] or ""
    if cam == "" then return nil end
    if Properties[PROP_SUB_STREAM] == "Yes" then
        return cam .. "_sub"
    end
    return cam
end

local function cameraName()
    local cam = Properties[PROP_CAMERA] or ""
    if cam == "" then return nil end
    return cam
end

local function setStatus(msg)
    C4:UpdateProperty(PROP_STATUS, msg)
end

--- Get a human-readable timestamp for history entries.
local function timestamp()
    return os.date("%Y-%m-%d %H:%M:%S")
end

--- Convert a Frigate object type to a friendly name.
--- e.g. "person" -> "Person", "car" -> "Car"
local function friendlyObject(objType)
    if not objType or objType == "" then return "Object" end
    return objType:sub(1, 1):upper() .. objType:sub(2)
end

--- Convert a Frigate zone name to a friendly name.
--- e.g. "illegal_parking" -> "Illegal Parking"
local function friendlyZone(zone)
    if not zone or zone == "" then return "" end
    return zone:gsub("_", " "):gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
    end)
end

------------------------------------------------------------------------
-- Variables (Composer conditionals)
------------------------------------------------------------------------

--- Create the driver variables with their initial values.
--- The return value of C4:AddVariable is deliberately ignored — see the
--- VAR table above. Variables are updated by name via setVar().
local function initVariables()
    -- Boolean variables
    C4:AddVariable(VAR.PERSON_DETECTED,    "false", "BOOL")
    C4:AddVariable(VAR.CAR_DETECTED,       "false", "BOOL")
    C4:AddVariable(VAR.DOG_DETECTED,       "false", "BOOL")
    C4:AddVariable(VAR.CAT_DETECTED,       "false", "BOOL")
    C4:AddVariable(VAR.MOTION_DETECTED,    "false", "BOOL")
    C4:AddVariable(VAR.CAMERA_ONLINE,      "true",  "BOOL")

    -- Numeric variables
    C4:AddVariable(VAR.PERSON_COUNT, "0", "NUMBER")
    C4:AddVariable(VAR.CAR_COUNT,    "0", "NUMBER")

    -- State variables
    C4:AddVariable(VAR.DETECTION_ENABLED,  "true",  "BOOL")
    C4:AddVariable(VAR.RECORDING_ENABLED,  "true",  "BOOL")
    C4:AddVariable(VAR.LOITERING_DETECTED, "false", "BOOL")

    -- Last-seen timestamps (object/motion/loitering)
    C4:AddVariable(VAR.PERSON_LAST_SEEN,    "", "STRING")
    C4:AddVariable(VAR.CAR_LAST_SEEN,       "", "STRING")
    C4:AddVariable(VAR.DOG_LAST_SEEN,       "", "STRING")
    C4:AddVariable(VAR.CAT_LAST_SEEN,       "", "STRING")
    C4:AddVariable(VAR.MOTION_LAST_SEEN,    "", "STRING")
    C4:AddVariable(VAR.LOITERING_LAST_SEEN, "", "STRING")

    -- Last-heard timestamps (audio)
    C4:AddVariable(VAR.AUDIO_LAST_HEARD,          "", "STRING")
    C4:AddVariable(VAR.SPEECH_LAST_HEARD,         "", "STRING")
    C4:AddVariable(VAR.BARK_LAST_HEARD,           "", "STRING")
    C4:AddVariable(VAR.SCREAM_LAST_HEARD,         "", "STRING")
    C4:AddVariable(VAR.YELL_LAST_HEARD,           "", "STRING")
    C4:AddVariable(VAR.FIRE_ALARM_LAST_HEARD,     "", "STRING")
    C4:AddVariable(VAR.GLASS_BREAKING_LAST_HEARD, "", "STRING")
    C4:AddVariable(VAR.SIREN_LAST_HEARD,          "", "STRING")
    C4:AddVariable(VAR.CAR_HORN_LAST_HEARD,       "", "STRING")
    C4:AddVariable(VAR.MUSIC_LAST_HEARD,          "", "STRING")
end

--- Update a driver variable by name. Never let a bad variable name abort
--- the calling handler — a failed SetVariable must not stop events from
--- firing (issue #27).
local function setVar(varName, value)
    if type(varName) ~= "string" or varName == "" then
        log(LOG_ERROR, "setVar called with invalid variable name: " .. tostring(varName))
        return
    end
    local ok, err = pcall(function()
        C4:SetVariable(varName, tostring(value))
    end)
    if not ok then
        log(LOG_ERROR, "SetVariable failed for " .. varName .. ": " .. tostring(err))
    end
end

------------------------------------------------------------------------
-- History (visible in Control4 app + touchscreens)
------------------------------------------------------------------------

--- History category/subcategory. These MUST match the values registered with
--- C4:RegisterEvents() in registerNotificationEvents() below — the registration
--- declares which (category, subcategory, type) tuples this device emits, and
--- Navigator only surfaces recorded events that match a registration. Recording
--- under a different category is why history was invisible in the Control4 app
--- despite appearing in the History agent (issue #24).
local HISTORY_CATEGORY    = "Cameras"
local HISTORY_SUBCATEGORY = "Frigate"

--- Record an event in the history database.
---
--- Signature per the DriverWorks API reference (Helper Interface, 1.6.0+):
---   C4:RecordHistory(severity, eventType, category, subcategory, metadata)
---     severity     "Critical" | "Warning" | "Info"
---     eventType    the specific event, e.g. "Person Detected" — this is the
---                  text Navigator displays, and must match a registered type
---     category     "Cameras"
---     subcategory  optional — "Frigate"
---     metadata     optional table of name-value pairs (NOT a description string)
---
--- Returns the UUID of the stored record, or nil if it was not recorded — so
--- the return value is a reliable success check. Matches the call pattern used
--- by shipping third-party camera drivers.
--- The four-argument form is the one used by shipping third-party camera
--- drivers and is treated as authoritative. The optional metadata table is
--- documented but was observed to stop records being stored on OS 3.4.3
--- (v0.8.14-beta regression), so it is attempted only as an enhancement and
--- immediately falls back to the plain form if it does not return a UUID.
local function recordHistory(message, severity, eventType)
    severity = severity or "Info"
    if severity ~= "Info" and severity ~= "Warning" and severity ~= "Critical" then
        severity = "Info"
    end
    eventType = eventType or "Camera Event"

    local function record(...)
        local ok, uuid = pcall(C4.RecordHistory, C4, ...)
        if not ok then return nil, tostring(uuid) end
        if uuid == nil or uuid == "" then return nil, nil end
        return uuid, nil
    end

    -- Plain four-argument form first: proven, and the one that matters.
    local uuid, err = record(severity, eventType, HISTORY_CATEGORY, HISTORY_SUBCATEGORY)

    if uuid then
        log(LOG_DEBUG, "History recorded: " .. eventType .. " (" .. uuid .. ")")
        return
    end

    -- Only if the plain form failed, try with the documented metadata table —
    -- covers firmware where the extra argument is required rather than fatal.
    local uuid2, err2 = record(severity, eventType, HISTORY_CATEGORY, HISTORY_SUBCATEGORY,
                               { Description = tostring(message),
                                 Camera      = cameraName() or "" })
    if uuid2 then
        log(LOG_DEBUG, "History recorded (with metadata): " .. eventType .. " (" .. uuid2 .. ")")
        return
    end

    log(LOG_WARNING, "RecordHistory did not store '" .. tostring(message)
        .. "' — plain form: " .. (err or "nil UUID")
        .. "; with metadata: " .. (err2 or "nil UUID")
        .. ". Check the History agent is installed and running.")
end

------------------------------------------------------------------------
-- Event Firing (for Composer programming)
------------------------------------------------------------------------

--- Event name to numeric ID mapping (must match driver.xml <event><id>).
local EVENT_IDS = {
    ["Person Detected"]      = 1,
    ["Person Left"]          = 2,
    ["Car Detected"]         = 3,
    ["Car Left"]             = 4,
    ["Dog Detected"]         = 5,
    ["Cat Detected"]         = 6,
    ["Object Detected"]      = 7,
    ["Object Left"]          = 8,
    ["Motion Detected"]      = 9,
    ["Motion Stopped"]  = 10,
    ["Zone Entered"]         = 11,
    ["Zone Exited"]          = 12,
    ["Loitering Detected"]   = 13,
    ["Camera Online"]        = 14,
    ["Camera Offline"]       = 15,
    ["Audio: Speech"]        = 16,
    ["Audio: Bark"]          = 17,
    ["Audio: Scream"]        = 18,
    ["Audio: Yell"]          = 19,
    ["Audio: Fire Alarm"]    = 20,
    ["Audio: Glass Breaking"] = 21,
    ["Audio: Siren"]         = 22,
    ["Audio: Car Horn"]      = 23,
    ["Audio: Music"]         = 24,
    ["Audio Detected"]       = 25,
    ["Detection Enabled"]    = 26,
    ["Detection Disabled"]   = 27,
    ["Recording Enabled"]    = 28,
    ["Recording Disabled"]   = 29,
}

--- Fire a named event declared in driver.xml <events>.
local function fireEvent(eventName)
    local eventId = EVENT_IDS[eventName]
    if eventId then
        C4:FireEvent(eventName)
        log(LOG_DEBUG, "Fired event: " .. eventName .. " (id=" .. eventId .. ")")
    end
end

------------------------------------------------------------------------
-- Detection Event Handlers (called by NVR driver via SendToDevice)
------------------------------------------------------------------------

--- Handle object detection count changes from MQTT.
--- tParams: { object_type="person", count=1, event_type="new"|"update"|"end" }
local function handleDetection(tParams)
    local objType = tParams.object_type or "object"
    local count = tonumber(tParams.count) or 0
    local eventType = tParams.event_type or ""
    local cam = cameraName() or "camera"
    local friendly = friendlyObject(objType)
    local ts = timestamp()

    if objType == "person" then
        setVar(VAR.PERSON_COUNT, count)
        setVar(VAR.PERSON_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.PERSON_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Person Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Person Left")
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
    elseif objType == "car" then
        setVar(VAR.CAR_COUNT, count)
        setVar(VAR.CAR_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.CAR_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Car Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Car Left")
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
    elseif objType == "dog" then
        setVar(VAR.DOG_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.DOG_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Dog Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
    elseif objType == "cat" then
        setVar(VAR.CAT_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.CAT_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Cat Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info", friendly .. " Detected")
        elseif count == 0 then
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info", friendly .. " Left")
        end
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

    C4:UpdateProperty(PROP_LAST_EVENT, friendly .. (count > 0 and " detected" or " left") .. " — " .. ts)
end

--- Handle motion on/off from MQTT.
--- tParams: { active=true|false }
local function handleMotion(tParams)
    local raw = tParams.active
    log(LOG_DEBUG, "handleMotion: active = " .. tostring(raw) .. " (type: " .. type(raw) .. ")")
    local active = (raw ~= false and raw ~= "false" and raw ~= "False" and raw ~= 0 and raw ~= "0" and raw ~= nil)
    setVar(VAR.MOTION_DETECTED, active and "true" or "false")

    if active then
        local ts = timestamp()
        setVar(VAR.MOTION_LAST_SEEN, ts)
        C4:UpdateProperty(PROP_LAST_MOTION, ts)
        fireEvent("Motion Detected")
        recordHistory("Motion detected", "Info", "Motion Detected")
    else
        fireEvent("Motion Stopped")
        recordHistory("Motion stopped", "Info", "Motion Stopped")
    end
end

--- Handle zone events from MQTT.
--- tParams: { zone="zone_name", object_type="person", count=1 }
local function handleZone(tParams)
    local zone = tParams.zone or ""
    local objType = tParams.object_type or "object"
    local count = tonumber(tParams.count) or 0
    local friendly = friendlyObject(objType)
    local friendlyZ = friendlyZone(zone)

    if count > 0 then
        fireEvent("Zone Entered")
        recordHistory(friendly .. " entered zone: " .. friendlyZ, "Info", "Zone Entered")
    else
        -- Reset loitering when zone clears
        setVar(VAR.LOITERING_DETECTED, "false")
        fireEvent("Zone Exited")
        recordHistory(friendly .. " left zone: " .. friendlyZ, "Info", "Zone Exited")
    end
end

--- Handle loitering events from MQTT.
--- tParams: { zone="zone_name", object_type="person" }
local function handleLoitering(tParams)
    local zone = tParams.zone or ""
    local objType = tParams.object_type or "object"
    local friendly = friendlyObject(objType)
    local friendlyZ = friendlyZone(zone)

    setVar(VAR.LOITERING_DETECTED, "true")
    setVar(VAR.LOITERING_LAST_SEEN, timestamp())

    fireEvent("Loitering Detected")
    recordHistory(friendly .. " loitering in zone: " .. friendlyZ, "Warning", "Loitering Detected")
    C4:UpdateProperty(PROP_LAST_EVENT, friendly .. " loitering in " .. friendlyZ .. " — " .. timestamp())
end

--- Handle camera health status.
--- tParams: { online=true|false }
local function handleHealth(tParams)
    local raw = tParams.online
    local online = (raw ~= false and raw ~= "false" and raw ~= "False" and raw ~= 0 and raw ~= "0" and raw ~= nil)
    setVar(VAR.CAMERA_ONLINE, online and "true" or "false")

    if online then
        fireEvent("Camera Online")
        setStatus("Online — " .. (cameraName() or ""))
        recordHistory("Camera came online", "Info", "Camera Online")
    else
        fireEvent("Camera Offline")
        setStatus("Offline")
        recordHistory("Camera went offline", "Warning", "Camera Offline")
    end
end

------------------------------------------------------------------------
-- Audio Detection Handler
------------------------------------------------------------------------

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

--- Handle audio detection from Frigate.
--- tParams: { audio_type="speech" }
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

------------------------------------------------------------------------
-- State Change Handlers
------------------------------------------------------------------------

--- Handle detection/recording/audio state changes from Frigate.
--- tParams: { setting="detect"|"recordings"|"audio", enabled=true|false }
local function handleStateChange(tParams)
    local setting = tParams.setting or ""
    local raw_enabled = tParams.enabled
    local enabled = (raw_enabled ~= false and raw_enabled ~= "false" and raw_enabled ~= "False" and raw_enabled ~= 0 and raw_enabled ~= "0" and raw_enabled ~= nil)

    if setting == "detect" then
        setVar(VAR.DETECTION_ENABLED, enabled and "true" or "false")
        if enabled then
            fireEvent("Detection Enabled")
            recordHistory("Detection enabled", "Info", "Detection Enabled")
        else
            fireEvent("Detection Disabled")
            recordHistory("Detection disabled", "Warning", "Detection Disabled")
        end
    elseif setting == "recordings" then
        setVar(VAR.RECORDING_ENABLED, enabled and "true" or "false")
        if enabled then
            fireEvent("Recording Enabled")
            recordHistory("Recording enabled", "Info", "Recording Enabled")
        else
            fireEvent("Recording Disabled")
            recordHistory("Recording disabled", "Warning", "Recording Disabled")
        end
    end
end

------------------------------------------------------------------------
-- Notification Attachment (snapshot for push notifications)
------------------------------------------------------------------------

--- Called by the Notification Agent when a push notification fires.
--- Returns the URL to the current snapshot JPEG.
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

--- Register detection events with the History Agent for push notifications.
local function registerNotificationEvents()
    local proxyDevices = C4:GetProxyDevices()
    if type(proxyDevices) ~= "table" then
        log(LOG_WARNING, "RegisterEvents skipped — GetProxyDevices returned no table; "
            .. "history will not surface in the Control4 app")
        return
    end

    local proxyDeviceId = nil
    for id, _ in pairs(proxyDevices) do
        proxyDeviceId = id
        break
    end
    if not proxyDeviceId then
        log(LOG_WARNING, "RegisterEvents skipped — no proxy device id found; "
            .. "history will not surface in the Control4 app")
        return
    end

    -- Every event type passed to recordHistory() must be registered here, or
    -- Navigator has no registration to match the stored record against.
    local types = {
        -- Object detection
        "Person Detected", "Person Left",
        "Car Detected",    "Car Left",
        "Dog Detected",    "Dog Left",
        "Cat Detected",    "Cat Left",
        "Object Detected", "Object Left",
        -- Motion / zones / loitering
        "Motion Detected", "Motion Stopped",
        "Zone Entered",    "Zone Exited",
        "Loitering Detected",
        -- Health
        "Camera Online",   "Camera Offline",
        -- Audio detection
        "Audio: Speech", "Audio: Bark", "Audio: Scream", "Audio: Yell",
        "Audio: Fire Alarm", "Audio: Glass Breaking", "Audio: Siren",
        "Audio: Car Horn", "Audio: Music",
        -- State changes
        "Detection Enabled", "Detection Disabled",
        "Recording Enabled", "Recording Disabled",
    }

    local typeList = ""
    for _, t in ipairs(types) do
        typeList = typeList .. '<type name="' .. C4:XmlEscapeString(t) .. '"/>'
    end

    local xml = '<events>'
        .. '<device id="' .. proxyDeviceId .. '"/>'
        .. '<categories><category name="' .. HISTORY_CATEGORY .. '">'
        .. '<subcategories><subcategory name="' .. HISTORY_SUBCATEGORY .. '">'
        .. '<types>' .. typeList .. '</types>'
        .. '</subcategory></subcategories>'
        .. '</category></categories></events>'

    local result = C4:RegisterEvents(xml)
    if result == 0 then
        log(LOG_INFO, "Registered notification events for device " .. proxyDeviceId)
    else
        log(LOG_WARNING, "RegisterEvents returned: " .. tostring(result))
    end
end

------------------------------------------------------------------------
-- Dynamic Stream URL Handlers
------------------------------------------------------------------------

function UIRequest(sCommand, tParams)
    log(LOG_DEBUG, "UIRequest: " .. tostring(sCommand))
    if sCommand == "GET_STREAM_URLS" then
        return getStreamURLs(tParams)
    end
    if sCommand == "GET_SNAPSHOT_QUERY_STRING" then
        return getSnapshotQueryString()
    end
    if sCommand == "GET_MJPEG_QUERY_STRING" then
        return getMJPEGQueryString()
    end
    if sCommand == "GET_RTSP_H264_QUERY_STRING" then
        return getRTSPH264QueryString()
    end
end

function getStreamURLs(tParams)
    local host = Properties[PROP_HOST] or ""
    local cam = cameraName()
    local src = streamName()

    if host == "" or cam == nil then
        setStatus("Not Configured")
        return ""
    end

    local mjpegURL    = "http://" .. host .. ":" .. PORT_HTTP .. "/api/" .. cam
    local snapshotURL = "http://" .. host .. ":" .. PORT_HTTP .. "/api/" .. cam .. "/latest.jpg"
    local rtspURL     = "rtsp://" .. host .. ":" .. PORT_RTSP .. "/" .. (src or cam)

    local key = tParams and tParams["KEY"] or "1"

    local xml = '<streams key="' .. key .. '" camera_address="' .. host .. '">'
    xml = xml .. '<stream url="' .. C4:XmlEscapeString(snapshotURL) .. '" codec="jpeg" />'
    xml = xml .. '<stream url="' .. C4:XmlEscapeString(mjpegURL) .. '" codec="mjpeg" />'
    xml = xml .. '<stream url="' .. C4:XmlEscapeString(rtspURL) .. '" codec="h264" />'
    xml = xml .. '</streams>'

    setStatus("Online — " .. cam)
    return xml
end

------------------------------------------------------------------------
-- Legacy Query String Handlers (fallback for older navigators)
------------------------------------------------------------------------

function getMJPEGQueryString()
    local cam = cameraName()
    if not cam then return "" end
    -- Frigate serves MJPEG at /api/<camera_name> (multipart/x-mixed-replace)
    local path = "api/" .. cam
    return "<mjpeg_query_string>" .. C4:XmlEscapeString(path) .. "</mjpeg_query_string>"
end

function getRTSPH264QueryString()
    local src = streamName()
    if not src then return "" end
    return "<rtsp_h264_query_string>" .. C4:XmlEscapeString(src) .. "</rtsp_h264_query_string>"
end

function getSnapshotQueryString()
    local cam = cameraName()
    if not cam then return "" end
    local path = "api/" .. cam .. "/latest.jpg"
    return "<snapshot_query_string>" .. C4:XmlEscapeString(path) .. "</snapshot_query_string>"
end

------------------------------------------------------------------------
-- Proxy Command Handlers
------------------------------------------------------------------------

function PRX_CMD(idBinding, sCommand, tParams)
    -- Ignore standard camera proxy setup commands — we use our own properties
end

------------------------------------------------------------------------
-- Proxy Update Helper
------------------------------------------------------------------------

--- Check if the camera's snapshot URL is reachable from the controller.
local function checkCameraHealth()
    local host = Properties[PROP_HOST] or ""
    local cam = cameraName()
    if host == "" or not cam then return end

    local snapshotURL = "http://" .. host .. ":" .. PORT_HTTP .. "/api/" .. cam .. "/latest.jpg"
    local mjpegURL = "http://" .. host .. ":" .. PORT_HTTP .. "/api/stream.mjpeg?src=" .. (streamName() or cam)

    log(LOG_DEBUG, "Health check: " .. snapshotURL)

    C4:urlGet(snapshotURL, {}, false, function(ticketId, strData, responseCode, tHeaders, strError)
        if responseCode == 200 and (not strError or strError == "") then
            setStatus("Online — " .. cam)
            log(LOG_INFO, cam .. " snapshot OK (HTTP 200, " .. tostring(#(strData or "")) .. " bytes)")
        else
            local err = (strError and strError ~= "") and strError or ("HTTP " .. tostring(responseCode))
            setStatus("Offline — " .. cam .. " (" .. err .. ")")
            log(LOG_ERROR, cam .. " snapshot FAILED: " .. err)
        end

        log(LOG_DEBUG, "Health check MJPEG: " .. mjpegURL)
    end)
end

--- Update the camera proxy with current address, ports, and stream URLs.
--- Must be called whenever host, camera name, or sub-stream changes.
local function updateProxy()
    local host = Properties[PROP_HOST] or ""
    local cam = cameraName()

    if host ~= "" and cam then
        -- Update proxy address and ports (try both DEFAULT and active notifications)
        C4:SendToProxy(PROXY_ID, "ADDRESS_CHANGED", { ADDRESS = host })
        C4:SendToProxy(PROXY_ID, "HTTP_PORT_CHANGED", { PORT = tostring(PORT_HTTP) })
        C4:SendToProxy(PROXY_ID, "RTSP_PORT_CHANGED", { PORT = tostring(PORT_RTSP) })
        C4:SendToProxy(PROXY_ID, "DEFAULT_HTTP_PORT_CHANGED", { PORT = tostring(PORT_HTTP) })
        C4:SendToProxy(PROXY_ID, "DEFAULT_RTSP_PORT_CHANGED", { PORT = tostring(PORT_RTSP) })
        C4:SendToProxy(PROXY_ID, "AUTHENTICATION_REQUIRED_CHANGED", { REQUIRED = "False" })
        C4:SendToProxy(PROXY_ID, "DEFAULT_AUTHENTICATION_REQUIRED_CHANGED", { REQUIRED = "False" })
        C4:SendToProxy(PROXY_ID, "STREAM_URLS_READY", {})
        log(LOG_INFO, "Proxy updated: " .. host .. ":" .. PORT_HTTP .. "/" .. PORT_RTSP .. " / " .. cam)

        -- Run health check to verify streams are reachable
        checkCameraHealth()
    else
        setStatus("Not Configured")
    end
end

------------------------------------------------------------------------
-- Inter-Driver Command Handler (from NVR parent driver)
------------------------------------------------------------------------

function ExecuteCommand(sCommand, tParams)
    if sCommand == "SET_FRIGATE_CONFIG" then
        if tParams then
            local cam = tParams.camera_name or "(unknown)"
            local sub = tParams.use_sub_stream or "(nil)"
            log(LOG_DEBUG, "SET_FRIGATE_CONFIG: cam=" .. cam .. " sub=" .. sub .. " host=" .. (tParams.host or ""))
            if tParams.host and tParams.host ~= "" then
                C4:UpdateProperty(PROP_HOST, tParams.host)
            end
            if tParams.camera_name and tParams.camera_name ~= "" then
                C4:UpdateProperty(PROP_CAMERA, tParams.camera_name)
            end
            if tParams.use_sub_stream ~= nil then
                C4:UpdateProperty(PROP_SUB_STREAM, tParams.use_sub_stream)
            end
            updateProxy()
        end
    elseif sCommand == "FRIGATE_DETECTION" then
        handleDetection(tParams or {})
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
    elseif sCommand == "FRIGATE_MOTION" then
        handleMotion(tParams or {})
    elseif sCommand == "FRIGATE_ZONE" then
        handleZone(tParams or {})
    elseif sCommand == "FRIGATE_LOITERING" then
        handleLoitering(tParams or {})
    elseif sCommand == "FRIGATE_HEALTH" then
        handleHealth(tParams or {})
    elseif sCommand == "FRIGATE_AUDIO" then
        handleAudio(tParams or {})
    elseif sCommand == "FRIGATE_STATE" then
        handleStateChange(tParams or {})
    elseif sCommand == "IDENTIFY_CAMERA" then
        -- NVR driver is asking us what camera we are (for orphan adoption)
        local parentId = tParams and tonumber(tParams.parent_device_id) or nil
        local cam = Properties[PROP_CAMERA] or ""
        if parentId and cam ~= "" then
            C4:SendToDevice(parentId, "ADOPT_RESPONSE", {
                camera_name = cam,
                device_id = C4:GetDeviceID()
            })
        end
    end
end

------------------------------------------------------------------------
-- Property Change Handler
------------------------------------------------------------------------

function OnPropertyChanged(sProperty)
    if sProperty == PROP_HOST or sProperty == PROP_CAMERA or sProperty == PROP_SUB_STREAM then
        updateProxy()
    end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

function OnDriverLateInit()
    C4:UpdateProperty(PROP_VERSION, C4:GetDriverConfigInfo("version") or "23")

    -- Initialize variables for Composer programming
    initVariables()

    -- Register events for push notification support
    registerNotificationEvents()

    -- Update proxy with current config (address, ports, stream URLs)
    updateProxy()
end

function OnDriverDestroyed()
    -- Variables are cleaned up automatically by the system
end
