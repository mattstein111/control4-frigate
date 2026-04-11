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

-- Variable IDs (assigned in OnDriverLateInit)
local VAR = {}

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

local function initVariables()
    -- Boolean variables
    VAR.PERSON_DETECTED    = C4:AddVariable("PERSON_DETECTED", "false", "BOOL")
    VAR.CAR_DETECTED       = C4:AddVariable("CAR_DETECTED", "false", "BOOL")
    VAR.DOG_DETECTED       = C4:AddVariable("DOG_DETECTED", "false", "BOOL")
    VAR.CAT_DETECTED       = C4:AddVariable("CAT_DETECTED", "false", "BOOL")
    VAR.MOTION_DETECTED    = C4:AddVariable("MOTION_DETECTED", "false", "BOOL")
    VAR.CAMERA_ONLINE      = C4:AddVariable("CAMERA_ONLINE", "true", "BOOL")

    -- Numeric variables
    VAR.PERSON_COUNT       = C4:AddVariable("PERSON_COUNT", "0", "NUMBER")
    VAR.CAR_COUNT          = C4:AddVariable("CAR_COUNT", "0", "NUMBER")

    -- State variables
    VAR.DETECTION_ENABLED  = C4:AddVariable("DETECTION_ENABLED", "true", "BOOL")
    VAR.RECORDING_ENABLED  = C4:AddVariable("RECORDING_ENABLED", "true", "BOOL")
    VAR.LOITERING_DETECTED = C4:AddVariable("LOITERING_DETECTED", "false", "BOOL")

    -- Last-seen timestamps (object/motion/loitering)
    VAR.PERSON_LAST_SEEN       = C4:AddVariable("PERSON_LAST_SEEN", "", "STRING")
    VAR.CAR_LAST_SEEN          = C4:AddVariable("CAR_LAST_SEEN", "", "STRING")
    VAR.DOG_LAST_SEEN          = C4:AddVariable("DOG_LAST_SEEN", "", "STRING")
    VAR.CAT_LAST_SEEN          = C4:AddVariable("CAT_LAST_SEEN", "", "STRING")
    VAR.MOTION_LAST_SEEN       = C4:AddVariable("MOTION_LAST_SEEN", "", "STRING")
    VAR.LOITERING_LAST_SEEN    = C4:AddVariable("LOITERING_LAST_SEEN", "", "STRING")

    -- Last-heard timestamps (audio)
    VAR.AUDIO_LAST_HEARD           = C4:AddVariable("AUDIO_LAST_HEARD", "", "STRING")
    VAR.SPEECH_LAST_HEARD          = C4:AddVariable("SPEECH_LAST_HEARD", "", "STRING")
    VAR.BARK_LAST_HEARD            = C4:AddVariable("BARK_LAST_HEARD", "", "STRING")
    VAR.SCREAM_LAST_HEARD          = C4:AddVariable("SCREAM_LAST_HEARD", "", "STRING")
    VAR.YELL_LAST_HEARD            = C4:AddVariable("YELL_LAST_HEARD", "", "STRING")
    VAR.FIRE_ALARM_LAST_HEARD      = C4:AddVariable("FIRE_ALARM_LAST_HEARD", "", "STRING")
    VAR.GLASS_BREAKING_LAST_HEARD  = C4:AddVariable("GLASS_BREAKING_LAST_HEARD", "", "STRING")
    VAR.SIREN_LAST_HEARD           = C4:AddVariable("SIREN_LAST_HEARD", "", "STRING")
    VAR.CAR_HORN_LAST_HEARD        = C4:AddVariable("CAR_HORN_LAST_HEARD", "", "STRING")
    VAR.MUSIC_LAST_HEARD           = C4:AddVariable("MUSIC_LAST_HEARD", "", "STRING")
end

local function setVar(varId, value)
    if varId then
        C4:SetVariable(varId, tostring(value))
    end
end

------------------------------------------------------------------------
-- History (visible in Control4 app + touchscreens)
------------------------------------------------------------------------

--- Record an event in the device's history log.
--- severity: "Info", "Warning", "Critical"
local function recordHistory(message, severity)
    severity = severity or "Info"
    -- C4:RecordHistory records to the device's history in the C4 app
    -- Parameters: severity, event category, event description, details
    C4:RecordHistory(severity, "Camera", message, "")
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
            recordHistory(friendly .. " detected", "Info")
        elseif count == 0 then
            fireEvent("Person Left")
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info")
        end
    elseif objType == "car" then
        setVar(VAR.CAR_COUNT, count)
        setVar(VAR.CAR_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.CAR_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Car Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info")
        elseif count == 0 then
            fireEvent("Car Left")
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info")
        end
    elseif objType == "dog" then
        setVar(VAR.DOG_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.DOG_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Dog Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info")
        elseif count == 0 then
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info")
        end
    elseif objType == "cat" then
        setVar(VAR.CAT_DETECTED, count > 0 and "true" or "false")
        if count > 0 then setVar(VAR.CAT_LAST_SEEN, ts) end
        if count > 0 and eventType == "new" then
            fireEvent("Cat Detected")
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info")
        elseif count == 0 then
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info")
        end
    else
        -- Generic object
        if count > 0 and eventType == "new" then
            fireEvent("Object Detected")
            recordHistory(friendly .. " detected", "Info")
        elseif count == 0 then
            fireEvent("Object Left")
            recordHistory(friendly .. " left", "Info")
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
        recordHistory("Motion detected", "Info")
    else
        fireEvent("Motion Stopped")
        recordHistory("Motion stopped", "Info")
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
        recordHistory(friendly .. " entered zone: " .. friendlyZ, "Info")
    else
        -- Reset loitering when zone clears
        setVar(VAR.LOITERING_DETECTED, "false")
        fireEvent("Zone Exited")
        recordHistory(friendly .. " left zone: " .. friendlyZ, "Info")
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
    recordHistory(friendly .. " loitering in zone: " .. friendlyZ, "Warning")
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
        recordHistory("Camera came online", "Info")
    else
        fireEvent("Camera Offline")
        setStatus("Offline")
        recordHistory("Camera went offline", "Warning")
    end
end

------------------------------------------------------------------------
-- Audio Detection Handler
------------------------------------------------------------------------

--- Map Frigate audio type names to event names.
local AUDIO_EVENTS = {
    speech         = "Audio: Speech",
    bark           = "Audio: Bark",
    scream         = "Audio: Scream",
    yell           = "Audio: Yell",
    fire_alarm     = "Audio: Fire Alarm",
    glass_breaking = "Audio: Glass Breaking",
    siren          = "Audio: Siren",
    car_horn       = "Audio: Car Horn",
    music          = "Audio: Music",
}

--- Handle audio detection from Frigate.
--- tParams: { audio_type="speech" }
local function handleAudio(tParams)
    local audioType = tParams.audio_type or "unknown"
    local friendly = friendlyObject(audioType:gsub("_", " "))
    local ts = timestamp()

    -- Update last-heard timestamps
    setVar(VAR.AUDIO_LAST_HEARD, ts)
    local AUDIO_LAST_HEARD_VARS = {
        speech         = VAR.SPEECH_LAST_HEARD,
        bark           = VAR.BARK_LAST_HEARD,
        scream         = VAR.SCREAM_LAST_HEARD,
        yell           = VAR.YELL_LAST_HEARD,
        fire_alarm     = VAR.FIRE_ALARM_LAST_HEARD,
        glass_breaking = VAR.GLASS_BREAKING_LAST_HEARD,
        siren          = VAR.SIREN_LAST_HEARD,
        car_horn       = VAR.CAR_HORN_LAST_HEARD,
        music          = VAR.MUSIC_LAST_HEARD,
    }
    if AUDIO_LAST_HEARD_VARS[audioType] then
        setVar(AUDIO_LAST_HEARD_VARS[audioType], ts)
    end

    local eventName = AUDIO_EVENTS[audioType]
    if eventName then
        fireEvent(eventName)
    end
    fireEvent("Audio Detected")
    recordHistory("Audio: " .. friendly, "Info")
    C4:UpdateProperty(PROP_LAST_EVENT, "Audio: " .. friendly .. " — " .. ts)
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
            recordHistory("Detection enabled", "Info")
        else
            fireEvent("Detection Disabled")
            recordHistory("Detection disabled", "Warning")
        end
    elseif setting == "recordings" then
        setVar(VAR.RECORDING_ENABLED, enabled and "true" or "false")
        if enabled then
            fireEvent("Recording Enabled")
            recordHistory("Recording enabled", "Info")
        else
            fireEvent("Recording Disabled")
            recordHistory("Recording disabled", "Warning")
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
    log(LOG_DEBUG, "GetNotificationAttachmentURL called (binding=" .. tostring(idBinding) .. " cam=" .. tostring(cam) .. ")")
    if host == "" or not cam then return "" end
    local url = "http://" .. host .. ":" .. PORT_HTTP .. "/api/" .. cam .. "/latest.jpg"
    log(LOG_DEBUG, "Snapshot URL: " .. url)
    return url
end

--- Register detection events with the History Agent for push notifications.
local function registerNotificationEvents()
    local proxyDevices = C4:GetProxyDevices()
    if type(proxyDevices) ~= "table" then return end

    local proxyDeviceId = nil
    for id, _ in pairs(proxyDevices) do
        proxyDeviceId = id
        break
    end
    if not proxyDeviceId then return end

    local types = {
        "Person Detected", "Car Detected", "Dog Detected", "Cat Detected",
        "Object Detected", "Motion Detected", "Loitering Detected",
        "Camera Online", "Camera Offline"
    }

    local typeList = ""
    for _, t in ipairs(types) do
        typeList = typeList .. '<type name="' .. t .. '"/>'
    end

    local xml = '<events>'
        .. '<device id="' .. proxyDeviceId .. '"/>'
        .. '<categories><category name="Cameras">'
        .. '<subcategories><subcategory name="Frigate">'
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
