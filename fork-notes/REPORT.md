# Omi CV1 investigation report (fork: ramseykilani/omi)

Written 2026-10-12, without access to the device. Nothing here has been run on hardware.
**[GUESS]** marks hypotheses. **[CODE]** marks facts read directly from source. **[ISSUE]** marks
facts reported by other users upstream.

Branches:

| Branch | Contents |
|---|---|
| `ccr-5f9fd4e0-y9emw6` | Android app fixes, these notes, CI that builds the APK |
| `ccr-5f9fd4e0-y9emw6-firmware` | Draft firmware patches (build-only CI; **not for flashing yet**) |

Companion docs: [`TEST_PLAN.md`](TEST_PLAN.md) and [`QUESTIONS.md`](QUESTIONS.md).

---

## 1. Has someone already fixed this?

### Fork sync
When the session started, `ramseykilani/omi` `main` was identical to `BasedHardware/omi` `main` at `01ca9cee`
(0 ahead, 0 behind). All work here is based on that commit.

### Other forks
I checked the most-starred and most recently active forks, and every one in the 2-year "active"
list with at least 1 star. I compared each against upstream `main` and looked for commits touching
`app/lib/services/devices`, `app/android`, `device_provider.dart`, the firmware-update pages, or
`omi/firmware`.

| Fork | Own commits | Touches device/BLE/battery/OTA? | Verdict |
|---|---|---|---|
| **Glucksberg/omi-local** (the one you'd heard of) | 37 (last May 2026) | **No.** Local transcription (Parakeet), local chat sessions, a "heartbeat", auth-redirect hardening | Not relevant to these symptoms. It is also ~5 months behind upstream. |
| togodynamicslab/omi | ~1.4k | Only package renames ("Omi → Nooto") | Rebrand. Nothing to take. |
| Johnsonbros/zeke-omi | 162 | Package renames ("ZEKE AI") | Rebrand. |
| Wizard815/omi-local | 73 | Flavor rename, local LLM host | Not relevant. |
| skywinder/omi-in-the-sky, gentbot/lomi, smian1/omi | 1–41 | No | Not relevant. |
| katipally, adrbn, simpleedev, CrazyAI9, ajin558, CorInfinitum, Aiowuka, Iansabia | 0 | — | Plain mirrors. |

**Conclusion:** no fork is meaningfully ahead of upstream on BLE, battery, power, Android
background behaviour, or OTA. Upstream `main` is where the fixes land. I cherry-picked one
**open upstream PR** instead (see §3).

### Official firmware: 3.0.20 → latest (3.0.21)
The latest CV1 firmware release is **`Omi_CV1_v3.0.21`** (tag `f12031d1`, ~2026-08-05). There is no CV1
release after it; `main` still says 3.0.21. Firmware changes between your 3.0.20 and 3.0.21:

- SD-card auto-save every 2 s while syncing, plus an async ring-advance (`storage.c`, `sd_card.c`).
- `mic_start()` now **fails** when the T5838 mic-rail init fails (`67d76753aa`). In 3.0.20 it only logged.
- `omi.conf` deduplication. Nothing related to battery, power, BLE, or DFU.

Everything battery/BLE related from the July 2026 batch (battery reported during sync, TX
buffers reserved for battery notifications, ~1 mA system-off leak fix, AAD-sleep connection-parameter
revert) is **already in 3.0.20**.

**Will updating to 3.0.21 fix your symptoms?** Probably not. Nothing in it targets charging,
battery reading, shutdown, BLE drops, or OTA. One caution **[GUESS]**: because of the mic-init change,
a unit with a marginal mic rail would go from "silent mic" on 3.0.20 to a **reboot loop** on 3.0.21
(see §4.3). There are also unconfirmed post-3.0.21 reports: [#18537](https://github.com/BasedHardware/omi/issues/18537)
"stopped charging right after the update" and [#20484](https://github.com/BasedHardware/omi/issues/20484)
"capture fails after 3.0.21" (iOS). Updating is still a sensible step in the test plan,
because it puts you on the same baseline as support and as my patches. Do it with the device charged.

### Upstream issues per symptom
| Symptom | Issues | Status |
|---|---|---|
| Charging | [#5469](https://github.com/BasedHardware/omi/issues/5469) charging reliability (open, needs-info); [#18537](https://github.com/BasedHardware/omi/issues/18537) not charging, LED solid blue on dock, after 3.0.21 (closed; triage said "possible hardware fault"); [#6148](https://github.com/BasedHardware/omi/issues/6148) low-power while charging (open); Featurebase "[Omi won't charge but shows charging LEDs](https://omi.featurebase.app/p/omi-wont-charge-but-shows-charging-leds)" — *"powers on, shuts off ~14 s later… flashes green/blue… battery stays at 1%"* | No fix upstream |
| Battery % | [#4599](https://github.com/BasedHardware/omi/issues/4599) indicator inaccurate (open, "firmware-level"); [#4077](https://github.com/BasedHardware/omi/issues/4077); [#20624](https://github.com/BasedHardware/omi/issues/20624) runtime ~10 h (open) | No fix |
| Turns off | [#20625](https://github.com/BasedHardware/omi/issues/20625) repeated buzzing + early shutdown after update (open); [#7358](https://github.com/BasedHardware/omi/issues/7358) "off" but still recording (open) | No fix |
| Connection | [#20777](https://github.com/BasedHardware/omi/issues/20777) saved pendant out of range at launch never reconnects (**fix PR [#21302](https://github.com/BasedHardware/omi/pull/21302) open**, cherry-picked here); [#7353](https://github.com/BasedHardware/omi/issues/7353) post-update stale pairing (closed) | Partially fixed |
| OTA | [#18940](https://github.com/BasedHardware/omi/issues/18940), [#19453](https://github.com/BasedHardware/omi/issues/19453) "update bricked CV1 at first setup" (open); [#5902](https://github.com/BasedHardware/omi/issues/5902) 3.0.18 update loop; [#11308](https://github.com/BasedHardware/omi/issues/11308) DFU leaves a stale bond (iOS, closed); [#20778](https://github.com/BasedHardware/omi/issues/20778) no reconnect after update (iOS, open) | Open |

---

## 2. Ranked suspected causes, per symptom

Rank 1 is most likely. File references are to `main` (`01ca9cee`).

### Symptom 1 — "Charging is inconsistent, I can't tell if it's charging"
1. **The charging LED is firmware-driven, so it is dark whenever the firmware is off.** [CODE]
   `set_led_state()` (`omi/firmware/omi/src/main.c:132-175`) is the only thing that lights the LED. After a long
   press or the low-battery cut-off, `turnoff_all()` (`omi/firmware/omi/src/lib/core/button.c:347-429`) enters System OFF
   with **only the button** armed as a wake source (`button.c:411`). The BQ25101 charger IC keeps
   charging in hardware, but nothing shows it. You can't tell from the outside whether it's charging.
2. **When charging finishes, the device reports "not charging" while still on the dock.** [CODE] + [GUESS about the IC]
   `battery_charging_state_read()` (`battery.c:332`) equates "charging" with the BQ25101 `CHG` pin being low. Per
   the BQ2510x datasheet, `CHG` goes high-impedance at charge termination. So at full, the firmware sets
   `is_charging=false`, the LED drops back to solid blue/red (`main.c:167-170`, same as unplugged), and the app
   shows "not charging". The "solid green when full" branch (`main.c:155-160`) only shows during the short
   window when CHG is still low and the % has already reached ≥98.
3. **The firmware powers itself off on low voltage even while charging.** [CODE] `broadcast_battery_level()`
   (`transport.c:577-579`) calls `turnoff_all()` whenever a reading is below 3500 mV, regardless of `is_charging`.
   A flat battery put on the dock boots (LED blinks "charging"), takes its second reading at ~13 s, and
   powers off. That matches the Featurebase report above almost exactly. The device then charges dark (cause 1).
4. **Physical contact.** [GUESS] Magnetic pogo pins; upstream's own troubleshooting says contact resistance should be <0.5 Ω and
   to check magnet alignment and the dock's 5 V input (`docs/doc/hardware/consumer/electronics.mdx:157`). A dirty
   or worn contact makes CHG bounce. The diagnostics firmware draft counts CHG edges so this can be seen.

### Symptom 2 — "Battery % in the app is unreliable"
1. **Voltage-only estimate on a 150 mAh cell, single burst, two different curves.** [CODE] `battery.c`:
   one burst of 50 back-to-back SAADC samples (~ms) per reading (`battery.c:160-212`). The % is looked up in
   one of two tables depending on `is_charging` (`battery.c:51-79`), with a hand-tuned 16 mV "charging skew"
   (`battery.c:230`). Any load spike (radio, SD write, haptic) or a CHG flip (cause 2 above) moves the number.
2. **Monotonic clamp + slow EMA.** [CODE] `battery.c:283-289`: while discharging, the % may never rise; while charging, it may never fall.
   One low (sagging) reading pins the displayed level low until the charger is attached. Near the
   ends, the EMA moves 1 % per reading (`battery.c:109-119`).
3. **The bottom of the scale is compressed.** [CODE] 3600 mV = 1 % (`battery.c:62`), but the cut-off is 3500 mV (`transport.c:517`), so
   the last stretch of usable charge reads as 0–1 %. With EMA lag, you see e.g. "8 %" and then it dies.
4. **App-side display issues (fixed in this fork).** [CODE] A real 0 % reading was hidden (`batteryLevel > 0`), and nothing showed how old
   the reading was. After a disconnect, the last value stayed on screen as if it were live.
5. **ADC source impedance.** [GUESS] The divider is R1=1091/R2=499 (`battery.c:146`, units not stated). If those are kΩ,
   a 10 µs acquisition time (`battery.c:23`) is too short for that source impedance (Nordic recommends 40 µs above ~100 kΩ),
   which biases readings low and makes them load/temperature dependent. Needs the schematic or a multimeter to confirm.

### Symptom 3 — "The device often just turns off, even after charging"
1. **Single-reading low-voltage cut-off.** [CODE] `transport.c:577-579`: one reading < 3500 mV powers the device off. That reading is a
   few-ms burst, so a current spike on an aged 150 mAh cell can trigger it with real charge left
   (cause 2.1). "Even after charging": if charge stopped early (bad contact, or you took it off when it looked
   charged) or the cell has lost capacity, the voltage under load crosses 3.5 V soon after.
2. **Watchdog reboot loop on an init failure.** [CODE] `main.c:288` (SD), `:336` (codec), and `:346` (mic) `return` from `main()`.
   Nothing feeds the 30 s watchdog after that, so the SoC resets, buzzes (boot haptic `main.c:212`), fails again,
   and BLE never starts. From outside it looks like a dead or "off" device that buzzes now and then; compare [#20625](https://github.com/BasedHardware/omi/issues/20625).
   3.0.21 adds a new way into this loop (mic rail).
3. **Battery genuinely worn/damaged.** [GUESS] Upstream's quoted runtime is 10–14 h. Much less than that after a confirmed full charge points at the cell.
4. **Accidental long press.** [CODE] 3 s hold = power off (`button.c:153`). It's worth ruling out (clip pressure, sleeping on it).
5. **Not actually off.** [ISSUE] [#7358](https://github.com/BasedHardware/omi/issues/7358): the LED can be dark while the device is still running.

### Symptom 4 — "Connecting is flaky; unclear status; connection drops"
1. **Android Background mode is off by default.** [CODE] `OmiBleForegroundService.isBackgroundModeEnabled()`
   (`app/android/app/src/main/kotlin/com/friend/ios/ble/OmiBleForegroundService.kt:85`) reads `backgroundModeEnabled`, default
   `false`. When it's off, the native BLE foreground service stops as soon as the app is swiped away, and the link goes with it. Battery
   optimization (Doze) can also delay reconnects.
2. **A launch-time 60 s connect timeout tore down native auto-reconnect.** [CODE] [ISSUE] [#20777](https://github.com/BasedHardware/omi/issues/20777): if the device was off or away
   when the app started, it never reconnected afterwards. **Fixed here** by cherry-picking PR #21302.
3. **The device turning off** (symptom 3) shows up as a "drop".
4. **The UI didn't say how fresh anything was.** [CODE] No "last seen", no battery age, and Diagnostics were only reachable while connected. **Fixed here.**
5. **Firmware connection-parameter ping-pong.** [GUESS] `transport.c:725`: every parameter update with an interval > 30 ms
   triggers an immediate re-request, without limit, sleeping in the BT callback context. Draft patch caps it.
6. **Stale bond after an OTA.** [ISSUE] The app's DFU uses `eraseAppSettings: true` (`app/lib/pages/home/firmware_mixin.dart:213`), which erases the
   device's settings partition, including its BLE bond, while Android keeps its half. That can show up as
   "connected, then immediately disconnected" or a pairing-lost prompt (cf. [#7353](https://github.com/BasedHardware/omi/issues/7353), [#11308](https://github.com/BasedHardware/omi/issues/11308)). Fix: forget the device in Android Bluetooth settings and re-pair.

### Symptom 5 — "Firmware updates fail or don't seem to take"
1. **The app trusted the DFU library's "success".** [CODE] That success only means the upload and reset were acknowledged.
   Nothing checked the version the device reported afterwards. **Fixed here** (post-reboot version verification + notification).
2. **The download didn't check the HTTP status or truncation.** [CODE] An error page saved as `firmware.zip` surfaced later as a vague
   "install failed". **Fixed here.**
3. **Low battery during OTA.** [CODE] The app allowed an update at a 0 % reading (**fixed**). Separately, the firmware's 3.5 V cut-off can
   fire mid-upload under radio load (firmware draft #2).
4. **Bond erased by the update** (symptom 4, cause 6): the update did take, but the app can't reconnect to show it.
5. **MCUboot rejected the image.** [GUESS] Overwrite-only + downgrade prevention, but all builds use image version 0.0.0, so equal versions pass.
   Unlikely for official images.

---

## 3. What I changed in the app (branch `ccr-5f9fd4e0-y9emw6`)

One commit per fix:

| Commit | What and why |
|---|---|
| `7a30224d`…`fc25af65` (4) | **Cherry-pick of upstream PR #21302** (open; fixes #20777). A launch-time connect timeout no longer disposes the transport, so native auto-reconnect can still bring the device back. Includes upstream's tests. |
| `39eef371` | **Fork diagnostics log** (`app/lib/services/devices/fork_diagnostics_log.dart`). Append-only JSONL in app storage (20k entries) that never throws into the BLE path. `BleBridge` logs each native device-ready and **disconnect with its native reason**. |
| `764fdadb` | **OTA robustness.** Post-reboot **version verification** (`app/lib/utils/firmware_update_verification.dart`): the update counts only when the device reports the target version, and you get a notification either way. The download rejects non-2xx and truncated files. The failure screen shows the underlying error. Every OTA step, each 10 % of progress, and mcumgr warnings go to the log. |
| `e1bb1cd1` | **Honest battery/connection UI.** Battery shows "Updated N min ago" and turns grey "~NN %" when stale (>2 min without a firmware notification), or "last known" when disconnected. The disconnected card shows "Last seen N min ago". 0 % is shown, not hidden. Diagnostics are reachable while disconnected. Battery changes (plus a 5-min heartbeat), charging transitions, and connect (firmware/hardware/model)/disconnect events go to the log. |
| `c6ec6ac9` | OTA minimum-battery gate no longer treats 0 % as "unknown". |
| `bb0f5e9a` | **Diagnostics page:** new "Phone setup" group (Background mode on/off; Android battery optimization, tap to exempt; fork log size, tap to clear). **Share** now exports a `fork` section: timestamps, phone setup, and the full fork log. The support-upload payload is unchanged. |
| `aa662602` | CI: `.github/workflows/fork_device_builds.yml` builds the APK (and the firmware drafts on the firmware branch) on GitHub runners. |

New user-facing strings in these fork screens are English-only. The upstream l10n tool requires translations for every locale, which isn't worth it for a personal fork.

Not changed, deliberately: Background mode's default. Turning it on changes when audio is streamed, so it should be your
choice. The new diagnostics row tells you if it's off. The test plan turns it on.

Verified here: `flutter analyze` on all touched files (clean); unit/widget tests for devices, device provider, device
settings, diagnostics, and capture (all pass after updating two test stubs). **Not verified:** anything on a phone or device.

## 4. Firmware investigation (branch `ccr-5f9fd4e0-y9emw6-firmware`, drafts only)

### 4.1 Bootloader / signing — can custom firmware be installed over the air?
**Yes, very likely without a J-Link.** [CODE] MCUboot verifies images against `SB_CONFIG_BOOT_SIGNATURE_KEY_FILE` =
`omi/firmware/bootloader/mcuboot/root-rsa-2048.pem` (`omi/firmware/omi/sysbuild.conf`). That file is a **private
RSA key committed to the public repo**, and `scripts/ci/README.md` says official releases are signed with it. So a
fork build signed with the same key is accepted by the same bootloader your device uses for official OTAs. The app
already has the path to do it: Settings → Developer settings → flash a local firmware `.zip` (`DeveloperFirmwareFlashPage`).
Caveats:
- Overwrite-only + downgrade prevention ([CODE] `sysbuild/mcuboot.conf`). No image version is set, so builds are 0.0.0 and equal versions pass. **[GUESS]** that your bootloader matches this config.
- The network core's bootloader (b0n) key isn't pinned in config. Official releases are built the same way and OTA fine,
  so a fork build from this pipeline should behave the same. **Unverified.**
- A J-Link (and the `.hex` files) is the recovery path if an image bricks the device. That's why nothing should be flashed until the drafts are built, reviewed, and you've decided.
- Side note: because the signing key is public, *anyone* can sign firmware your device will accept over BLE.

### 4.2 Battery measurement
SAADC AIN0, gain 1/3, internal 0.6 V reference, 12-bit, 10 µs acquisition time. 50-sample burst, median, divider math
(R1=1091, R2=499), −16 mV while charging. Two 11-point tables, 4140/4200 mV = 100 % down to 3600/3750 mV = 1 %. The first reading after boot is discarded. Reported over the standard
Battery Service every 5 s connected / 10 s disconnected. Charging state comes from the BQ25101 `CHG` pin (P0.07, pull-up, both-edge IRQ)
and is exposed on characteristic `19B10013` (notify). Raw millivolts are **not** exposed in shipped firmware.
Minor: `BATTERY_STATES_COUNT` is 16 but each table has 12 rows (the rest zero-fill). Harmless.

### 4.3 Shutdown, watchdog, BLE disconnect — and the drafts
All drafts **compile and link** in the full NCS 2.9.0 sysbuild. [CI run 38240782702](https://github.com/ramseykilani/omi/actions/runs/38240782702) produced an MCUboot-signed `dfu_application.zip` plus `merged.hex`/`merged_CPUNET.hex`, in artifact `omi-cv1-fork-firmware-drafts`. Building isn't testing, though: **none of them has run on a device.**

| Draft commit | Change | Addresses |
|---|---|---|
| `042d2ec6` | `_transport_connected` returns early when `err != 0` (it used to take a ref and set `is_connected` on a failed link), and stops unref'ing a ref it never took. Defensive; probably rare for a peripheral. | Symptom 4 (minor) |
| `4c5f344d` | Low-battery power-off needs **3 consecutive** readings < 3500 mV and **never happens while charging**. | Symptoms 1, 3, 5 |
| `ac7a4f15` | Before System OFF, arm `CHG` (active-low) as a **wake source** when not already charging, so docking a dead device boots it and the charging LED shows. Needs a hardware check that CHG stays high off-dock in System OFF. | Symptom 1 |
| `a30a85dc` | On SD/codec/mic init failure, **continue with BLE up** (error LED pattern still shown) instead of returning into a watchdog reboot loop. | Symptom 3, #20625-like |
| `3820c4e1` | Cap fast connection-parameter re-requests at 3 per connection. | Symptom 4 (speculative) |
| `f25e12b9` | Implement the **Omi Diagnostics characteristic** `19B10040/19B10041` that the Android app already reads every ≤15 min but CV1 never served. Contents: reset cause (power-on / pin / watchdog / wake-from-OFF / lockup), uptime, battery **mV**, charging, last off-charger mV, CHG edge count. | Evidence for all symptoms |

The firmware version string is left at 3.0.21. If you ever flash a draft, the app won't be able to tell it from official 3.0.21.

## 5. Build status / APK

The APK could **not** be built inside this session. Its network policy blocks `dl.google.com`, which serves Google Maven (Android Gradle Plugin, androidx)
and the Android SDK. Flutter 3.44.5 and an Android SDK were obtained some other way, and Dart code generation and analysis worked,
but Gradle can't fetch AGP 8.11.1. So the APK is built on GitHub Actions by `.github/workflows/fork_device_builds.yml`
on every push to the app branch. Download it from the run's **Artifacts** (`omi-fork-prod-debug-apk`). Manual build
instructions are in `TEST_PLAN.md` §0.

APK configuration: `prod` flavor (package `com.friend.ios`, same as the store app), production API `https://api.omi.me/`,
the committed public Firebase client config (`app/setup/release-firebase`), sign-in via the backend's web flow
(`USE_WEB_AUTH=true`, `USE_AUTH_CUSTOM_TOKEN=true`), and the committed community debug keystore. Version `1.0.600 (90000)`, arm64.
**Missing / stubbed:** PostHog, Intercom, Google client ID/secret, OpenAI, OneSignal, Growthbook, and Maps keys. So: no analytics, no in-app
support chat, no native Google sign-in sheet (web sign-in instead). Push notifications from Omi's servers won't reach this build (signature differs).
**[GUESS]** Whether production sign-in accepts a differently-signed APK is untested. If Firebase's Android API key is
restricted to the store signature, sign-in will fail. `QUESTIONS.md` covers it.

Because the package name matches but the signature differs, **you must uninstall the official app first**. Uninstalling deletes its local
data, so **sync any offline recordings first**, and note your settings.

## 6. Still unverified (everything, really — but especially)
- Every runtime behaviour of the app changes (no phone available). Unit and widget tests pass.
- Whether sign-in works in a self-signed production build.
- All firmware drafts: they compile (CI), but nothing has run on hardware.
- The BQ25101 CHG-at-termination behaviour as it applies to your unit, the divider units, and whether VBUS or CHG can wake the SoC.
- Whether your symptoms are hardware (cell, pogo contacts, dock) rather than software. The test plan is designed to separate the two.
