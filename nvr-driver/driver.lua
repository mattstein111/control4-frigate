--[[
  Frigate NVR Controller Driver for Control4
  Auto-discovery + MQTT detection events + camera lifecycle

  Queries the Frigate REST API to discover cameras, spawns Frigate Camera
  driver instances, subscribes to MQTT for real-time detection/motion/zone
  events, and routes them to the appropriate camera driver for history,
  events, and variables.

  MQTT subscriptions:
    frigate/available              — Frigate online/offline status
    frigate/events                 — full event JSON (for loitering detection)
    frigate/+/person|car|dog|cat   — object count per camera
    frigate/+/motion               — motion ON/OFF per camera
    frigate/+/+/person|car|dog|cat — zone object counts
    frigate/+/audio/+              — audio detection events
    frigate/+/detect/state         — detection enable/disable
    frigate/+/recordings/state     — recording enable/disable

  Orphan adoption:
    On init and via "Adopt Existing Cameras" action, finds frigate-camera
    devices not tracked by this NVR. Sends IDENTIFY_CAMERA; cameras respond
    with ADOPT_RESPONSE containing their camera_name and device_id.

  Persistent storage (survives reboots):
    "managed_cameras" table: { camera_name = { deviceId, proxyId } }
]]

-- Property name constants
local PROP_VERSION     = "Driver Version"
local PROP_HOST        = "Frigate Host"
local PROP_PORT        = "Frigate Port"
local PROP_USER        = "Frigate Username"
local PROP_PASS        = "Frigate Password"
local PROP_MQTT_HOST   = "MQTT Broker"
local PROP_MQTT_PORT   = "MQTT Port"
local PROP_MQTT_USER   = "MQTT Username"
local PROP_MQTT_PASS   = "MQTT Password"
local PROP_SUB         = "Use Sub Streams"
local PROP_STATUS        = "Frigate Status"
local PROP_MQTT_STATUS   = "MQTT Status"
local PROP_FRIGATE_COUNT = "Cameras in Frigate"
local PROP_C4_COUNT      = "Cameras in Control4"
local PROP_MANAGED       = "Managed Cameras"
local PROP_UNMATCHED     = "Unmatched Cameras"
local PROP_LOG_LEVEL   = "Log Level"
local PROP_LOG_MODE    = "Log Mode"
local PROP_AUTO_UPDATE   = "Auto Update"
local PROP_DRIVER_RELEASE = "Driver Release"
local PROP_LATEST        = "Latest Available Version"
local PROP_UPDATE_URL    = "Update Download URL"

-- The camera driver filename (must be loaded on the controller)
local CAMERA_DRIVER   = "frigate-camera.c4z"

-- Current release tag for this driver build. Bumped per release alongside <version>.
-- Used as the comparison baseline for the update checker.
local DRIVER_RELEASE  = "v0.8.7-beta"

-- GitHub repo for auto-update checks
local UPDATE_REPO     = "mattstein111/control4-frigate"

-- Persistence keys
local PERSIST_CAMERAS = "managed_cameras"

-- MQTT client handle (C4:MQTT API, OS 3.3+)
local mqttClient = nil

-- Track previous object counts to detect new vs update events
local prevCounts = {}  -- { "camera/object" = count }

-- Track camera names seen via MQTT that aren't in managed_cameras
local unmatchedCameras = {}  -- { camera_name = true }

-- Reconnect timer
local MQTT_RECONNECT_TIMER = nil
local MQTT_RECONNECT_INTERVAL = 30  -- seconds

-- Periodic health-check timer (recovers Frigate Status if MQTT availability msg missed)
local HEALTH_CHECK_TIMER = nil
local HEALTH_CHECK_INTERVAL = 60  -- seconds

-- Periodic update-check timer (GitHub releases poll; notification-only, no self-install)
local UPDATE_CHECK_TIMER = nil
local UPDATE_CHECK_INTERVAL = 24 * 60 * 60  -- 24 hours in seconds

-- Log levels
local LOG_FATAL   = 0
local LOG_ERROR   = 1
local LOG_WARNING = 2
local LOG_INFO    = 3
local LOG_DEBUG   = 4
local LOG_TRACE   = 5

------------------------------------------------------------------------
-- Logging
------------------------------------------------------------------------

--- Get the current log level from the property.
local function getLogLevel()
    local val = Properties[PROP_LOG_LEVEL] or "2 - Warning"
    return tonumber(val:match("^(%d+)")) or LOG_WARNING
end

--- Get the current log mode from the property.
local function getLogMode()
    return Properties[PROP_LOG_MODE] or "Off"
end

--- Log a message at the given level.
local function log(level, msg)
    if level > getLogLevel() then return end
    local mode = getLogMode()
    if mode == "Off" then return end

    local prefix = "[Frigate NVR] "
    local fullMsg = prefix .. msg

    if mode == "Print" or mode == "Print and Log" then
        print(fullMsg)
    end
    if mode == "Log" or mode == "Print and Log" then
        C4:ErrorLog(fullMsg)
    end
end

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function getManagedCameras()
    local cameras = C4:PersistGetValue(PERSIST_CAMERAS)
    if type(cameras) ~= "table" then cameras = {} end
    return cameras
end

local function saveManagedCameras(cameras)
    C4:PersistSetValue(PERSIST_CAMERAS, cameras)
    updateManagedDisplay(cameras)
end

function updateManagedDisplay(cameras)
    local count = 0
    local names = {}
    for name, _ in pairs(cameras) do
        count = count + 1
        table.insert(names, name)
    end
    table.sort(names)
    C4:UpdateProperty(PROP_C4_COUNT, tostring(count))
    C4:UpdateProperty(PROP_MANAGED, table.concat(names, ", "))
end

local function friendlyName(camName)
    return camName:gsub("_", " "):gsub("(%a)([%w]*)", function(first, rest)
        return first:upper() .. rest
    end)
end

local function setStatus(msg)
    C4:UpdateProperty(PROP_STATUS, msg)
end

local mqttConnected = false

local function setMQTTStatus(msg)
    C4:UpdateProperty(PROP_MQTT_STATUS, msg)
end

local function apiBaseURL()
    local host = Properties[PROP_HOST] or ""
    local port = Properties[PROP_PORT] or "5000"
    if host == "" then return nil end
    return "http://" .. host .. ":" .. port
end

--- Build HTTP headers for Frigate API requests.
local function apiHeaders()
    local headers = {}
    local user = Properties[PROP_USER] or ""
    local pass = Properties[PROP_PASS] or ""
    if user ~= "" then
        local credentials = C4:Base64Encode(user .. ":" .. pass)
        headers["Authorization"] = "Basic " .. credentials
    end
    return headers
end

--- Find the device ID for a managed camera by name.
local function deviceIdForCamera(camName)
    local managed = getManagedCameras()
    local info = managed[camName]
    if info and info.deviceId and info.deviceId > 0 then
        return info.deviceId
    end
    return nil
end

--- Update the Unmatched Cameras property display.
local function updateUnmatchedDisplay()
    local names = {}
    for name, _ in pairs(unmatchedCameras) do
        table.insert(names, name)
    end
    table.sort(names)
    C4:UpdateProperty(PROP_UNMATCHED, #names > 0 and table.concat(names, ", ") or "")
end

--- Send a command to a camera driver instance.
local function sendToCamera(camName, command, params)
    local devId = deviceIdForCamera(camName)
    if devId then
        -- Clear from unmatched if it was previously unmatched
        if unmatchedCameras[camName] then
            unmatchedCameras[camName] = nil
            updateUnmatchedDisplay()
        end
        C4:SendToDevice(devId, command, params)
        log(LOG_DEBUG, "Sent " .. command .. " to " .. tostring(camName) .. " (device " .. devId .. ")")
    else
        if not unmatchedCameras[camName] then
            unmatchedCameras[camName] = true
            updateUnmatchedDisplay()
            log(LOG_WARNING, "No device ID for camera '" .. tostring(camName) .. "' — events will be dropped until synced")
        end
    end
end

------------------------------------------------------------------------
-- Minimal JSON value extractor
------------------------------------------------------------------------

local function jsonString(json, key)
    local pattern = '"' .. key .. '"%s*:%s*"([^"]*)"'
    return json:match(pattern)
end

local function jsonNumber(json, key)
    local pattern = '"' .. key .. '"%s*:%s*([%d%.%-]+)'
    local val = json:match(pattern)
    return val and tonumber(val) or nil
end

local function jsonBool(json, key)
    local pattern = '"' .. key .. '"%s*:%s*(true)'
    return json:match(pattern) ~= nil
end

------------------------------------------------------------------------
-- MQTT Client (C4:MQTT API — OS 3.3+)
------------------------------------------------------------------------

--- Subscribe to all Frigate MQTT topics.
local function subscribeFrigateTopics()
    if not mqttClient then return end

    local topics = {
        "frigate/available",
        "frigate/events",
        -- Per-camera object counts
        "frigate/+/person",
        "frigate/+/car",
        "frigate/+/dog",
        "frigate/+/cat",
        "frigate/+/motion",
        -- Zone events: frigate/<camera>/<zone>/<object>
        "frigate/+/+/person",
        "frigate/+/+/car",
        "frigate/+/+/dog",
        "frigate/+/+/cat",
        -- Audio and state
        "frigate/+/audio/+",
        "frigate/+/detect/state",
        "frigate/+/recordings/state",
    }

    for _, topic in ipairs(topics) do
        mqttClient:Subscribe(topic, 1)
        log(LOG_DEBUG, "Subscribed to: " .. topic)
    end

    log(LOG_INFO, "Subscribed to all Frigate MQTT topics")
end

--- Parse MQTT topic into segments.
local function splitTopic(topic)
    local segments = {}
    for seg in topic:gmatch("[^/]+") do
        table.insert(segments, seg)
    end
    return segments
end

--- Handle the full event JSON from frigate/events topic.
function handleEventJSON(payload)
    if not payload or payload == "" then return end

    local camera = jsonString(payload, "camera")
    local label = jsonString(payload, "label")
    local loitering = jsonBool(payload, "loitering")

    if not camera then
        log(LOG_DEBUG, "Event JSON missing 'camera' field — discarding")
        return
    end

    local zonesStr = payload:match('"current_zones"%s*:%s*%[([^%]]*)%]')
    local zones = {}
    if zonesStr then
        for zone in zonesStr:gmatch('"([^"]+)"') do
            table.insert(zones, zone)
        end
    end

    if loitering and #zones > 0 then
        for _, zone in ipairs(zones) do
            sendToCamera(camera, "FRIGATE_LOITERING", {
                zone = zone,
                object_type = label or "object"
            })
            log(LOG_DEBUG, "Loitering: " .. (label or "object") .. " in " .. zone .. " on " .. camera)
        end
    end
end

--- Main MQTT message handler. Routes messages to camera drivers.
local function onMQTTMessage(obj, msgId, topic, payload, qos, retain)
    log(LOG_TRACE, "MQTT msg: " .. topic .. " = " .. tostring(payload))

    local segments = splitTopic(topic)
    if #segments < 2 or segments[1] ~= "frigate" then return end

    -- frigate/available — Frigate process health (don't overwrite API status)
    if segments[2] == "available" then
        local online = (payload == "online")
        local managed = getManagedCameras()
        for camName, _ in pairs(managed) do
            sendToCamera(camName, "FRIGATE_HEALTH", { online = online })
        end
        if online then
            -- Frigate came back — refresh status via REST to get version info
            checkStatus()
        else
            setStatus("Frigate unavailable (MQTT)")
        end
        log(LOG_INFO, "Frigate available: " .. tostring(payload))
        return
    end

    -- frigate/events
    if segments[2] == "events" then
        handleEventJSON(payload)
        return
    end

    local camName = segments[2]

    -- frigate/<camera>/detect/state or frigate/<camera>/recordings/state
    if #segments == 4 and segments[4] == "state" then
        local setting = segments[3]
        if setting == "detect" or setting == "recordings" then
            local enabled = (payload == "ON")
            sendToCamera(camName, "FRIGATE_STATE", { setting = setting, enabled = enabled })
            log(LOG_DEBUG, setting .. " " .. (enabled and "ON" or "OFF") .. " on " .. camName)
        end
        return
    end

    -- frigate/<camera>/audio/<type> (audio detection events)
    if #segments == 4 and segments[3] == "audio" and segments[4] ~= "state" then
        -- Audio detection payload is a count or score; > 0 means detected
        local val = tonumber(payload) or 0
        if val > 0 then
            local audioType = segments[4]
            sendToCamera(camName, "FRIGATE_AUDIO", { audio_type = audioType })
            log(LOG_TRACE, "Audio: " .. audioType .. " on " .. camName)
        end
        return
    end

    -- frigate/<camera>/motion
    if #segments == 3 and segments[3] == "motion" then
        local active = (payload == "ON")
        sendToCamera(camName, "FRIGATE_MOTION", { active = active })
        log(LOG_DEBUG, "Motion " .. (active and "ON" or "OFF") .. " on " .. camName)
        return
    end

    -- frigate/<camera>/<object>
    if #segments == 3 then
        local objType = segments[3]
        if objType == "person" or objType == "car" or objType == "dog" or objType == "cat" then
            local count = tonumber(payload) or 0
            local key = camName .. "/" .. objType
            local prevCount = prevCounts[key] or 0

            local eventType = "update"
            if prevCount == 0 and count > 0 then
                eventType = "new"
            elseif count == 0 and prevCount > 0 then
                eventType = "end"
            end
            prevCounts[key] = count

            sendToCamera(camName, "FRIGATE_DETECTION", {
                object_type = objType,
                count = count,
                event_type = eventType
            })
            log(LOG_DEBUG, objType .. " " .. eventType .. " (" .. count .. ") on " .. camName)
        end
        return
    end

    -- frigate/<camera>/<zone>/<object>
    if #segments == 4 then
        local zone = segments[3]
        local objType = segments[4]
        if objType == "person" or objType == "car" or objType == "dog" or objType == "cat" then
            local count = tonumber(payload) or 0
            local zoneKey = camName .. "/" .. zone .. "/" .. objType
            local prevCount = prevCounts[zoneKey] or 0
            prevCounts[zoneKey] = count

            sendToCamera(camName, "FRIGATE_ZONE", {
                zone = zone,
                object_type = objType,
                count = count
            })
            log(LOG_DEBUG, objType .. " in zone " .. zone .. " (" .. count .. ") on " .. camName)
        end
        return
    end
end

--- Connect (or reconnect) the MQTT client using C4:MQTT() API.
local function connectMQTT()
    -- Disconnect existing client if any
    if mqttClient then
        mqttClient:Disconnect()
        mqttClient = nil
        mqttConnected = false
    end

    local mqttHost = Properties[PROP_MQTT_HOST] or ""
    local mqttPort = tonumber(Properties[PROP_MQTT_PORT]) or 1883

    if mqttHost == "" then
        setMQTTStatus("Not Configured — set MQTT Broker")
        return
    end

    setMQTTStatus("Connecting...")
    log(LOG_INFO, "Connecting to MQTT at " .. mqttHost .. ":" .. mqttPort)

    -- Create MQTT client using C4:MQTT() API (OS 3.3+)
    local clientId = "control4-frigate-" .. tostring(C4:GetDeviceID())

    local ok, client = pcall(function()
        return C4:MQTT(clientId)
    end)

    if not ok or not client then
        setMQTTStatus("Error: C4:MQTT() not available")
        log(LOG_ERROR, "C4:MQTT() failed — OS 3.3+ required. Error: " .. tostring(client))
        return
    end

    mqttClient = client

    -- Set credentials if configured
    local mqttUser = Properties[PROP_MQTT_USER] or ""
    local mqttPass = Properties[PROP_MQTT_PASS] or ""
    if mqttUser ~= "" then
        mqttClient:SetUsernameAndPassword(mqttUser, mqttPass or "")
    end

    -- Set callbacks using C4:MQTT() API style
    mqttClient:OnConnect(function(obj, reasonCode, flags, message)
        if reasonCode == 0 then
            mqttConnected = true
            setMQTTStatus("Connected")
            log(LOG_INFO, "MQTT connected")

            if MQTT_RECONNECT_TIMER then
                C4:KillTimer(MQTT_RECONNECT_TIMER)
                MQTT_RECONNECT_TIMER = nil
            end

            subscribeFrigateTopics()
        else
            local reason = ""
            if mqttClient and mqttClient.ReasonCodeToString then
                reason = mqttClient:ReasonCodeToString(reasonCode) or tostring(reasonCode)
            else
                reason = tostring(reasonCode)
            end
            setMQTTStatus("Connect failed: " .. reason)
            log(LOG_ERROR, "MQTT connect failed: " .. reason)
            -- Schedule retry on connect failure (not just disconnect)
            if not MQTT_RECONNECT_TIMER then
                MQTT_RECONNECT_TIMER = C4:AddTimer(MQTT_RECONNECT_INTERVAL, "SECONDS", false)
                log(LOG_INFO, "Scheduled MQTT reconnect in " .. MQTT_RECONNECT_INTERVAL .. "s")
            end
        end
    end)

    mqttClient:OnDisconnect(function(obj, reasonCode)
        mqttConnected = false
        setMQTTStatus("Disconnected")
        log(LOG_WARNING, "MQTT disconnected (reason: " .. tostring(reasonCode) .. ")")

        if not MQTT_RECONNECT_TIMER then
            MQTT_RECONNECT_TIMER = C4:AddTimer(MQTT_RECONNECT_INTERVAL, "SECONDS", false)
            log(LOG_INFO, "Scheduled MQTT reconnect in " .. MQTT_RECONNECT_INTERVAL .. "s")
        end
    end)

    mqttClient:OnMessage(onMQTTMessage)

    -- Connect
    mqttClient:Connect(mqttHost, mqttPort, 60)
    log(LOG_DEBUG, "MQTT Connect() called")
end

------------------------------------------------------------------------
-- Frigate API
------------------------------------------------------------------------

local function fetchCameras(callback)
    local base = apiBaseURL()
    if not base then
        setStatus("Not Configured — set Frigate Host")
        if callback then callback(false, {}) end
        return
    end
    local url = base .. "/api/config"

    C4:urlGet(url, apiHeaders(), false, function(ticketId, strData, responseCode, tHeaders, strError)
        if responseCode ~= 200 or (strError and strError ~= "") then
            setStatus("API Error: " .. ((strError and strError ~= "") and strError or ("HTTP " .. tostring(responseCode))))
            if callback then callback(false, {}) end
            return
        end

        local cameraNames = {}
        local camerasBlock = strData:match('"cameras"%s*:%s*{(.+)')
        if camerasBlock then
            local depth = 0
            local pos = 1
            while pos <= #camerasBlock do
                local ch = camerasBlock:sub(pos, pos)
                if ch == "{" then
                    depth = depth + 1
                elseif ch == "}" then
                    if depth == 0 then break end
                    depth = depth - 1
                elseif ch == '"' and depth == 0 then
                    local keyEnd = camerasBlock:find('"', pos + 1)
                    if keyEnd then
                        local key = camerasBlock:sub(pos + 1, keyEnd - 1)
                        table.insert(cameraNames, key)
                        pos = keyEnd
                    end
                end
                pos = pos + 1
            end
        end

        -- Update Frigate camera count
        C4:UpdateProperty(PROP_FRIGATE_COUNT, tostring(#cameraNames))

        if #cameraNames == 0 then
            log(LOG_WARNING, "API returned config but no cameras found")
            if callback then callback(true, cameraNames, {}) end
            return
        end

        log(LOG_INFO, "Found " .. #cameraNames .. " cameras in Frigate")

        -- Query go2rtc runtime API to detect which cameras have sub-streams
        local host = Properties[PROP_HOST] or ""
        local go2rtcURL = "http://" .. host .. ":1984/api/streams"

        C4:urlGet(go2rtcURL, {}, false, function(t2, go2rtcData, rc2, h2, err2)
            local hasSubStream = {}
            if rc2 == 200 and go2rtcData and go2rtcData ~= "" then
                for _, camName in ipairs(cameraNames) do
                    if go2rtcData:find('"' .. camName .. '_sub"') then
                        hasSubStream[camName] = true
                    else
                        hasSubStream[camName] = false
                        log(LOG_INFO, camName .. " has no sub-stream — will use main stream")
                    end
                end
            else
                log(LOG_WARNING, "Could not query go2rtc API — defaulting all to sub-stream")
                for _, camName in ipairs(cameraNames) do
                    hasSubStream[camName] = true
                end
            end

            if callback then callback(true, cameraNames, hasSubStream) end
        end)
    end)
end

--- Auto-populate MQTT broker from Frigate's config if not already set.
local function autoPopulateMQTT()
    local mqttHost = Properties[PROP_MQTT_HOST] or ""
    if mqttHost ~= "" then return end  -- already configured

    local base = apiBaseURL()
    if not base then return end

    local url = base .. "/api/config"
    C4:urlGet(url, apiHeaders(), false, function(ticketId, strData, responseCode, tHeaders, strError)
        if responseCode ~= 200 or not strData then
            log(LOG_WARNING, "Failed to auto-populate MQTT broker: HTTP " .. tostring(responseCode))
            return
        end

        local host = jsonString(strData, "host")
        local port = jsonNumber(strData, "port")

        -- The "host" key appears in multiple sections — find the one under "mqtt"
        local mqttBlock = strData:match('"mqtt"%s*:%s*({.-})')
        if mqttBlock then
            host = jsonString(mqttBlock, "host")
            port = jsonNumber(mqttBlock, "port")
        end

        if host and host ~= "" then
            C4:UpdateProperty(PROP_MQTT_HOST, host)
            log(LOG_INFO, "Auto-populated MQTT Broker from Frigate: " .. host)
            if port then
                C4:UpdateProperty(PROP_MQTT_PORT, tostring(port))
            end
            -- Trigger MQTT connection
            connectMQTT()
        end
    end)
end

local function checkStatus()
    local base = apiBaseURL()
    if not base then
        setStatus("Not Configured — set Frigate Host")
        return
    end
    local url = base .. "/api/version"

    C4:urlGet(url, apiHeaders(), false, function(ticketId, strData, responseCode, tHeaders, strError)
        if responseCode == 200 and (not strError or strError == "") then
            local version = strData:match("[%d%.]+") or strData
            setStatus("Online — Frigate " .. version)
            log(LOG_INFO, "Frigate online: v" .. version)
        else
            setStatus("Offline — " .. ((strError and strError ~= "") and strError or ("HTTP " .. tostring(responseCode))))
            log(LOG_ERROR, "Frigate offline: " .. ((strError and strError ~= "") and strError or ("HTTP " .. tostring(responseCode))))
        end
    end)
end

------------------------------------------------------------------------
-- Adopt Orphan Cameras
------------------------------------------------------------------------

--- Find existing frigate-camera devices not tracked by this NVR and adopt them.
--- Sends IDENTIFY_CAMERA to each untracked camera; they respond asynchronously
--- via ADOPT_RESPONSE with their camera_name.
local function adoptOrphanCameras()
    local managed = getManagedCameras()
    local existingDevices = C4:GetDevicesByC4iName(CAMERA_DRIVER)

    if type(existingDevices) ~= "table" then return end

    -- Build set of already-managed device IDs
    local managedDeviceIds = {}
    for _, info in pairs(managed) do
        if info.deviceId then
            managedDeviceIds[info.deviceId] = true
        end
    end

    local myDeviceId = C4:GetDeviceID()
    local orphanCount = 0

    for devId, _ in pairs(existingDevices) do
        devId = tonumber(devId)
        if devId and not managedDeviceIds[devId] then
            -- Ask this camera to identify itself
            C4:SendToDevice(devId, "IDENTIFY_CAMERA", {
                parent_device_id = tostring(myDeviceId)
            })
            orphanCount = orphanCount + 1
        end
    end

    if orphanCount > 0 then
        log(LOG_INFO, "Sent IDENTIFY_CAMERA to " .. orphanCount .. " untracked camera(s)")
    end
end

--- Handle ADOPT_RESPONSE from a camera identifying itself.
local function handleAdoptResponse(tParams)
    local camName = tParams and tParams.camera_name or ""
    local devId = tParams and tonumber(tParams.device_id) or nil

    if camName == "" or not devId then
        log(LOG_WARNING, "Invalid ADOPT_RESPONSE: camName=" .. tostring(camName) .. " devId=" .. tostring(devId))
        return
    end

    local managed = getManagedCameras()
    if managed[camName] then
        log(LOG_DEBUG, "Camera " .. camName .. " already managed, skipping adopt")
        return
    end

    managed[camName] = {
        deviceId = devId,
        proxyId = nil
    }
    saveManagedCameras(managed)

    -- Send current config to the adopted camera
    local host = Properties[PROP_HOST] or ""
    local useSub = Properties[PROP_SUB] or "Yes"
    C4:SendToDevice(devId, "SET_FRIGATE_CONFIG", {
        host = host,
        camera_name = camName,
        use_sub_stream = useSub
    })

    log(LOG_INFO, "Adopted orphan camera: " .. camName .. " (device " .. devId .. ")")
end

------------------------------------------------------------------------
-- Camera Discovery
------------------------------------------------------------------------

local function discoverCameras()
    setStatus("Discovering...")
    print("[Frigate NVR] discoverCameras() called")

    -- Adopt any orphan cameras first (e.g. from a previous NVR driver instance)
    adoptOrphanCameras()

    fetchCameras(function(success, cameraNames, hasSubStream)
        print("[Frigate NVR] fetchCameras callback: success=" .. tostring(success) .. " cameras=" .. tostring(#cameraNames))
        if not success then return end

        hasSubStream = hasSubStream or {}
        local managed = getManagedCameras()
        local host = Properties[PROP_HOST] or ""
        local globalUseSub = Properties[PROP_SUB] or "Yes"
        local added = 0
        local skipped = 0

        for _, camName in ipairs(cameraNames) do
            -- Auto-detect sub-stream: use sub if available AND global setting is Yes
            local useSub = globalUseSub
            if hasSubStream[camName] == false then
                useSub = "No"
                log(LOG_INFO, camName .. " — no sub-stream, setting Use Sub Stream = No")
            end

            if managed[camName] then
                local devId = managed[camName].deviceId
                if devId and devId > 0 then
                    C4:SendToDevice(devId, "SET_FRIGATE_CONFIG", {
                        host = host,
                        camera_name = camName,
                        use_sub_stream = useSub
                    })
                end
                skipped = skipped + 1
            else
                local displayName = "Frigate — " .. friendlyName(camName)
                local roomId = C4:RoomGetId()
                C4:AddDevice(CAMERA_DRIVER, roomId, displayName, function(deviceId, tDeviceInfo)
                    if deviceId == 0 then
                        log(LOG_ERROR, "Failed to add camera: " .. camName)
                        return
                    end

                    managed[camName] = {
                        deviceId = deviceId,
                        proxyId = nil
                    }

                    if type(tDeviceInfo) == "table" then
                        for k, v in pairs(tDeviceInfo) do
                            if type(v) == "number" and v ~= deviceId then
                                managed[camName].proxyId = v
                                break
                            end
                        end
                    end

                    saveManagedCameras(managed)

                    C4:SendToDevice(deviceId, "SET_FRIGATE_CONFIG", {
                        host = host,
                        camera_name = camName,
                        use_sub_stream = useSub
                    })

                    log(LOG_INFO, "Added camera: " .. camName .. " (device " .. deviceId .. ")")
                end)
                added = added + 1
            end
        end

        -- Clear unmatched list since managed cameras may have changed
        unmatchedCameras = {}
        updateUnmatchedDisplay()

        local msg = "Discovery complete — " .. added .. " added, " .. skipped .. " existing"
        setStatus(msg)
        log(LOG_INFO, msg)
    end)
end

------------------------------------------------------------------------
-- Camera Rename
------------------------------------------------------------------------

local function renameCameras()
    local managed = getManagedCameras()
    local count = 0

    for camName, info in pairs(managed) do
        local id = info.proxyId or info.deviceId
        if id and id > 0 then
            local displayName = friendlyName(camName)
            C4:RenameDevice(id, displayName)
            count = count + 1
            log(LOG_INFO, "Renamed device " .. id .. " to: " .. displayName)
        end
    end

    setStatus("Renamed " .. count .. " cameras")
end

------------------------------------------------------------------------
-- Camera Removal
------------------------------------------------------------------------

local function removeAllCameras()
    local managed = getManagedCameras()
    local count = 0
    for _ in pairs(managed) do count = count + 1 end

    C4:PersistSetValue(PERSIST_CAMERAS, {})
    updateManagedDisplay({})

    setStatus("Cleared tracking of " .. count .. " cameras (remove drivers manually in Composer)")
    log(LOG_INFO, "Cleared tracking of " .. count .. " cameras")
end

------------------------------------------------------------------------
-- Reconciliation
------------------------------------------------------------------------

local function reconcileCameras()
    local managed = getManagedCameras()
    local changed = false

    local existingDevices = C4:GetDevicesByC4iName(CAMERA_DRIVER)
    local existingSet = {}
    if type(existingDevices) == "table" then
        for devId, _ in pairs(existingDevices) do
            existingSet[tonumber(devId)] = true
        end
    end

    for camName, info in pairs(managed) do
        if info.deviceId and not existingSet[info.deviceId] then
            log(LOG_WARNING, "Removing stale tracking for: " .. camName .. " (device " .. info.deviceId .. " gone)")
            managed[camName] = nil
            changed = true
        end
    end

    if changed then
        saveManagedCameras(managed)
    else
        updateManagedDisplay(managed)
    end
end

------------------------------------------------------------------------
-- Auto-update check (notification-only — see c4-conventions §3a)
------------------------------------------------------------------------

--- Parse a semver-ish tag like "v0.8.7-beta" into {major, minor, patch, suffix}.
local function parseVersion(tag)
    if not tag or tag == "" then return nil end
    tag = tag:gsub("^v", "")
    local core, suffix = tag:match("^([%d%.]+)(.*)$")
    if not core then return nil end
    suffix = suffix:gsub("^%-", "")
    local parts = {}
    for n in core:gmatch("(%d+)") do
        table.insert(parts, tonumber(n))
    end
    while #parts < 3 do table.insert(parts, 0) end
    return { parts[1], parts[2], parts[3], suffix ~= "" and suffix or nil }
end

--- Returns -1 / 0 / 1 for a < b / a == b / a > b. A release tag (no suffix)
--- outranks a prerelease tag with the same numeric core (semver rule).
local function compareVersions(a, b)
    local va, vb = parseVersion(a), parseVersion(b)
    if not va or not vb then return 0 end
    for i = 1, 3 do
        if va[i] < vb[i] then return -1 end
        if va[i] > vb[i] then return 1 end
    end
    if va[4] == vb[4] then return 0 end
    if va[4] == nil then return 1 end
    if vb[4] == nil then return -1 end
    if va[4] < vb[4] then return -1 end
    if va[4] > vb[4] then return 1 end
    return 0
end

--- Walk the GitHub releases JSON array and return the first release matching
--- the channel. Releases are newest-first per the GitHub API default.
--- Channel "Beta" includes prereleases; "Release" excludes them. Drafts are
--- always skipped.
local function selectRelease(body, channel)
    local includePrerelease = (channel == "Beta")
    local pos = 1
    while true do
        local tagStart, tagEnd, tag = body:find('"tag_name"%s*:%s*"([^"]+)"', pos)
        if not tag then return nil end
        local _, nextTagStart = body:find('"tag_name"%s*:', tagEnd)
        nextTagStart = nextTagStart or (#body + 1)
        local window = body:sub(tagEnd, nextTagStart)
        local draft = window:match('"draft"%s*:%s*(%w+)') == "true"
        local prerelease = window:match('"prerelease"%s*:%s*(%w+)') == "true"
        if not draft and (includePrerelease or not prerelease) then
            -- Construct the canonical release URL from repo + tag rather than
            -- trying to locate the release's own html_url in the JSON — the
            -- release's html_url sits before "tag_name" in GitHub's output,
            -- so a forward window from tag_name picks up the next release's
            -- author html_url instead.
            local htmlUrl = "https://github.com/" .. UPDATE_REPO .. "/releases/tag/" .. tag
            return {
                tag = tag,
                prerelease = prerelease,
                html_url = htmlUrl,
            }
        end
        pos = nextTagStart
    end
end

--- Poll GitHub Releases and update the three read-only update properties.
--- channelOverride lets the manual "Check for Updates Now" action probe even
--- when Auto Update is Off; pass nil to use the dropdown value.
--- silent = true suppresses the "no update" log line (used for timer polls).
function checkForUpdates(silent, channelOverride)
    local channel = channelOverride or Properties[PROP_AUTO_UPDATE] or "Off"
    if channel == "Off" then
        C4:UpdateProperty(PROP_LATEST, "")
        C4:UpdateProperty(PROP_UPDATE_URL, "")
        if not silent then
            log(LOG_INFO, "Auto Update is Off — not checking")
        end
        return
    end

    local url = "https://api.github.com/repos/" .. UPDATE_REPO .. "/releases"
    local headers = {
        ["User-Agent"] = "control4-frigate-driver/" .. DRIVER_RELEASE,
        ["Accept"]     = "application/vnd.github+json",
    }

    log(LOG_DEBUG, "Checking for updates — channel=" .. channel .. " current=" .. DRIVER_RELEASE)

    C4:urlGet(url, headers, false, function(ticketId, strData, responseCode, tHeaders, strError)
        if strError and strError ~= "" then
            log(LOG_WARNING, "Update check failed: " .. tostring(strError))
            return
        end
        if responseCode ~= 200 then
            log(LOG_WARNING, "Update check HTTP " .. tostring(responseCode))
            return
        end
        if not strData or strData == "" then
            log(LOG_WARNING, "Update check returned empty body")
            return
        end

        local rel = selectRelease(strData, channel)
        if not rel then
            log(LOG_INFO, "No matching release found on channel " .. channel)
            C4:UpdateProperty(PROP_LATEST, "(none)")
            C4:UpdateProperty(PROP_UPDATE_URL, "")
            return
        end

        local cmp = compareVersions(DRIVER_RELEASE, rel.tag)
        C4:UpdateProperty(PROP_LATEST, rel.tag)
        if cmp < 0 then
            local dl = rel.html_url
            C4:UpdateProperty(PROP_UPDATE_URL, dl)
            log(LOG_INFO, string.format(
                "Update available: %s (installed %s). Download: %s",
                rel.tag, DRIVER_RELEASE, dl))
        else
            C4:UpdateProperty(PROP_UPDATE_URL, "")
            if not silent then
                log(LOG_INFO, string.format(
                    "Up to date — installed %s, latest on %s channel is %s",
                    DRIVER_RELEASE, channel, rel.tag))
            end
        end
    end)
end

--- Start the periodic update-check timer if a channel is selected.
--- Safe to call repeatedly — replaces any existing timer.
local function startUpdateCheckTimer()
    if UPDATE_CHECK_TIMER then
        C4:KillTimer(UPDATE_CHECK_TIMER)
        UPDATE_CHECK_TIMER = nil
    end
    local channel = Properties[PROP_AUTO_UPDATE] or "Off"
    if channel == "Off" then
        log(LOG_DEBUG, "Auto Update Off — update check timer not started")
        return
    end
    UPDATE_CHECK_TIMER = C4:AddTimer(UPDATE_CHECK_INTERVAL, "SECONDS", true)
    log(LOG_INFO, "Started update check timer (" .. UPDATE_CHECK_INTERVAL .. "s, channel=" .. channel .. ")")
end

------------------------------------------------------------------------
-- Timer Handler (MQTT reconnect)
------------------------------------------------------------------------

function OnTimerExpired(timerId)
    if timerId == MQTT_RECONNECT_TIMER then
        MQTT_RECONNECT_TIMER = nil
        log(LOG_INFO, "MQTT reconnect timer fired")
        connectMQTT()
    elseif timerId == HEALTH_CHECK_TIMER then
        log(LOG_DEBUG, "Health check timer fired")
        checkStatus()
        if not mqttConnected then
            log(LOG_INFO, "MQTT not connected — reconnecting from health check")
            connectMQTT()
        end
    elseif timerId == UPDATE_CHECK_TIMER then
        log(LOG_DEBUG, "Update check timer fired")
        checkForUpdates(true)
    end
end

------------------------------------------------------------------------
-- Command Handlers
------------------------------------------------------------------------

function ExecuteCommand(sCommand, tParams)
    -- Actions from Composer arrive as LUA_ACTION with the command in tParams
    local cmd = sCommand
    if sCommand == "LUA_ACTION" and tParams then
        cmd = tParams.ACTION or tParams.action or ""
        print("[Frigate NVR] Action: " .. cmd)
    else
        print("[Frigate NVR] ExecuteCommand: " .. tostring(sCommand))
    end

    if cmd == "ADOPT_RESPONSE" then
        handleAdoptResponse(tParams)
        return
    end

    if cmd == "CreateCameras" or cmd == "DiscoverCameras" then
        discoverCameras()
    elseif cmd == "RenameCameras" or cmd == "SyncCameraNames" then
        -- Sync = re-discover (updates config on all existing cameras) + rename
        discoverCameras()
        renameCameras()
    elseif cmd == "RemoveAllCameras" then
        removeAllCameras()
    elseif cmd == "CheckStatus" then
        checkStatus()
        if not mqttConnected then
            log(LOG_INFO, "MQTT not connected — reconnecting as part of status check")
            connectMQTT()
        end
    elseif cmd == "ReconnectMQTT" then
        connectMQTT()
    elseif cmd == "AdoptCameras" then
        adoptOrphanCameras()
    elseif cmd == "CheckUpdates" then
        -- Manual trigger — always runs, even when Auto Update is Off.
        -- When Off, probe against the Release channel so users see what
        -- stable release is available without enabling polling.
        local channel = Properties[PROP_AUTO_UPDATE] or "Off"
        if channel == "Off" then channel = "Release" end
        checkForUpdates(false, channel)
    end
end

------------------------------------------------------------------------
-- Property Change Handler
------------------------------------------------------------------------

function OnPropertyChanged(sProperty)
    if sProperty == PROP_HOST or sProperty == PROP_PORT then
        checkStatus()
        autoPopulateMQTT()
    end
    if sProperty == PROP_MQTT_HOST or sProperty == PROP_MQTT_PORT
       or sProperty == PROP_MQTT_USER or sProperty == PROP_MQTT_PASS then
        connectMQTT()
    end
    if sProperty == PROP_USER or sProperty == PROP_PASS then
        checkStatus()
    end
    if sProperty == PROP_AUTO_UPDATE then
        startUpdateCheckTimer()
        checkForUpdates(false)
    end
end

------------------------------------------------------------------------
-- Lifecycle
------------------------------------------------------------------------

--- Query Frigate for camera count (no creation, just updates the property).
local function refreshFrigateCameraCount()
    fetchCameras(function(success, cameraNames)
        -- fetchCameras already updates PROP_FRIGATE_COUNT
        -- Nothing else to do here
    end)
end

function OnDriverLateInit()
    C4:UpdateProperty(PROP_VERSION, C4:GetDriverConfigInfo("version") or "27")
    C4:UpdateProperty(PROP_DRIVER_RELEASE, DRIVER_RELEASE)
    log(LOG_INFO, "Driver initializing — release " .. DRIVER_RELEASE)
    reconcileCameras()
    adoptOrphanCameras()
    checkStatus()
    refreshFrigateCameraCount()
    connectMQTT()

    -- Start periodic health check so status self-corrects if MQTT availability msg is missed
    HEALTH_CHECK_TIMER = C4:AddTimer(HEALTH_CHECK_INTERVAL, "SECONDS", true)
    log(LOG_INFO, "Started health check timer (" .. HEALTH_CHECK_INTERVAL .. "s)")

    -- Start update-check timer (silent by design when Auto Update is Off) and
    -- run an initial poll so property values populate immediately.
    startUpdateCheckTimer()
    checkForUpdates(true)
end

function OnDriverDestroyed()
    if mqttClient then
        mqttClient:Disconnect()
        mqttClient = nil
    end
    if MQTT_RECONNECT_TIMER then
        C4:KillTimer(MQTT_RECONNECT_TIMER)
        MQTT_RECONNECT_TIMER = nil
    end
    if HEALTH_CHECK_TIMER then
        C4:KillTimer(HEALTH_CHECK_TIMER)
        HEALTH_CHECK_TIMER = nil
    end
    if UPDATE_CHECK_TIMER then
        C4:KillTimer(UPDATE_CHECK_TIMER)
        UPDATE_CHECK_TIMER = nil
    end
end
