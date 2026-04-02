# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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

[0.8.0-beta]: https://github.com/mattstein111/control4-frigate/releases/tag/v0.8.0-beta
[0.7.0-beta]: https://github.com/mattstein111/control4-frigate/releases/tag/v0.7.0-beta
