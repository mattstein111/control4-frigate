# Control4 Frigate Driver

**Bring your Frigate NVR cameras into Control4 — with auto-discovery, live streams on every navigator, real-time AI detection events, and full Composer Pro programming.**

![Control4](https://img.shields.io/badge/Control4-OS%203.3%2B-ff6600)
![Frigate](https://img.shields.io/badge/Frigate-0.14%2B-blue)
![Cameras](https://img.shields.io/badge/Cameras-Unlimited-brightgreen)
![Events](https://img.shields.io/badge/Events-29%20Types-purple)
![Variables](https://img.shields.io/badge/Variables-27-cyan)
![License](https://img.shields.io/badge/License-MIT-green)

---

## What This Does

This driver connects [Frigate NVR](https://frigate.video) — the popular open-source NVR with AI-powered object detection — to Control4. Once installed, your customers get:

- **Every Frigate camera** visible on T3/T4 touchscreens, mobile apps, and on-screen navigators
- **AI detection events** (person, car, dog, cat, motion) available for Composer Pro programming
- **Full event history** in the Control4 app — "Person detected at Front Door" with timestamps
- **Composer variables** for conditional logic — "if person count > 0 on Driveway, then..."
- **Zone and loitering alerts** — "car loitering in No Parking zone" triggers notifications

The driver uses Frigate's standard APIs. RTSP restreaming requires cameras to route through go2rtc (default in Docker installs — see [prerequisites](#prerequisites)).

---

## How It Works

```mermaid
graph TD
    subgraph Frigate Server
        F[Frigate NVR]
        G[go2rtc<br/>Stream Server]
        M[MQTT Broker]
    end

    subgraph Control4 Controller
        NVR[Frigate NVR Driver<br/><i>1 instance</i>]
        C1[Frigate Camera<br/>Front Door]
        C2[Frigate Camera<br/>Driveway]
        C3[Frigate Camera<br/>Patio]
        CN[Frigate Camera<br/>...]
    end

    subgraph Navigators
        TS[T3/T4 Touchscreens<br/><i>MJPEG</i>]
        APP[Mobile Apps<br/><i>RTSP H.264</i>]
        TV[On-Screen<br/><i>MJPEG</i>]
    end

    F -->|REST API<br/>camera discovery| NVR
    M -->|MQTT<br/>detection events| NVR
    NVR -->|auto-creates| C1 & C2 & C3 & CN
    F -->|MJPEG :5000| TS & TV
    G -->|RTSP :8554| APP
    F -->|Snapshots :5000| TS & APP & TV

    style F fill:#3b82f6,color:#fff
    style G fill:#3b82f6,color:#fff
    style M fill:#3b82f6,color:#fff
    style NVR fill:#f97316,color:#fff
    style C1 fill:#f97316,color:#fff
    style C2 fill:#f97316,color:#fff
    style C3 fill:#f97316,color:#fff
    style CN fill:#f97316,color:#fff
    style TS fill:#8b5cf6,color:#fff
    style APP fill:#8b5cf6,color:#fff
    style TV fill:#8b5cf6,color:#fff
```

Two drivers work together:

| Driver | Purpose |
|--------|---------|
| **Frigate NVR** | Connects to Frigate. Discovers cameras. Subscribes to MQTT for detection events. Creates and manages camera drivers. *Add one per Frigate server.* |
| **Frigate Camera** | Standard camera proxy. Provides MJPEG/RTSP/snapshot streams. Fires events, updates variables, logs history. *Auto-created by the NVR driver — one per camera.* |

---

## Installation Guide

### Prerequisites

Before you begin, confirm the following with the homeowner or IT contact:

| Requirement | Details |
|-------------|---------|
| **Frigate NVR** | Version 0.14 or newer, with go2rtc enabled (default in modern Frigate) |
| **Frigate cameras routed through go2rtc** | Frigate's ffmpeg inputs must pull from go2rtc (see below) |
| **MQTT Broker** | Mosquitto or similar, accessible from the Control4 controller's network |
| **Network access** | Controller must reach the Frigate server on ports 5000 and 8554 |
| **Control4 OS** | 3.3.0 or newer (required for C4:MQTT API and C4:AddDevice) |

> **Tip:** Ask the homeowner for the Frigate server IP, MQTT broker IP, and whether either requires authentication. Most home setups run without auth on the LAN.

### Frigate Streaming Requirement — Cameras Must Route Through go2rtc

This driver serves video to Control4 navigators via two paths:

- **MJPEG** (touchscreens) — from Frigate's API at `http://host:5000/api/<camera>` — always works
- **RTSP** (mobile apps) — from go2rtc's restream at `rtsp://host:8554/<camera>` — **requires go2rtc to have active sources**

For RTSP to work, Frigate's ffmpeg must pull camera streams **through go2rtc**, not directly from cameras. This is the default in Docker-based Frigate installs, but may not be configured in native/bare-metal installs.

**How to verify:** Check your Frigate config — camera inputs should look like this:

```yaml
# Correct — Frigate pulls through go2rtc (RTSP restreaming works)
cameras:
  front_door:
    ffmpeg:
      inputs:
        - path: rtsp://127.0.0.1:8554/front_door_sub
          roles: [detect]
        - path: rtsp://127.0.0.1:8554/front_door
          roles: [record]
```

**Not this:**

```yaml
# Won't work for RTSP — Frigate pulls directly from camera, go2rtc has no active source
cameras:
  front_door:
    ffmpeg:
      inputs:
        - path: rtsp://admin:pass@192.168.1.100:554/stream1
          roles: [detect]
```

If cameras pull directly, go2rtc's RTSP server returns 404 because no source is active. MJPEG and snapshots still work (they come from Frigate's API, not go2rtc), but RTSP for mobile apps will not.

**If your cameras use non-standard RTSP auth** (e.g., Speco NVRs with MD5-uppercase digest), go2rtc's native RTSP client may fail to connect. The workaround is to use go2rtc's `ffmpeg:` source backend with `#video=copy#audio=copy` (zero-overhead passthrough). Create a `go2rtc_overrides.yml` file with `ffmpeg:rtsp://...#video=copy#audio=copy` sources, and a wrapper script at `/config/go2rtc` that appends `-config=/config/go2rtc_overrides.yml` to load it after Frigate's generated config.

### Step 1 — Load the Drivers

1. Download the two `.c4z` driver files from the [latest release](https://github.com/mattstein111/control4-frigate/releases/latest) on GitHub:
   - `frigate-nvr.c4z`
   - `frigate-camera.c4z`

   > Beta releases are published as GitHub **prereleases** and are visible only on the [full releases page](https://github.com/mattstein111/control4-frigate/releases). `Latest` always points at the most recent stable build.

2. In Composer Pro, go to **System Design → Driver menu → Add or Update Driver or Agent**
3. Browse to each `.c4z` file and add it. Repeat for both files.

> **Important:** Both drivers must be loaded onto the controller before creating cameras. The NVR driver creates camera instances from the camera driver file.

### Step 2 — Add the NVR Driver

1. In the **Search** tab on the right side of Composer Pro, search for **Frigate**
2. You should see two results: **Frigate NVR** and **Frigate Camera**
3. Double-click **Frigate NVR** to add it to your project (add it to any room — Rack Room is typical)
4. Select the driver in the project tree and configure these properties in the **Advanced Properties** section at the bottom:

> **Note:** The NVR driver uses a combo driver proxy, so no Camera Properties panel is shown. All configuration is in the Advanced Properties section.

| Property | What to Enter |
|----------|---------------|
| **Frigate Host** | IP address of the Frigate server (e.g., `10.0.1.50`) |
| **Frigate Port** | Usually `5000` (default) |
| **Frigate Username** | Only if Frigate has auth enabled — otherwise leave blank |
| **Frigate Password** | Only if Frigate has auth enabled — otherwise leave blank |
| **MQTT Broker** | IP address of the MQTT broker. **Auto-populated** from Frigate's config when you set the Frigate Host — only change if your broker is on a different server. |
| **MQTT Port** | Usually `1883` (default) |
| **MQTT Username** | Only if the broker requires auth — otherwise leave blank |
| **MQTT Password** | Only if the broker requires auth — otherwise leave blank |
| **Use Sub Streams** | **Yes** (recommended) — uses 720p H.264 sub-streams. Set to No only if cameras don't have sub-streams configured. |

5. Scroll down to verify the read-only status properties:
   - **Frigate Status** should show `Online — Frigate X.X.X`
   - **MQTT Status** should show `Connected`
   - **Cameras in Frigate** should show a number (e.g., `13`)

> **If Frigate Status shows "Offline":** Verify the IP and port. Open `http://<frigate-ip>:5000` in a browser to confirm Frigate is running. Check firewall rules between the controller and Frigate.
>
> **If MQTT Status stays "Connecting...":** Verify the broker IP and port. Ensure the MQTT broker allows connections from the controller's IP. If the broker requires authentication, enter the MQTT Username and Password.

### Step 3 — Create / Relink Cameras

1. In the driver's **Actions** tab, click **Create / Relink Cameras**
2. The driver queries Frigate and creates a camera driver for each camera found
3. **Cameras in Frigate** and **Cameras in Control4** properties update to show counts
4. New cameras appear in the project tree under the same room as the NVR driver
5. Cameras without a sub-stream in go2rtc (e.g., single-stream door stations) are automatically configured to use the main stream

> **Safe to re-run:** Creation is idempotent. Running it again adds only new cameras and updates existing ones. It will never create duplicates.

### Step 4 — Assign Cameras to Rooms

1. In the project tree, drag each camera driver to the room where that camera is physically located
2. Each camera is an **independent device** — it can live in any room, completely separate from the NVR driver

### Step 5 — Synchronize (Optional)

After assigning cameras to rooms, click **Synchronize Cameras with Frigate** to:
- Update all camera configurations (host, sub-stream settings)
- Rename cameras to match Frigate names, title-cased:
  - `driveway_to_gate` → **Driveway To Gate**
  - `front_door` → **Front Door**
  - `garage_internal` → **Garage Internal**

> Use Synchronize any time you add cameras to Frigate, change the Frigate host, or want to refresh names. The Composer project tree refreshes automatically.

### Step 6 — Verify Streams

1. Select any camera driver in the project tree
2. Go to the **Camera Test** tab in Properties
3. Click **Get Snapshot URL** then **Test** — should pass
4. Click **Get MJPEG URL** then **Test** — should pass
5. On a connected touchscreen or the Control4 mobile app, navigate to the camera to verify live video

> **RTSP Camera Test** may fail for cameras with HEVC (H.265) sub-streams — this is expected. The Control4 test tool only validates H.264 RTSP. Video will still work in the mobile app via MJPEG fallback. For full RTSP support, configure your cameras' sub-streams as H.264.

### Step 7 — Program Events (Optional)

Detection events are already flowing. See [Programming Examples](#programming-examples) below for common automations.

---

## What the Customer Sees

### On Touchscreens & Mobile Apps
- Live camera feeds with MJPEG (touchscreens) or RTSP H.264 (mobile)
- Camera accessible from the room where it's assigned
- Standard Control4 camera viewer UI

### In the Control4 App History
Every detection event is logged with a timestamp:
- *"Person detected"*
- *"Car left"*
- *"Motion started"*
- *"Person entered zone: Front Porch"*
- *"Car loitering in zone: No Parking"* (Warning severity)

---

## Detection Events

```mermaid
graph LR
    CAM[IP Camera] -->|video| FR[Frigate<br/>AI Detection]
    FR -->|MQTT event| MQTT[MQTT Broker]
    MQTT -->|subscribe| NVR[NVR Driver]
    NVR -->|route by camera| CAMERA[Camera Driver]
    CAMERA --> E[Fire Event<br/><i>Composer programming</i>]
    CAMERA --> H[Record History<br/><i>App timeline</i>]
    CAMERA --> V[Set Variable<br/><i>Conditionals</i>]

    style CAM fill:#6b7280,color:#fff
    style FR fill:#3b82f6,color:#fff
    style MQTT fill:#3b82f6,color:#fff
    style NVR fill:#f97316,color:#fff
    style CAMERA fill:#f97316,color:#fff
    style E fill:#10b981,color:#fff
    style H fill:#10b981,color:#fff
    style V fill:#10b981,color:#fff
```

### Programmable Events

These events are available in Composer Pro under each camera's **Events** tab:

| Event | When It Fires |
|-------|---------------|
| **Person Detected** | A person appears in the camera's field of view |
| **Person Left** | All persons have left the frame |
| **Car Detected** | A car appears |
| **Car Left** | All cars have left |
| **Dog Detected** | A dog appears |
| **Cat Detected** | A cat appears |
| **Object Detected** | Any object detected (generic catch-all) |
| **Object Left** | An object type's count drops to zero |
| **Motion Detected** | Motion is detected |
| **Motion Stopped** | Motion ends |
| **Zone Entered** | An object enters a configured detection zone |
| **Zone Exited** | All objects of a type leave a zone |
| **Loitering Detected** | An object stays in a zone beyond the configured time limit |
| **Camera Online** | Camera becomes reachable |
| **Camera Offline** | Camera becomes unreachable |
| **Audio: Speech** | Speech audio detected by Frigate |
| **Audio: Bark** | Dog bark audio detected |
| **Audio: Scream** | Scream audio detected |
| **Audio: Yell** | Yell audio detected |
| **Audio: Fire Alarm** | Fire alarm sound detected |
| **Audio: Glass Breaking** | Glass breaking sound detected |
| **Audio: Siren** | Siren sound detected |
| **Audio: Car Horn** | Car horn sound detected |
| **Audio: Music** | Music audio detected |
| **Audio Detected** | Any audio event detected (generic catch-all) |
| **Detection Enabled** | Object detection turned on for this camera |
| **Detection Disabled** | Object detection turned off for this camera |
| **Recording Enabled** | Recording turned on for this camera |
| **Recording Disabled** | Recording turned off for this camera |

### Composer Variables

Available under each camera for conditional programming:

| Variable | Type | Example Use |
|----------|------|-------------|
| `PERSON_DETECTED` | Boolean | "If person detected, turn on lights" |
| `CAR_DETECTED` | Boolean | "If car detected, open garage" |
| `DOG_DETECTED` | Boolean | "If dog detected, sound chime" |
| `CAT_DETECTED` | Boolean | "If cat detected, close pet door" |
| `MOTION_DETECTED` | Boolean | "If motion detected, keep lights on" |
| `CAMERA_ONLINE` | Boolean | "If camera offline, send alert" |
| `DETECTION_ENABLED` | Boolean | "If detection disabled, send alert" |
| `RECORDING_ENABLED` | Boolean | "If recording disabled, send alert" |
| `LOITERING_DETECTED` | Boolean | "If loitering, send notification" |
| `PERSON_COUNT` | Number | "If person count > 2, alert homeowner" |
| `CAR_COUNT` | Number | "If car count = 0, arm alarm" |
| `PERSON_LAST_SEEN` | String | Timestamp of last person detection |
| `CAR_LAST_SEEN` | String | Timestamp of last car detection |
| `DOG_LAST_SEEN` | String | Timestamp of last dog detection |
| `CAT_LAST_SEEN` | String | Timestamp of last cat detection |
| `MOTION_LAST_SEEN` | String | Timestamp of last motion |
| `LOITERING_LAST_SEEN` | String | Timestamp of last loitering event |
| `AUDIO_LAST_HEARD` | String | Timestamp of last audio event |
| `SPEECH_LAST_HEARD` | String | Timestamp of last speech detection |
| `BARK_LAST_HEARD` | String | Timestamp of last bark detection |
| `SCREAM_LAST_HEARD` | String | Timestamp of last scream |
| `YELL_LAST_HEARD` | String | Timestamp of last yell |
| `FIRE_ALARM_LAST_HEARD` | String | Timestamp of last fire alarm |
| `GLASS_BREAKING_LAST_HEARD` | String | Timestamp of last glass breaking |
| `SIREN_LAST_HEARD` | String | Timestamp of last siren |
| `CAR_HORN_LAST_HEARD` | String | Timestamp of last car horn |
| `MUSIC_LAST_HEARD` | String | Timestamp of last music detection |

---

## Programming Examples

### Turn on porch light when person detected

| Field | Value |
|-------|-------|
| **Event** | `Person Detected` on **Front Door** camera |
| **Action** | Turn On → **Porch Light** |

### Send push notification on loitering

| Field | Value |
|-------|-------|
| **Event** | `Loitering Detected` on **Street** camera |
| **Action** | Push Notification → "Vehicle loitering detected" |

### Arm alarm when no one is home

| Field | Value |
|-------|-------|
| **Conditional** | `PERSON_COUNT` = 0 on **all cameras** |
| **Action** | Security → Arm Away |

### Turn on driveway lights when car arrives at night

| Field | Value |
|-------|-------|
| **Event** | `Car Detected` on **Driveway** camera |
| **Conditional** | Time is between Sunset and Sunrise |
| **Action** | Turn On → **Driveway Lights** for 5 minutes |

### Alert on camera failure

| Field | Value |
|-------|-------|
| **Event** | `Camera Offline` on **any camera** |
| **Action** | Push Notification → "Camera offline: check NVR" |

---

## Stream Details

Navigators connect **directly** to the Frigate server for video — the Control4 controller does not proxy streams.

```mermaid
graph LR
    subgraph Frigate Server
        API[Frigate API :5000<br/><i>MJPEG + Snapshots</i>]
        RS[go2rtc :8554<br/><i>RTSP</i>]
    end

    T3[T3/T4 Touchscreen] -->|MJPEG| API
    APP[Control4 Mobile App] -->|RTSP| RS
    TV[On-Screen Navigator] -->|MJPEG| API
    ANY[All Navigators] -->|Thumbnail| API

    style RS fill:#3b82f6,color:#fff
    style API fill:#3b82f6,color:#fff
    style T3 fill:#8b5cf6,color:#fff
    style APP fill:#8b5cf6,color:#fff
    style TV fill:#8b5cf6,color:#fff
    style ANY fill:#8b5cf6,color:#fff
```

| Stream | Port | Source | Navigator | Notes |
|--------|:----:|--------|-----------|-------|
| **MJPEG** | 5000 | Frigate API | Touchscreens, on-screen, PC | Universal — works on every navigator type. Always available. |
| **RTSP** | 8554 | go2rtc | Mobile apps | H.264 sub-streams. Requires cameras routed through go2rtc. |
| **Snapshot** | 5000 | Frigate API | All | JPEG thumbnail from Frigate's latest detection frame |

> **Why sub-streams?** Control4 navigators display at 720p max and **cannot decode H.265**. The driver defaults to H.264 sub-streams, which avoids transcoding entirely. Only change this if your cameras don't have sub-streams configured in Frigate.

---

## NVR Driver Actions

These actions are available in the Frigate NVR driver's **Actions** tab in Composer Pro:

| Action | Description |
|--------|-------------|
| **Create / Relink Cameras** | Queries Frigate API, adopts orphan cameras from a previous NVR driver (preserving room assignments), then creates drivers for any remaining new cameras. Auto-detects sub-stream availability. Also runs automatically on driver startup. Safe to re-run — never creates duplicates. |
| **Synchronize Cameras with Frigate** | Updates all camera configurations (host, sub-stream) from Frigate, renames to match Frigate names. Use after adding cameras to Frigate or changing settings. |
| **Reconnect MQTT** | Disconnects and reconnects the MQTT client. Use if detection events stop. |
| **Check Frigate Status** | Tests Frigate API connectivity and displays the Frigate version. |
| **Remove All Cameras** | Clears the NVR driver's internal tracking. Camera drivers must still be removed manually in Composer. |

---

## MQTT Topics

The NVR driver automatically subscribes to these Frigate MQTT topics:

| Topic Pattern | What It Provides |
|---------------|------------------|
| `frigate/available` | Frigate server online/offline status |
| `frigate/<camera>/person` | Person count per camera (0 = no person) |
| `frigate/<camera>/car` | Car count per camera |
| `frigate/<camera>/dog` | Dog count per camera |
| `frigate/<camera>/cat` | Cat count per camera |
| `frigate/<camera>/motion` | Motion `ON` / `OFF` per camera |
| `frigate/<camera>/<zone>/<object>` | Object count per zone (for zone enter/exit) |
| `frigate/<camera>/audio/<type>` | Audio detection events (speech, bark, scream, etc.) |
| `frigate/<camera>/detect/state` | Detection enable/disable state changes |
| `frigate/<camera>/recordings/state` | Recording enable/disable state changes |
| `frigate/events` | Full event JSON (used for loitering detection) |

No MQTT configuration is needed on the Frigate side — these topics are published by default when MQTT is enabled in Frigate.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| **Frigate Status: "Not Configured"** | Frigate Host is blank | Enter the Frigate server IP in driver properties |
| **Frigate Status: "Offline"** | Can't reach Frigate API | Verify IP/port. Open `http://<ip>:5000` in a browser. Check firewall. |
| **Frigate Status: "API Error: HTTP 401"** | Frigate auth is enabled | Enter Frigate Username and Password |
| **MQTT Status: "Not Configured"** | MQTT Broker is blank | Enter the MQTT broker IP |
| **MQTT Status: "Disconnected"** | Broker unreachable or auth failed | Check broker IP/port. If broker requires auth, enter MQTT Username/Password. Try **Reconnect MQTT**. |
| **Discover finds 0 cameras** | Frigate config has no cameras | Verify `http://<ip>:5000/api/config` returns camera data in a browser |
| **No video on touchscreen** | MJPEG stream not reachable | Test in browser: `http://<frigate-ip>:5000/api/<camera_name>` |
| **No video on mobile app** | RTSP 404 (no active go2rtc source) | Frigate's ffmpeg must pull through go2rtc, not directly from cameras. See [Streaming Requirement](#frigate-streaming-requirement--cameras-must-route-through-go2rtc) above. |
| **Frigate Status: "Frigate unavailable (MQTT)"** | MQTT availability message missed | Wait up to 60 seconds — the driver auto-recovers via periodic health check. Or click **Check Frigate Status**. |
| **No detection events** | MQTT not connected or camera not tracked | Verify MQTT Status = "Connected". Check that the camera name appears in Managed Cameras. If **Unmatched Cameras** shows names, run **Synchronize Cameras with Frigate**. |
| **Events firing but programming doesn't trigger** | Camera driver not receiving events | Re-run **Synchronize Cameras with Frigate** to refresh the camera-to-device mapping |
| **RTSP Camera Test fails** | HEVC sub-streams or go2rtc not active | Expected for H.265 cameras. Video still works via MJPEG. For RTSP, configure sub-streams as H.264. |
| **Camera shows "Not Configured"** | Properties not set | Run **Synchronize Cameras with Frigate** from the NVR driver, or manually enter Frigate Host and Camera Name. |
| **Door station / single-stream camera not working** | Sub-stream doesn't exist | Run **Synchronize** — the driver auto-detects single-stream cameras. Or manually set **Use Sub Stream** to **No** on that camera. |

### Debugging

Both drivers support configurable logging via **Log Mode** and **Log Level** properties:

| Property | Setting | Effect |
|----------|---------|--------|
| **Log Mode** | `Print` | Output appears in the **Lua** tab in Composer |
| **Log Mode** | `Log` | Output goes to the controller's system log |
| **Log Mode** | `Print and Log` | Both |
| **Log Level** | `4 - Debug` | Shows MQTT messages, event firing, API calls, camera config |
| **Log Level** | `5 - Trace` | Shows every MQTT message payload including audio (verbose) |

Set Log Mode back to `Off` when done — logging adds overhead.

> **Tip:** When debugging event flow, set both the NVR and the specific camera driver to Debug + Print. The NVR Lua tab shows MQTT receipt and routing, the camera Lua tab shows event processing and firing.

---

## Building from Source

If you need to build the `.c4z` files from source:

```bash
git clone https://github.com/mattstein111/control4-frigate.git
cd control4-frigate
./build.sh all
```

Output in `dist/`:
- `frigate-camera.c4z` (~11 KB)
- `frigate-nvr.c4z` (~52 KB — includes the full Navigator icon ladder)

A `.c4z` is simply a ZIP file containing the driver XML, Lua, and documentation.

### Project Structure

```
control4-frigate/
├── README.md
├── CHANGELOG.md
├── LICENSE
├── build.sh                    # Packages .c4z driver files
├── .github/workflows/
│   ├── build.yml               # Build .c4z on every push / PR
│   └── release.yml             # Attach .c4z to tagged releases (auto-prerelease for -beta/-rc/-alpha)
├── camera-driver/
│   ├── driver.xml              # Camera proxy manifest (events, variables, capabilities)
│   ├── driver.lua              # Streams, detection event handling, history, variables
│   └── www/documentation.html  # Help page shown in Composer Pro
├── nvr-driver/
│   ├── driver.xml              # NVR controller manifest (actions, properties)
│   ├── driver.lua              # Discovery, MQTT client, event routing
│   └── www/
│       ├── documentation.html  # Help page shown in Composer Pro
│       └── icons/              # device_sm/lg + experience_* ladder + logo.svg
└── dist/                       # Built .c4z files (gitignored)
```

---

## Frequently Asked Questions

**Does this require Docker?**
No. The driver connects to Frigate's standard HTTP and MQTT interfaces. It works with Docker, bare-metal, VM, or any Frigate installation.

**Can I add cameras from multiple Frigate servers?**
Yes — add one Frigate NVR driver per server, each pointed at a different IP.

**What happens when a new camera is added to Frigate?**
Run **Create / Relink Cameras** again. It only adds new cameras and won't affect existing ones. Or run **Synchronize Cameras with Frigate** to update everything.

**Do I need to configure anything in Frigate?**
MQTT must be enabled (it is by default if you have a broker configured). For RTSP streaming to mobile apps, Frigate's camera inputs must route through go2rtc — this is the default in Docker installs. Native/bare-metal installs may need to change ffmpeg input paths from direct camera URLs to `rtsp://127.0.0.1:8554/<camera>`. See the [Streaming Requirement](#frigate-streaming-requirement--cameras-must-route-through-go2rtc) section. MJPEG on touchscreens works regardless.

**What if the homeowner doesn't have an MQTT broker?**
Streams will still work — you'll get live video on all navigators. But detection events, history, and variables require MQTT. Mosquitto is easy to set up and often runs on the same server as Frigate.

**Will this slow down the Frigate server?**
Negligible impact. MJPEG streams are on-demand (only active while someone is viewing). RTSP is packet passthrough. Snapshots are already generated by Frigate. The MQTT subscription is lightweight.

**Why does the NVR driver show as a combo driver?**
The NVR uses a combo driver proxy so it appears correctly in Composer's driver search without showing an unnecessary Camera Properties panel. All configuration is in the Advanced Properties section.

**My door station / single-stream camera doesn't show video.**
The driver defaults to using sub-streams (`<camera>_sub`). If a camera has no sub-stream in go2rtc, run **Synchronize Cameras with Frigate** — the driver auto-detects this and switches to the main stream. Or manually set **Use Sub Stream** to **No** on that camera.

**Can I update the driver without losing camera room assignments?**
Yes. Load the updated `.c4z` files, then delete the old NVR driver and add a new one. On startup, the new NVR driver automatically adopts orphan camera drivers from the previous instance, preserving their room assignments. You can also manually run **Create / Relink Cameras** to trigger adoption.

**How do I enable debug logging?**
On either driver, set **Log Mode** to `Print` and **Log Level** to `4 - Debug`. Then check the **Lua** tab in Composer Pro. For tracing event flow end-to-end, enable debug on both the NVR driver and the specific camera driver.

---

## Related Projects

- [Frigate NVR](https://frigate.video) — open-source NVR with AI object detection
- [go2rtc](https://github.com/AlexxIT/go2rtc) — camera restreaming server (bundled with Frigate)
- [DriverWorks SDK](https://control4.github.io/docs-driverworks-introduction/) — Control4 driver development documentation
- [Annex4 Generic Camera](https://github.com/annex4-inc/control4-generic-camera) — reference open-source Control4 camera driver

## License

MIT License — see [LICENSE](LICENSE).
