# The Android app

`qt_badger_app/` is a Flutter app (Dart) - `dist/QT-BADGEr-2.0.apk` is the release build. It talks to the hub's HTTP
API (`docs/API.md`) over Wi-Fi: your phone and the board have to be on the same network (a phone hotspot works).

## Install

1. Copy `dist/QT-BADGEr-2.0.apk` to the phone (USB, Drive, or `adb install -r QT-BADGEr-2.0.apk`).
2. Open it and allow "install unknown apps" for whatever opened it. (It is signed with the debug key, so Play Protect may
   ask you to confirm once. See "Publishing" below.)
3. First launch shows **Welcome**: the board's address is pre-filled (`192.168.157.74`). Tap **Test**, then **Connect**.
   If the address is wrong (a hotspot restart changes it), tap **Scan network**: the app checks every address on the
   networks the phone is on and lists the badge.

Permissions it asks for, and why: **location** (send your position to the badge indoors, "you are here" on the map, phone
as a peer), **microphone** (dictate tasks and messages), **notifications** (SOS, reminders, arrival). All optional - the
app works without them.

## Tabs

| Tab | What you can do |
|---|---|
| **Badge** | A live mirror of the badge's TFT, redrawn from the hub's status with the firmware's own layout and colours, so you see exactly the screen it is on. A remote for the two buttons (Left / Right / Select / Back) and chips to jump to any screen. **Find badge** (flashes + buzzes until you stop it), **Message**, **Read tasks** aloud on the phone, live stats, and a hold-to-send **SOS**. |
| **Tasks** | The badge's 8 slots: tick, swipe to delete, read aloud. **Add** by typing, **dictating**, or scheduling a **timed reminder** (it appears on the badge at that time with a buzz). The sparkles button is the **schedule organizer**: paste or dictate an agenda and each action item becomes a reminder (Auto / Instant / AI-only). |
| **Map** | OpenStreetMap with the badge, its destination, peers, you, and the badge's trail. **Long-press** the map to send the badge there; or enter coordinates / paste a Google Maps or OSM link. "Use phone GPS on the badge" feeds it your location when it has no GPS fix. |
| **Inbox** | Send messages to the badge (quick replies, dictation, optional buzz). They show as a banner, then wait in its Inbox screen. Swipe to delete. |
| **More** | **Name tag** (name, title, organisation and a live QR code: contact card / link / text, uploaded to the badge as a bitmap), **Peers** (list, share this phone as a peer, add one by hand), **Voice** (read reminders out, speed/pitch), **Alert and SOS** (hold to send, emergency contacts with one-tap call / text-with-location, alert history), **Settings** (brightness, haptics, peer alert distance, badge clock, notifications, theme), **Connection**, **About and diagnostics**. |

An SOS (from the badge's button or the app) raises a full-screen alarm in the app with the badge's last position, an
"open in maps" link, and call/text buttons for your emergency contacts, plus a high-priority notification.

## Things to know

* **Alerts need the app to be running.** It polls the hub about every 1.5 s while open. Android may suspend it in the
  background, and there is no background service yet - so an SOS pressed on the badge while the phone has the app closed
  is seen when you next open it (the alert history shows it). A foreground service is the natural next step; see the
  "Next steps" in the top-level README.
* The badge's clock follows the phone's time zone (the app sets it on first connect).
* It uses plain HTTP: Android blocks that by default, and the app opts in (`usesCleartextTraffic`) because the hub is
  on your LAN and has no certificate.
* Text with accents or emoji is folded to ASCII by the hub (the badge's font can't draw them).

## Build it yourself

```bash
cd qt_badger_app
flutter pub get
flutter analyze && flutter test                # lint-clean, 29 tests
flutter build apk --release                    # -> build/app/outputs/flutter-apk/app-release.apk
flutter build web --release                    # optional: a browser build for quick UI checks
```

Needs the Flutter SDK, JDK 17 (Android Studio's bundled one is fine) and the Android SDK. The first Gradle build
downloads the NDK, an SDK platform and CMake into the SDK folder (a few GB, one time).

## Publishing

The release build is signed with the debug key so it installs immediately. For the Play Store, create a keystore, add a
`signingConfigs` block to `android/app/build.gradle.kts` and reference it from the `release` build type; change the
application id (`com.qtbadger.qt_badger`) if you want your own.

## Code map

```
lib/main.dart                     entry
lib/src/api/                      models.dart (JSON -> classes), badge_api.dart (one method per endpoint)
lib/src/state/app_state.dart      polling, events, every action, phone-location sharing
lib/src/services/                 settings, notifications, speech (TTS + STT), location, network scan, QR bitmap
lib/src/ui/                       theme, widgets, shell (tabs), one file per page, virtual_badge.dart (the TFT mirror)
test/                             models (parses a real /api/status), API client (mock server), QR bit packing, coordinates
```
