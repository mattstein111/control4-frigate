# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.8.13-beta] - 2026-08-13

### Fixed

- **Camera driver: history entries were written with the wrong field layout (#24).** `C4:RecordHistory` takes **five** parameters — `(severity, type, category, subcategory, description)` — but the driver passed four: `C4:RecordHistory(severity, "Camera", message, "")`. Every field was therefore shifted one position left and the last dropped: the human-readable message landed in `category`, `subcategory` was an empty string, and `description` was `nil`. Camera events now record as `("Info", "Person Detected", "Security", "Camera", "Person detected")`, matching the field semantics documented in Control4's own drivers (`category` = domain, `subcategory` = device kind, `type` = specific event). Signature confirmed against `c4_utils.lua` as shipped inside Control4's `camera_ip_compatibility_test.c4z`, and corroborated by the stock `door_relay_control` pattern and the DS2 door station's History-agent parameter block. All 23 `recordHistory()` call sites now pass a meaningful event type. The call is additionally wrapped in `pcall` so a history failure can never abort its calling handler — the failure mode that made #27 so damaging.

  Note: this fix was only reachable after #27, which prevented `recordHistory()` from ever executing. Whether the History **agent** must be present in the Control4 project for records to persist is still unverified.

### Changed

- NVR driver bumped to v45, camera driver bumped to v40.

## [0.8.12-beta] - 2026-08-13

### Fixed

- **Camera driver: every variable update threw `LUA_ERROR`, so detection and motion events never fired (#27).** `initVariables()` stored the *return value* of `C4:AddVariable()` in the `VAR` table, but that return is a boolean — not a variable identifier. Every `setVar()` call therefore invoked `C4:SetVariable(true, …)` and raised `identifier should be a number/string`, which aborted the enclosing handler at its first variable write. The visible consequences: `Person Detected`, `Car Detected`, `Object Detected`, `Motion Detected`/`Motion Stopped`, loitering, camera online/offline and audio events never fired for Composer programming; no history entries were recorded; `Last Event` never updated; and all 27 driver variables kept their initial values permanently. Fixed by addressing variables **by name** (`C4:SetVariable` accepts a name) via a static `VAR` name table, with `C4:AddVariable` now used only to create them. `setVar()` additionally validates the name and wraps the call in `pcall`, so a future variable problem degrades to a log line instead of silently killing event dispatch. Present since v0.7.0-beta.

### Changed

- NVR driver bumped to v44, camera driver bumped to v39 so Director will hot-reload both via the self-install auto-updater.

## [0.8.11-beta] - 2026-04-15

### Fixed

- **Spurious `Audio: Rms` events flooding `Last Event` on every camera (#23).** The NVR driver's MQTT handler subscribed to `frigate/+/audio/+`, which matches Frigate 0.17's continuous audio telemetry topics (`rms`, `dBFS`) in addition to discrete detections. Because those telemetry values are effectively always > 0, the driver fired `FRIGATE_AUDIO { audio_type = "rms" }` on every publish, overwriting the camera's `Last Event` display and pushing real detections (speech, bark, etc.) off-screen. Fixed by (1) narrowing MQTT subscriptions to the explicit list of audio detection types — `speech`, `bark`, `scream`, `yell`, `fire_alarm`, `glass_breaking`, `siren`, `car_horn`, `music` — so telemetry topics never reach the driver at all, and (2) adding an in-driver whitelist (`AUDIO_DETECTION_TYPES`) as belt-and-suspenders against future Frigate telemetry additions. Significant controller-CPU reduction expected on systems with Frigate audio enabled (dozens of bogus messages per camera per second are no longer dispatched through the C4 proxy).

### Changed

- NVR driver bumped to v43, camera driver bumped to v38 so Director will hot-reload both via the self-install auto-updater.

## [0.8.10-beta] - 2026-04-15

### Changed

- No code changes — smoke-test release for the self-install auto-updater shipped in v0.8.9-beta. NVR driver bumped to v42, camera driver bumped to v37 so Director will actually hot-reload them when the installed driver pulls this release.

## [0.8.9-beta] - 2026-04-14

### Changed

- NVR driver bumped to v41, camera driver bumped to v36 (both drivers must be installed to get auto-update).

- **`Auto Update` is now self-installing.** When set to `Beta` or `Release`, the NVR driver downloads both `frigate-nvr.c4z` and `frigate-camera.c4z` from the matched GitHub release, writes them to `C4Z_ROOT`, and asks Director to hot-reload them — no Composer required. Set to `Off` to disable. The `Check for Updates Now` action while `Off` still only reports availability and never installs.
  - Camera driver is installed first, then NVR (NVR install reloads its own Lua VM).
  - Anti-loop guard: if a self-install was attempted in the last 5 min and the driver booted on the same version (i.e. the install didn't take), the initial poll is skipped — use `Check for Updates Now` to retry manually.
  - Releases must ship both `frigate-nvr.c4z` and `frigate-camera.c4z` as assets; if either is missing, install is skipped and a warning is logged.
  - Mechanism: shared-secret `FileSetDir` handshake (c4-conventions §3a) plus `UpdateProjectC4i` SOAP envelope to `127.0.0.1:5020` (§3). Validated end-to-end in control4-mqttmirror v0.9.1.8 → v0.9.1.9.

## [0.8.8-beta] - 2026-04-15

### Added

- **Auto-update notifications** (#3) — NVR driver now polls GitHub Releases once daily and surfaces available updates via read-only properties and a log line. **Notification-only by design** — self-install is blocked on unsigned community drivers in OS 3.4+ (see shared `c4-conventions.md` §3a), so updates must still be installed manually via Composer.
  - New `Auto Update` dropdown — `Off` (default), `Beta` (prereleases + releases), `Release` (stable releases only).
  - New read-only properties: `Driver Release` (current tag), `Latest Available Version`, `Update Download URL`.
  - New action `Check for Updates Now` — manual trigger works regardless of the dropdown value; when `Off`, probes the `Release` channel.
  - When a newer release is detected, logs `Update available: <tag>. Download: <url>` at INFO level.

### Changed

- NVR driver bumped to v40.

## [0.8.7-beta] - 2026-04-14

### Fixed

- Driver icon read "wide" in Composer's driver list (#18) — device icons resized to the canonical Control4 slot sizes (`device_lg.png` 32×32, `device_sm.png` 16×16). Oversized source PNGs were being downscaled by the host with visible aspect distortion.

### Added

- Full `experience_*.png` icon ladder (sizes 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120, 130, 140, 300, 512, 1024) so Navigator / end-user surfaces pick density-matched icons instead of scaling from the two device PNGs.
- Padded wrapper SVG (`icon_padded.svg`) in the repo so future icon regenerations stay vector-crisp and consistently padded.

### Changed

- NVR driver bumped to v39.
- CI: `release.yml` auto-marks `-beta`/`-rc`/`-alpha` tags as GitHub prereleases so they don't ship to the future `Release` autoupdate channel (#3).

## [0.8.5-beta] - 2026-04-06

### Fixed

- Events now fire on the camera proxy (binding 5001) — all 29 events visible in Composer Programming tab
- `LOITERING_DETECTED` variable now resets to false when the zone clears

### Changed

- Motion events renamed: "Motion Started" → "Motion Detected", "Motion Stopped" → "Motion Not Detected"
- `MOTION_ACTIVE` variable renamed to `MOTION_DETECTED` for consistency
- MQTT subscriptions narrowed from broad `frigate/+/+/+` wildcard to specific per-object-type topics, reducing message volume on busy installs (#10)
- Replaced 10 audio boolean variables (never auto-reset) with `_LAST_HEARD` timestamp variables per audio type
- Replaced `LAST_OBJECT_TYPE`, `LAST_ZONE`, `LAST_DETECTION_TIME`, `LAST_AUDIO_TYPE` with per-type `_LAST_SEEN` / `_LAST_HEARD` timestamps
- Removed `CAMERA_NAME` variable (redundant with driver property)
- Variables: 27 total (11 boolean, 2 numeric, 6 last-seen, 10 last-heard) — down from 25 but more useful

### Added

- `_LAST_SEEN` timestamp variables: `PERSON_LAST_SEEN`, `CAR_LAST_SEEN`, `DOG_LAST_SEEN`, `CAT_LAST_SEEN`, `MOTION_LAST_SEEN`, `LOITERING_LAST_SEEN`
- `_LAST_HEARD` timestamp variables: `AUDIO_LAST_HEARD`, `SPEECH_LAST_HEARD`, `BARK_LAST_HEARD`, `SCREAM_LAST_HEARD`, `YELL_LAST_HEARD`, `FIRE_ALARM_LAST_HEARD`, `GLASS_BREAKING_LAST_HEARD`, `SIREN_LAST_HEARD`, `CAR_HORN_LAST_HEARD`, `MUSIC_LAST_HEARD`
- Debug logging on `GetNotificationAttachmentURL()` for push notification troubleshooting (#4, #12)
- GitHub Actions CI: build on push/PR, auto-attach `.c4z` artifacts to releases

## [0.8.0-beta] - 2026-04-02

### Added

- NVR driver uses combo driver proxy — no more Camera Properties panel in Composer Pro (#9)
- Custom Frigate logo icon on NVR driver in Composer (#8)
- "Create / Relink Cameras" action — adopts orphan cameras from a previous NVR driver and creates new ones in a single step (#11)
- Auto-adopt runs on driver startup — cameras survive NVR driver replacement with room assignments intact
- Snapshot attachment support for push notifications via Notification Agent (#4)
- MQTT broker auto-populated from Frigate config when Frigate Host is set
- 14 new programmable events (29 total):
  - Audio detection: Speech, Bark, Scream, Yell, Fire Alarm, Glass Breaking, Siren, Car Horn, Music, plus generic Audio Detected
  - State changes: Detection Enabled/Disabled, Recording Enabled/Disabled
- Camera protocol driver unhidden — all 29 events now visible in Composer Programming

### Changed

- "C4" renamed to "Control4" in all human-readable text (properties, documentation, README)
- "Cameras in C4" property renamed to "Cameras in Control4"

### Fixed

- GetDevicesByC4iName returns device IDs as table keys, not values
- Icon loading requires `image_source="c4z"` attribute and paths relative to www/

## [0.7.0-beta] - 2026-04-01

### Added

- Two-driver architecture: NVR parent driver handles discovery, MQTT, and event routing; Camera child driver provides streams, events, history, and variables
- Auto-discovery of Frigate cameras via the Frigate REST API — one click in Composer Pro creates all camera drivers
- Real-time AI detection events via MQTT subscription (person, car, dog, cat, motion)
- 15 programmable events in Composer Pro: person/car/dog/cat detected/left, object detected/left, motion started/stopped, zone entered/exited, loitering detected, camera online/offline
- 11 Composer variables for conditional programming: PERSON_DETECTED, CAR_DETECTED, DOG_DETECTED, CAT_DETECTED, MOTION_ACTIVE, CAMERA_ONLINE, PERSON_COUNT, CAR_COUNT, LAST_OBJECT_TYPE, LAST_ZONE, LAST_DETECTION_TIME
- Full event history in the Control4 app with timestamped entries
- Sub-stream auto-detection via go2rtc — automatically uses main stream for cameras without sub-streams
- MJPEG streaming for touchscreens (via Frigate API port 5000)
- RTSP H.264 streaming for mobile apps (via go2rtc port 8554)
- Snapshot thumbnails from Frigate's latest detection frame
- Zone enter/exit and loitering detection events
- Synchronize action to update all cameras from Frigate and rename to match Frigate names
- In-Composer documentation pages (HTML help accessible from each driver's Properties)
- Configurable debug logging (Off / Print, levels 1-5)
- MQTT auto-reconnect on 30-second timer
- Support for Frigate and MQTT authentication (optional)

[0.8.5-beta]: https://github.com/mattstein111/control4-frigate/releases/tag/v0.8.5-beta
[0.8.0-beta]: https://github.com/mattstein111/control4-frigate/releases/tag/v0.8.0-beta
[0.7.0-beta]: https://github.com/mattstein111/control4-frigate/releases/tag/v0.7.0-beta
