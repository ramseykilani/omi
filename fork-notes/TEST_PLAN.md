# "When the device arrives" test plan

Do the parts in order. Each one rules something out before the next adds variables. Keep a simple
notes file with timestamps (or photos/videos with timestamps). Times matter more than anything else.

Reference: [`REPORT.md`](REPORT.md) explains *why* each step is here.

---

## 0. Getting the APK (do this before the device arrives)

**Easiest:** GitHub → `ramseykilani/omi` → **Actions** → "Fork device builds (APK + CV1 firmware drafts)" → latest run
on branch `ccr-5f9fd4e0-y9emw6` → **Artifacts** → `omi-fork-prod-debug-apk`. Unzip it to get
`omi-fork-prod-debug.apk` (plus a `.sha256`). Artifacts expire after 14 days. Re-run the workflow (Run workflow → branch
`ccr-5f9fd4e0-y9emw6`) to get a fresh one.

**Building it yourself** (Linux/macOS; needs Flutter **3.44.5**, JDK **21**, Android SDK platform **36** and NDK
**28.2.13676358**, e.g. via Android Studio):

```bash
git clone -b ccr-5f9fd4e0-y9emw6 https://github.com/ramseykilani/omi && cd omi/app
bash scripts/install_release_firebase_config.sh          # public Firebase client config (committed)
printf 'API_BASE_URL=https://api.omi.me/\nUSE_WEB_AUTH=true\nUSE_AUTH_CUSTOM_TOKEN=true\n' > .env
printf 'API_BASE_URL=\nUSE_WEB_AUTH=true\nUSE_AUTH_CUSTOM_TOKEN=true\n' > .dev.env
cp setup/prebuilt/key.properties android/                # community debug keystore (committed)
flutter pub get
dart run build_runner build --delete-conflicting-outputs
flutter build apk --debug --flavor prod --build-name=1.0.600 --build-number=90000 --target-platform android-arm64
# -> build/app/outputs/flutter-apk/app-prod-debug.apk
```

If the debug build feels sluggish (debug = JIT), build the same thing with `--profile` instead of `--debug`.

---

## 1. Hardware checks first (official app, official firmware, no changes)

### 1.1 What the LED *should* do (firmware 3.0.20/3.0.21, from `main.c` `set_led_state()`)
| State | LED |
|---|---|
| Booting | short **blue** flash, then two slow **green** fades; one short buzz |
| On dock, charging, < 98 % | **blinks** once a second: **green** alternating with **blue** (phone connected) or **red** (not connected) |
| On dock, charging, ≥ 98 % | **solid green** |
| On dock, charge *finished* | probably **solid blue/red**, the same as off-dock. The charger chip stops signalling "charging" when done; see REPORT §2 symptom 1 cause 2. **[GUESS]** |
| Off dock, running | **solid blue** (connected) / **solid red** (not connected) |
| Clock not set yet | **red blinking** (plus green if charging, blue if connected) until the app connects once |
| Powered off (long-press 3 s, or low-battery cut-off) | **dark — even on the dock.** The LED is driven by firmware, which is off. The battery still charges. |
| Error at boot | red, then a short coloured blink code. Cyan = SD/storage, yellow = battery, magenta = haptic |

### 1.2 Charger and cable
1. Use the original dock. Power it from **two different** plain 5 V USB sources: a phone wall charger (≥ 1 A) and a laptop port.
   Use **two different cables** if the dock has a removable cable.
2. Clean the device's charging contacts and the dock's pogo pins with isopropyl alcohol on a cotton swab, then let them dry.
   Press each pogo pin; it should spring back freely. Check the device snaps in squarely (magnets) and doesn't rock.
3. With the device on the dock and charging (blinking), tap the table gently. **If the LED pattern flickers between
   "charging" and "not charging", that's a contact problem** (dock or device), i.e. hardware.

### 1.3 Separating "battery/contacts are bad" from "software"
Run these in order. Note times.

1. **Dead-device test.** If it arrives flat or off: put it on the dock and **don't press anything for 60 min**.
   Expect the LED to stay dark (that's normal for an off device; see 1.1). Then press the button once.
   - Boots, then blinks "charging" and stays on → charging works; the darkness was just "off" (software design).
   - Boots, blinks "charging", **then turns off about 14 s later**, repeatedly → the firmware's low-voltage cut-off firing
     *while charging* (software bug; firmware draft #2 fixes it). Leave it on the dock another 1–2 h untouched and retry.
   - Never boots, even after 2 h on two chargers → hardware (cell, charger IC or contacts). Warranty.
2. **Full-charge test.** Charge until solid green or ≥ 2.5 h, then note the time and take it off the dock.
3. **Runtime test.** Use it normally (connected to the phone) until it turns off. Write down the time it died and the last % the app showed.
   - Upstream claims 10–14 h. **Under ~5 h, repeated twice after full charges, points at the battery.**
   - Dies while the app still shows ≥ 15 % → the % estimate is wrong and/or the single-reading cut-off fired (software).
     Note the RSSI and whether you were syncing or recording at the time.
4. **Heat/swelling.** If the device gets hot on the dock, the case bulges, or it smells: stop charging and go straight to warranty.

### 1.4 Evidence for a warranty claim
Collect as you go:
- Order number/date, the device's hardware revision and firmware (Omi app → Device settings, or nRF Connect §3.4).
- **Video** (10–20 s each) of the LED on the dock with **two** different power sources, and of any flicker-on-tap.
- The dead-device and runtime results from 1.3 with timestamps (start, unplug, death, % shown).
- Screenshots of the app battery % over time, or the diagnostics export (§3.3) showing the battery curve.
- A list of what you tried: cleaning, two chargers/cables, firmware update, reboot, re-pair.
- Report through the official app's help/support or Omi's support page. Mention [#5469](https://github.com/BasedHardware/omi/issues/5469)
  (charging reliability) if it fits.

---

## 2. Update to the latest official firmware (3.0.21), then re-check

Expectation: it probably **won't** change your symptoms (REPORT §1), but it puts you on the current baseline.

1. Official app, device charged ≥ 50 % **and sitting on the dock**, phone within 1 m, screen on, keep the app in the foreground.
2. Device settings → Firmware update → 3.0.21. Don't touch anything until it says done.
3. Afterwards, check the reported version: Device settings shows `3.0.21`. Also check in nRF Connect (§3.4).
4. If the app won't reconnect after the update: Android Settings → Connected devices → **Omi → Forget**, then pair again in the app.
   The update erases the device's pairing record (REPORT symptom 4 cause 6).
5. If it starts **buzzing every ~30 s with no Bluetooth**, that's the reboot loop described in REPORT §4.3. Video it and stop there.
6. Use it for a day. Re-run 1.3 steps 2–3. Note any change in all five symptoms.

---

## 3. Testing the fork APK

### 3.1 Install
1. In the **official** app: let offline recordings finish syncing (Device settings → Offline sync shows nothing pending).
   Note any settings you care about.
2. **Uninstall the official Omi app.** Same package name, different signature, so Android won't install over it. Uninstalling deletes its local data.
3. Install `omi-fork-prod-debug.apk` (allow "install unknown apps" for your file manager/browser).
4. Open it and sign in. Sign-in goes through a browser page. **If sign-in fails, stop and tell me the exact error** (QUESTIONS #1).
5. Pair the device.

### 3.2 Settings for testing
- Settings → **Recording & Transcription** → **Background mode: On** (otherwise swiping the app away ends the Bluetooth link). The device must be connected for the toggle to be enabled.
- Device settings → **Diagnostics** → **Phone setup**: Background mode should say On; tap **Battery optimization** until it says **Unrestricted**.
  On Samsung, also Settings → Battery → Background usage limits → make sure Omi isn't in "Sleeping/Deep sleeping apps".
- Settings → **Developer Settings** → **Debug Logs: On** (used in 3.4; they auto-delete after 3 days).
- Leave product analytics/tracking **on**. The native disconnect/battery history in Diagnostics is only recorded when it's on.
  This build has no analytics key, so nothing is sent. The fork event log records regardless.
- In Diagnostics → Phone setup → **Fork event log**, tap once to clear it, so the log starts at the beginning of testing.

### 3.3 Scenarios: what to do, what to watch
Write the start time of each scenario in your notes.

| # | Do | Expect / watch |
|---|---|---|
| A | Device on, app open. Look at the home pill and Device settings. | Pill shows the device + %. Device settings: battery row "Updated just now". Every ~30 s it should still say "just now". If it turns grey "~NN %" / "No update since…", battery notifications stopped while "connected". **Note the time.** |
| B | Walk 20–30 m away (or put the device in a microwave oven that is **off**, as a Faraday cage) for 2 min, then come back. Don't touch the phone. | Disconnects; Device settings shows "Last seen N min ago". Reconnects on its own within ~1 min of returning. |
| C | Turn the device **off** (hold 3 s). Swipe the app away. Open the app, wait **90 s**, then turn the device on. | Connects without you doing anything. Upstream bug #20777, cherry-picked fix. |
| D | With Background mode on, swipe the app away and lock the phone for 30–60 min, then open the app. | A "Connected to Omi" notification stays the whole time; no gap in the conversation; Diagnostics shows no new drops. |
| E | Put the device on the dock while connected. Leave it until full. | The app shows **Charging** within ~10 s. The LED matches 1.1. **Note whether "Charging" switches off by itself when full**, and the % at that moment. |
| F | Normal day of use. | When anything odd happens (drop, sudden % jump, device off), write the time and **export diagnostics right after** (3.4). |
| G | Only if a firmware update is offered: install it as in §2. | If it fails, the failure screen now shows a technical detail line; screenshot it. After the device reboots and reconnects, a notification says **"Firmware update confirmed"** or **"did not take"**. |

### 3.4 What to export (after each incident, and once a day)
1. Device settings → **Diagnostics** → **Share** (top right) → save or send the `.json`.
   It contains the native disconnect history with reasons, the battery curve, RSSI, firmware diagnostics, and the **`fork`** section
   (battery samples, charging transitions, connect/disconnect with reasons, OTA steps, phone setup).
2. Settings → Developer Settings → **Debug Logs** → share the latest log file.
3. Screenshots of the Diagnostics page (top half, plus the disconnect list).
4. Your notes with timestamps.

### 3.5 nRF Connect readings
Use **nRF Connect for Mobile** (Nordic). The device allows **one connection at a time**, so first force-stop the Omi app
(Android Settings → Apps → Omi → Force stop). Afterwards, disconnect in nRF Connect before reopening Omi.

1. **Scanner:** find "Omi". Screenshot the RSSI with the phone ~1 m away.
2. Connect. If prompted to pair, accept.
3. **Device Information (0x180A):** read and screenshot
   - Firmware Revision String (0x2A26), e.g. `3.0.20`
   - Hardware Revision String (0x2A27), e.g. `5.0`
   - Model Number String (0x2A24) `Omi CV 1` and Manufacturer Name (0x2A29)
4. **Battery Service (0x180F) → Battery Level (0x2A19):** read it, then enable notifications (the triple-arrow icon).
   Values should arrive about **every 5 s**. Leave it 2 min and screenshot the log (Log tab, with timestamps).
5. **Charging status:** service `19B10010-E8F2-537E-4F6C-D104768A1214` → characteristic `19B10013-…`: read (`0x01` charging,
   `0x00` not), enable notify, then put the device on and off the dock. Screenshot the log.
6. (Only if you ever run the fork firmware) service `19B10040-…` → characteristic `19B10041-…`: read and share the hex.
7. Do 3–5 once on the dock and once off it.
