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
    MOTION_ACTIVE (bool), CAMERA_ONLINE (bool)
    PERSON_COUNT, CAR_COUNT (int)
    LAST_OBJECT_TYPE, LAST_ZONE, LAST_DETECTION_TIME (string)
]]

-- Property name constants
local PROP_VERSION     = "Driver Version"
local PROP_HOST        = "Frigate Host"
local PROP_CAMERA      = "Camera Name"
local PROP_SUB_STREAM  = "Use Sub Stream"
local PROP_STATUS      = "Camera Status"
local PROP_LAST_EVENT  = "Last Event"

-- Ports
-- MJPEG and snapshots both served by Frigate API on port 5000
-- go2rtc MJPEG (1984) doesn't start sources on-demand — unusable for C4
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
    VAR.MOTION_ACTIVE      = C4:AddVariable("MOTION_ACTIVE", "false", "BOOL")
    VAR.CAMERA_ONLINE      = C4:AddVariable("CAMERA_ONLINE", "true", "BOOL")

    -- Numeric variables
    VAR.PERSON_COUNT       = C4:AddVariable("PERSON_COUNT", "0", "NUMBER")
    VAR.CAR_COUNT          = C4:AddVariable("CAR_COUNT", "0", "NUMBER")

    -- String variables
    VAR.LAST_OBJECT_TYPE   = C4:AddVariable("LAST_OBJECT_TYPE", "", "STRING")
    VAR.LAST_ZONE          = C4:AddVariable("LAST_ZONE", "", "STRING")
    VAR.LAST_DETECTION_TIME = C4:AddVariable("LAST_DETECTION_TIME", "", "STRING")
end

local function setVar(varId, value)
    if varId then
        C4:SetVariable(varId, tostring(value))
    end
end

------------------------------------------------------------------------
-- History (visible in C4 app + touchscreens)
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

--- Fire a named event declared in driver.xml <events>.
local function fireEvent(eventName)
    C4:FireEvent(eventName)
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

    -- Update variables
    setVar(VAR.LAST_OBJECT_TYPE, objType)
    setVar(VAR.LAST_DETECTION_TIME, ts)

    if objType == "person" then
        setVar(VAR.PERSON_COUNT, count)
        setVar(VAR.PERSON_DETECTED, count > 0 and "true" or "false")
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
    local active = tParams.active
    setVar(VAR.MOTION_ACTIVE, active and "true" or "false")

    if active then
        fireEvent("Motion Started")
        recordHistory("Motion started", "Info")
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

    setVar(VAR.LAST_ZONE, zone)
    setVar(VAR.LAST_OBJECT_TYPE, objType)
    setVar(VAR.LAST_DETECTION_TIME, timestamp())

    if count > 0 then
        fireEvent("Zone Entered")
        recordHistory(friendly .. " entered zone: " .. friendlyZ, "Info")
    else
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

    setVar(VAR.LAST_ZONE, zone)
    setVar(VAR.LAST_OBJECT_TYPE, objType)
    setVar(VAR.LAST_DETECTION_TIME, timestamp())

    fireEvent("Loitering Detected")
    recordHistory(friendly .. " loitering in zone: " .. friendlyZ, "Warning")
    C4:UpdateProperty(PROP_LAST_EVENT, friendly .. " loitering in " .. friendlyZ .. " — " .. timestamp())
end

--- Handle camera health status.
--- tParams: { online=true|false }
local function handleHealth(tParams)
    local online = tParams.online
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
-- Dynamic Stream URL Handlers
------------------------------------------------------------------------

function UIRequest(sCommand, tParams)
    print("[Frigate Camera] UIRequest: " .. tostring(sCommand))
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

    print("[Frigate Camera] Health check: " .. snapshotURL)

    C4:urlGet(snapshotURL, {}, false, function(ticketId, strData, responseCode, tHeaders, strError)
        if responseCode == 200 and (not strError or strError == "") then
            setStatus("Online — " .. cam)
            print("[Frigate Camera] " .. cam .. " snapshot OK (HTTP 200, " .. tostring(#(strData or "")) .. " bytes)")
        else
            local err = (strError and strError ~= "") and strError or ("HTTP " .. tostring(responseCode))
            setStatus("Offline — " .. cam .. " (" .. err .. ")")
            print("[Frigate Camera] " .. cam .. " snapshot FAILED: " .. err)
        end

        -- Also test MJPEG endpoint (just check if it responds, don't download the stream)
        print("[Frigate Camera] Health check MJPEG: " .. mjpegURL)
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
        print("[Frigate Camera] Proxy updated: " .. host .. ":" .. PORT_HTTP .. "/" .. PORT_RTSP .. " / " .. cam)

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
            print("[Frigate Camera] SET_FRIGATE_CONFIG: cam=" .. cam .. " sub=" .. sub .. " host=" .. (tParams.host or ""))
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
    C4:UpdateProperty(PROP_VERSION, C4:GetDriverConfigInfo("version") or "21")

    -- Initialize variables for Composer programming
    initVariables()

    -- Update proxy with current config (address, ports, stream URLs)
    updateProxy()
end

function OnDriverDestroyed()
    -- Variables are cleaned up automatically by the system
end
