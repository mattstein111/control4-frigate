# Frigate event snapshots in Control4 push notifications

**Date:** 2026-08-14
**Issue:** [#25](https://github.com/mattstein111/control4-frigate/issues/25)
**Status:** Design approved, pending implementation plan

## Problem

When a Control4 push notification fires for a camera detection, the attached image is
`/api/<camera>/latest.jpg` — the camera's view *at the moment the notification renders*, not the
event that triggered it. By then the person has usually walked out of frame, so the notification
shows an empty driveway.

Frigate stores an image for every event. The driver should attach that instead.

## Scope

In scope: replacing the notification attachment image with the triggering event's snapshot.

Out of scope, deferred from #25: clip links and tap-through playback, inline thumbnails in the app
history list, structured metadata (zone/confidence/duration) in history entries, and driver-side
image caching. Each is independently valuable; none is required for notification images.

## Background

Two facts make this smaller than #25 assumed.

**The NVR already subscribes to `frigate/events` and already parses it.** `handleEventJSON()` in
`nvr-driver/driver.lua` extracts `camera`, `label`, `loitering` and `current_zones` for loitering
detection. It has simply never read the event `id`. No new subscription, parser, or dependency is
needed.

**The notification attachment path is already wired.** `camera-driver/driver.xml` declares
`<notification_attachment_provider>True</notification_attachment_provider>` with an `IMAGE_JPEG`
attachment, and `GetNotificationAttachmentURL()` already exists in the camera driver. Control4
*pulls*: it calls that function when a notification fires and uses the URL returned.

The consequence of the pull model is the central design constraint: **at notification time the
driver must already know which event was responsible.** It cannot go and find out, because the
function must return synchronously.

## Rejected alternative

Have the camera driver query `/api/events?camera=<cam>&limit=1` inside
`GetNotificationAttachmentURL()`, avoiding any NVR change. Rejected: `C4:urlGet` is asynchronous and
the function must return a URL synchronously. There is no way to block for the response, and
returning a URL built from a not-yet-received reply is not possible. Forwarding the ID over the
existing NVR→camera path is both simpler and correct.

## Design

### 1. NVR: extract and forward the event ID

`handleEventJSON()` additionally extracts `id` and `has_snapshot`, and sends a new command:

```lua
sendToCamera(camera, "FRIGATE_EVENT", {
    event_id     = eventId,
    has_snapshot = hasSnapshot,
    label        = label or "object",
})
```

**Field extraction detail.** `frigate/events` payloads wrap the event in `before` and `after`
objects. The existing `jsonString()` helper returns the first match in the string, which falls
inside `before`.

- `id` is identical in both, so the first match is correct.
- `has_snapshot` is **not** — it flips `false` → `true` as the event matures and Frigate writes the
  snapshot. It must be read from the `after` object specifically, or the driver will believe no
  snapshot exists for events that have one.

This asymmetry is the single most likely source of a subtle bug in this change and must be covered
by a test.

### 2. Camera: remember the last event

Module-level state in `camera-driver/driver.lua`:

```lua
local lastEvent = { id = nil, timestamp = 0, hasSnapshot = false }
```

Updated on each `FRIGATE_EVENT` command. `timestamp` is `os.time()` at receipt, not a Frigate
timestamp — the comparison is against local controller time, and mixing clock sources would make the
freshness window unreliable if Frigate's clock drifts.

No persistence. A driver reload loses the cached event, and the next notification falls back to the
live snapshot until the next detection. That is acceptable and not worth `PersistSetValue` traffic.

### 3. Camera: build the URL at notification time

```lua
function GetNotificationAttachmentURL(idBinding, tParams)
    local host = Properties[PROP_HOST] or ""
    local cam  = cameraName()
    if host == "" or not cam then return "" end

    -- "Off" (or any unparseable value) yields nil; treat Off as 0, absent as the 60s default.
    local raw    = Properties[PROP_NOTIFY_FRESHNESS]
    local window = (raw == "Off") and 0 or (tonumber(raw) or 60)
    if window > 0 and lastEvent.id and lastEvent.hasSnapshot
       and (os.time() - lastEvent.timestamp) <= window then
        return "http://" .. host .. ":" .. PORT_HTTP
            .. "/api/events/" .. lastEvent.id .. "/snapshot.jpg?bbox=1&h=480"
    end

    return "http://" .. host .. ":" .. PORT_HTTP .. "/api/" .. cam .. "/latest.jpg"
end
```

`bbox=1` draws Frigate's bounding box around the detected object. `h=480` caps the height so the
image stays small enough for a responsive push notification.

### 4. New property: `Notification Image Freshness (seconds)`

| | |
|---|---|
| Name | `Notification Image Freshness (seconds)` |
| Type | `LIST` |
| Items | `Off`, `30`, `60`, `120`, `300` |
| Default | `60` |

`LIST` rather than `NUMBER`: every property in both drivers is `LIST` or `STRING`, and a fixed set
of sensible values avoids free-text validation. Per the shared conventions, Composer does not enforce
type constraints beyond the widget, so the value is still parsed defensively with
`tonumber(...) or 60` at the point of use rather than trusted.

`Off` disables event snapshots entirely and always returns `latest.jpg`. This matters because the
driver has external users and the change alters what their notifications look like — `Off` restores
exactly the current behaviour without needing a downgrade.

### 5. Error handling

Every failure path degrades to `latest.jpg`, never to no image:

| Condition | Result |
|---|---|
| No event received yet | `latest.jpg` |
| Event older than the freshness window | `latest.jpg` |
| `has_snapshot: false` | `latest.jpg` |
| Freshness set to `Off` | `latest.jpg` |
| Host or camera name unset | `""` (unchanged from today) |

Frigate purging a snapshot on its retention schedule needs no special handling: purged events are
long past any sane freshness window, so the stale check catches them first. This resolves open
question 3 in #25 — no driver-side caching is needed.

`GetNotificationAttachmentURL()` performs no I/O, cannot raise, and returns synchronously, so it
cannot break notification delivery.

### 6. Remote access

The URL points at the Frigate host on the LAN. Whether a phone on cellular can load it depends on
whether Control4 fetches the image controller-side and relays it, or hands the URL to the client.
This is unverified.

It does not block implementation — the failure mode is identical to today's `latest.jpg`, which has
the same LAN-only URL. If remote notifications currently show images, this will too. If they do not,
that is a pre-existing limitation, unchanged by this work, and worth its own issue. This resolves
open question 2 in #25 as "no change to current behaviour, verify separately."

## Testing

The regression harness used to verify #24 and #27 currently lives only in a scratch directory and
will be lost. Implementation should commit it to the repo as `test/driver_test.lua` — a standalone
Lua script that mocks the `C4` API, drives `ExecuteCommand`, and asserts on captured calls — then
extend it with the cases below. It runs under stock `lua` with no framework, and the existing
`build.yml` workflow can invoke it so regressions are caught in CI.

Committing it also protects the three bugs already fixed this cycle from regressing: variables set by
name, history recorded under the registered category, and the four-argument `C4:RecordHistory` form.

**URL selection:**

| Case | Expected |
|---|---|
| Fresh event with `has_snapshot: true` | Event snapshot URL, with `bbox=1` |
| Event older than the window | `latest.jpg` |
| Event with `has_snapshot: false` | `latest.jpg` |
| No event received | `latest.jpg` |
| Freshness set to `Off` | `latest.jpg`, even with a fresh event |
| Freshness boundary (exactly at the window) | Event snapshot — the comparison is `<=` |

**Payload parsing**, against a realistic `frigate/events` payload containing both `before` and
`after`:

| Case | Expected |
|---|---|
| `id` extracted | Matches the event ID |
| `has_snapshot` read from `after`, not `before` | `true` when `before.has_snapshot` is `false` and `after.has_snapshot` is `true` |
| Malformed or empty payload | No `FRIGATE_EVENT` sent, no error raised |

**Regression:** existing loitering detection continues to work from the same payload.

## Files affected

| File | Change |
|---|---|
| `nvr-driver/driver.lua` | Extract `id` / `has_snapshot` in `handleEventJSON()`; send `FRIGATE_EVENT` |
| `camera-driver/driver.lua` | `lastEvent` cache; `FRIGATE_EVENT` handler; rewrite `GetNotificationAttachmentURL()` |
| `camera-driver/driver.xml` | Add `Notification Image Freshness` property; bump `<version>` |
| `nvr-driver/driver.xml` | Bump `<version>` |
| `test/driver_test.lua` | New — commit the existing harness, extend with the cases above |
| `.github/workflows/build.yml` | Run the harness in CI |
| `CHANGELOG.md` | New release entry |
| `README.md` | Document the new property and the notification image behaviour |

## Success criteria

A person walks into frame; the resulting Control4 push notification shows the full camera frame from
the moment of detection with a bounding box around the person — not a later empty view of the same
scene. Motion-only notifications continue to show an image. Setting the freshness property to `Off`
reproduces current behaviour exactly.
