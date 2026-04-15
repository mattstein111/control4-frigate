# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
