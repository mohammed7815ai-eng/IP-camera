# HomeGuard

Secure home security camera app for **Windows** and **Android**, built with Flutter.

## What works now (Stage 1)

- Add cameras three ways:
  - **ONVIF**: finds cameras on your network (WS-Discovery), logs in with WS-Security digest (password never sent), lets you pick main or sub stream.
  - **RTSP / RTSPS**: address + path, or paste a full `rtsp://` URL.
  - **HTTPS API key**: JPEG snapshot endpoint with an API-key header, refreshed every N seconds.
- Live grid (1 to 4 per row), full-screen view with pinch zoom, snapshots saved to disk, snapshot gallery.
- Auto-reconnect with back-off when a camera drops.
- Security:
  - Passwords and API keys in the **Android Keystore** / **Windows DPAPI** (`flutter_secure_storage`), never in preferences or logs (covered by tests).
  - HTTPS cameras are **certificate-pinned** on first connect (you approve the SHA-256 fingerprint); a changed certificate blocks the connection.
  - Optional **app lock** with Windows Hello, fingerprint, or device PIN.
  - Android backups disabled so secrets never leave the phone.
  - Unencrypted cameras are flagged with an orange open lock.

Known limit: RTSPS streams are encrypted but libmpv does not verify the camera certificate; keep cameras on a private network or VLAN.

## Stage 2 (v1.1): on-device AI

- **Face detection** (UltraFace) and **number-plate detection + reading** (YOLOv9 + fast-plate-ocr), switched on per camera, every 1 to 10 seconds. Boxes and plate numbers are drawn on the live picture.
- **Detections log**: every face and plate with a close-up crop and the full frame, searchable by plate number; repeats are suppressed (faces 20 s per camera, the same plate 2 min across cameras).
- **Enhance**: low-light boost, edge-preserving denoise, auto contrast, sharpening, 2x upscale, with a before/after slider. Enhanced copies are stamped "ENHANCED"; originals are never changed.
- Everything runs on the device (ONNX Runtime on Windows and Android). Models and licences: `assets/models/LICENSES.md`.
- Faces are detected, not identified.

## Stage 3 (v1.2): recording, playback, alarms

- **Recording per camera**: continuous 24/7, or only around events (1-minute clips kept around motion, faces and plates, plus a minute before and after). The camera's stream is saved as-is (no re-encoding), in 5-minute `.mkv` files under `Recordings/<camera>/<day>/`.
- **Background workers**: a headless player per camera decodes only keyframes for motion detection and AI, so 24/7 watching costs far less than live view.
- **Playback**: day timeline with recorded spans and colour-coded event ticks, zoom to 6 h / 1 h, 0.5x to 16x, 30-second jumps, auto-advance across files, and a synced multi-camera view (up to 4).
- **Export** a clip with a `.sha256` file to prove it was not changed.
- **Alarm system**: Disarmed / Home / Away; per-camera triggers (motion, person, vehicle) and "alarm in Home mode"; plate **watchlist** (always alerts) and **allowed list** (never alarms); notifications on Android and Windows, a generated siren, an alarm inbox that jumps to the recording.
- **Storage**: retention days per camera and a total limit (oldest deleted first).
- **Android background mode** (opt-in): a foreground service with a permanent notification keeps recording and alarms running when you leave the app. On Windows, keep the app open or minimised.

## Auto setup (v1.3)

- Radar button on the Home screen: scans the device's own /24 network for camera ports, runs an ONVIF WS-Discovery search, fingerprints each device (ports, web banner, ONVIF scopes), then logs in over ONVIF or tries the brand's RTSP stream paths with RTSP Digest/Basic login.
- Only private addresses are scanned; the typed password is tried once per path, never guessed.
- Code: `lib/discovery/` (net_scan, rtsp_probe, camera_agent), UI in `lib/ui/auto_setup_page.dart`.

## Coming next

- Remote access from outside the home (WireGuard), smaller per-architecture APKs, code-signed Windows installer.

## Install

Download from the GitHub Actions run (artifacts) or a tagged release:

- **Windows**: `HomeGuard-Setup-x.y.z.exe` (installs per-user, no admin needed) or `HomeGuard-portable.zip`.
- **Android**: `HomeGuard.apk`. Allow "install unknown apps" for your browser or file manager, then open it.

## Build

```sh
flutter pub get
flutter test
flutter build apk --release        # Android
flutter build windows --release    # Windows (on Windows, with Visual Studio C++ workload)
iscc installer\HomeGuard.iss       # Windows installer (Inno Setup 6)
```

Release signing for Android: set the repo secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`. Without them CI signs with a debug key (fine for personal sideloading, but updates must keep using the same key).

Tag a version (`git tag v1.0.0 && git push --tags`) to publish a GitHub Release with both installers.
