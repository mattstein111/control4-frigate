# RESUME: config-driven detection labels

**Paused:** 2026-08-15, by choice, for roughly a week.
**Branch:** `feature/28-29-config-driven-labels` — pushed, CI green, **not merged**.
**PR:** [#31](https://github.com/mattstein111/control4-frigate/pull/31)
**Issues:** [#28](https://github.com/mattstein111/control4-frigate/issues/28), [#29](https://github.com/mattstein111/control4-frigate/issues/29) (fixed, open until released) · [#30](https://github.com/mattstein111/control4-frigate/issues/30) (blocks release)

To resume, say "pick up the config-driven labels work". Read this file first; it is the single source of state.

---

## Where things stand

The work is **complete, reviewed and CI-green**, but deliberately unreleased and unmerged.

| | |
|---|---|
| Released? | **No.** No tag, no GitHub release. Camera driver v44, NVR v49, `DRIVER_RELEASE` `v0.9.0-rc.1` — all unchanged. |
| On `main`? | **No.** `main` is untouched. The branch exists only as PR #31. |
| Can users get it? | **No.** The auto-updater installs GitHub *releases*; there is no release. |
| Tests | 55 assertions (`nvr_test.lua`) + 79 (`driver_test.lua`), green locally and on CI. |

### Verify the state in one command

```sh
git fetch && git checkout feature/28-29-config-driven-labels
luajit test/nvr_test.lua nvr-driver/driver.lua      # expect ALL PASS
luajit test/driver_test.lua camera-driver/driver.lua # expect ALL PASS
./build.sh all                                       # expect both .c4z
grep -o "<version>[0-9]*</version>" camera-driver/driver.xml nvr-driver/driver.xml
grep -n 'DRIVER_RELEASE  =' nvr-driver/driver.lua    # expect v0.9.0-rc.1
```

**Use `luajit`, never the system `lua`.** DriverWorks runs LuaJIT (Lua 5.1 semantics); the local `lua` is 5.5 and will not even load `nvr-driver/driver.lua`.

---

## What this branch did

The driver hardcoded which Frigate detection labels it subscribed to over MQTT, in two independent places per detection kind, while Frigate's real labels come from its own per-camera config. They drifted silently: on the reference system `package`, `glass`, `shatter` and `car_alarm` detections were discarded entirely, while the driver subscribed to four labels Frigate has never emitted.

Now both the subscription set and the handler whitelist are generated from one config-resolved label set, a canonical mapping table feeds the event / history type / registration alike, unmapped labels reach a generic path instead of being dropped, and registration is per-camera. `package` and `car_alarm` became first-class; `Audio: Siren` / `Car Horn` / `Music` were removed as a breaking change.

Full detail is in PR #31 and in `docs/superpowers/specs/2026-08-14-config-driven-detection-labels-design.md`.

---

## Do this first when you return

### 1. #30 — the only thing blocking release

Per-camera history registration is lost when a camera driver restarts on its own, because the NVR only sends a camera its labels during adoption or a manual **Discover Cameras**. Its own `OnDriverLateInit` never resends to already-managed cameras.

**Severity is now reduced.** An empty label list registers the *full canonical set*, so `person`, `car`, `dog`, `cat`, `package` and every canonical `Audio: *` recover after a restart. Only **non-canonical** labels are still affected — `bicycle`, `truck`, or Frigate+ `amazon` / `ups` / `fedex`.

**The fix, roughly 30 lines:** in `camera-driver/driver.lua`, persist the label list with `C4:PersistSetValue` when `SET_FRIGATE_CONFIG` arrives, and restore it in `OnDriverLateInit` before calling `registerNotificationEvents`. That recovers the exact per-camera set rather than the canonical superset, and removes the reliance on registering more types than a camera can emit.

Needs a regression test: a camera restarting with no fresh `SET_FRIGATE_CONFIG` still ends up with its full registration.

### 2. Hardware test

Nothing on this branch has run on the live Control4 system. Worth confirming before any release:

- A `package` detection at `front_door` fires `Package Detected`, sets `PACKAGE_DETECTED`, and **appears in the app's history**
- The startup log line reports the resolved sets, e.g. `Subscribed to objects: car, package, person | audio: bark, car_alarm, …`
- Adding a label in Frigate, restarting Frigate, and running **Discover Cameras** makes that label's events flow without a driver release

### 3. Then decide on merge and release

Merging is safe whenever — no release results from it. Release only after #30 and the hardware test.

---

## Deferred minor findings

None block merge. Recorded here because the SDD ledger that held them was deleted with its workspace.

| Finding | Where | Why deferred |
|---|---|---|
| `friendlyObject` is still a second source for history types, used in five hardcoded `handleDetection` branches (`camera-driver/driver.lua:164`, used ~`:372`) | camera driver | Harmless **only** because those five labels are single-word. Add a multi-word first-class label such as `license_plate` and the title-case bug from #28 returns. Worth folding into the next change that touches those branches. |
| No test exercises `sendCameraConfig`'s third `useSub` parameter | `test/nvr_test.lua` | Dropping the per-camera override still passes the suite (proven by mutation). Correctness verified by code reading. Pre-existing coverage gap. |
| Object labels bypass the audio telemetry filter in `buildSubscriptionTopics` | nvr driver | An object label literally named `rms` would produce a matching zone topic. The handler drops it, so #23 does **not** regress. Noted for symmetry only. |
| Three `*ForTest` accessors ship in the production `.c4z` — `getFallbackLabels`, `sendCameraConfigForTest`, `handleMQTTForTest` | both drivers | Legitimate test seams for `local` functions, inert in the C4 sandbox. Flagged so the call stays deliberate. |

---

## Gotchas that cost real time on this codebase

- **Tests run under `luajit`.** The system `lua` is 5.5 and cannot load the NVR driver at all.
- **Count variables with `grep -cE '^\s*C4:AddVariable\('` → 27.** A bare `grep -c "C4:AddVariable"` returns 29 because two comment lines mention the API name. That miscount already propagated into a badge and a spec once.
- **`C4:SendToDevice` serialises every param as a string.** Tables do not survive; `"false"` is truthy in Lua.
- **`C4:RecordHistory` takes four arguments.** The documented fifth metadata table stops the record being stored on OS 3.4.3.
- **Recorded history must match a `C4:RegisterEvents` registration exactly**, category `Cameras`, subcategory `Frigate`, or Navigator silently will not display it.
- **Never subscribe to `frigate/+/audio/rms` or `dBFS`** — ~1 message/second/camera.
- **"The tests pass" was not sufficient evidence here.** Reviewers repeatedly found tests that passed while the code was wrong, and the most serious defect on this branch — resolved labels never reaching the MQTT subscription list, which would have made the whole feature inert for any label outside the fallback — survived seven clean per-task reviews and only fell to the whole-branch pass. Mutation-test anything load-bearing.
