# Control4 Frigate Driver

## Overview

Custom Control4 `.c4z` drivers for Frigate NVR. Two-driver architecture: NVR parent (discovery, MQTT, event routing) + Camera child (streams, events, history, variables).

## Key Files

- `camera-driver/driver.xml` — Camera proxy manifest: events, variables, capabilities, connections
- `camera-driver/driver.lua` — Stream URL handlers, detection event processing, history logging, Composer variables
- `nvr-driver/driver.xml` — NVR manifest: actions, commands, MQTT properties
- `nvr-driver/driver.lua` — Frigate API client, MQTT subscriber, camera discovery, event routing
- `build.sh` — Packages drivers as `.c4z` (zip) files into `dist/`

## Architecture

- **Camera proxy** binding ID 5001, uses dynamic stream URLs (`requires_dynamic_stream_urls`)
- **MQTT** via `C4:CreateMQTTClient()` — subscribes to `frigate/+/person`, `frigate/+/motion`, `frigate/+/+/+`, `frigate/events`
- **Inter-driver comms** via `C4:SendToDevice()` — NVR sends `FRIGATE_DETECTION`, `FRIGATE_MOTION`, `FRIGATE_ZONE`, `FRIGATE_LOITERING`, `FRIGATE_HEALTH` to camera drivers
- **Persistence** via `C4:PersistSetValue()` — managed cameras table survives reboots
- **Discovery** via `C4:AddDevice()` + `C4:GetDevicesByC4iName()` for reconciliation

## Critical Notes

- Control4 navigators only decode H.264 (not H.265) — always use sub-streams
- DriverWorks Lua has no JSON library — JSON parsing uses pattern matching
- `C4:RenameDevice()` works with proxy ID (not protocol ID) and refreshes the Composer project
- `C4:AddDevice()` requires OS 3.2.0+ and the target `.c4z` must be pre-loaded on the controller
- MQTT reconnects on 30-second timer via `C4:AddTimer()` / `OnTimerExpired()`
- `.c4z` files are unencrypted ZIPs — encryption only needed for commercial distribution

## Streams

| Stream | Port | Source |
|--------|:----:|--------|
| MJPEG | 1984 | go2rtc `api/stream.mjpeg?src=<cam>_sub` |
| RTSP H.264 | 8554 | go2rtc `<cam>_sub` |
| Snapshot | 5000 | Frigate `api/<cam>/latest.jpg` |

## Related

- Reference driver: [Annex4 generic camera](https://github.com/annex4-inc/control4-generic-camera)
- DriverWorks API: https://control4.github.io/docs-driverworks-api/
