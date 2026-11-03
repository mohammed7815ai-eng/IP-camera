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

## Coming next

- Stage 2: face detection, licence-plate reading, image enhancement.
- Stage 3: continuous and event recording, timeline playback, alarms with push notifications.

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
