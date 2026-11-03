## Install

**Windows 10/11:** download `HomeGuard-Setup-<version>.exe` and run it (no admin rights needed). If SmartScreen warns, click **More info**, then **Run anyway**; the app isn't code-signed yet. `HomeGuard-portable.zip` runs without installing.

**Android 7+:** on your phone, download `HomeGuard.apk`, open it, allow your browser to **Install unknown apps**, then tap **Install**. If Play Protect warns, tap **Install anyway**.

Your device must be on the same network as the cameras.

## What's in this version

- Add cameras by ONVIF (auto-discovery on your Wi-Fi), RTSP/RTSPS, or HTTPS API key
- Live grid (1 to 4 per row), full-screen view with zoom, snapshots and gallery, auto-reconnect
- Camera passwords and keys stored in Android Keystore / Windows DPAPI
- HTTPS certificate pinning, ONVIF digest login, Windows Hello / fingerprint app lock

## New in 1.1.0: on-device AI

- Face detection and number-plate reading per camera (turn on in the camera's settings), with boxes on the live picture
- Detections log with close-ups, searchable by plate number
- Enhance any snapshot or detection: low light, denoise, contrast, sharpen, 2x upscale, before/after slider
- Runs fully on your device; nothing is uploaded

## New in 1.2.0: recording, playback and alarms

- Record each camera 24/7 or only around events, with storage and retention limits
- Playback timeline with event markers, zoom, speeds up to 16x, and a 4-camera synced view
- Export clips with a SHA-256 fingerprint
- Alarm system with Disarmed / Home / Away modes, motion / person / vehicle triggers, plate watchlist and allowed list, notifications and siren
- Android: optional "keep watching in the background"

## New in 1.3.0: automatic camera setup

- **Auto setup** (radar button on the Home screen): scans your home network, finds cameras, works out how to connect (ONVIF, or RTSP with the right stream path for Hikvision, Dahua, Reolink, Tapo, iCSee/XMEye, Yoosee, V380, CamHi, Uniview, Axis and generic cameras), checks the login, and adds working cameras with one tap
- Tells you clearly when a camera refused the password, or only works in its maker's cloud app
- More reliable "Find cameras on my network": searches every network adapter, asks in three ways, and holds Android's multicast lock while searching
- Cameras that need the login inside the stream path (iCSee/XMEye) are supported; the password still stays in secure storage
