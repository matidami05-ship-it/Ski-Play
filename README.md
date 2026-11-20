# Ski Play

Play your PS5 (or PS4) on your iPhone over your home Wi-Fi — a faster, more reliable alternative to Sony's Remote Play app, built on [chiaki-ng](https://github.com/streetpea/chiaki-ng), the open-source Remote Play client.

- Finds your console on the Wi-Fi automatically, shows if it's on or in rest mode, and wakes it up
- One-time PlayStation sign-in and linking with the 8-digit code from the console
- Hardware video decoding (H.264 / HEVC) shown the moment each frame arrives — no buffering
- Low-latency audio (~40 ms buffer that catches up after hiccups)
- DualSense, DualShock 4, Xbox and MFi controllers (touchpad, rumble, PS button), or on-screen controls
- Quality presets (Smooth / Balanced / Sharp / Max), 30 or 60 fps, live stats (fps, ping, bitrate, packet loss)

## Less lag

1. Plug the PS5 into the router with Ethernet.
2. Keep the iPhone on 5 GHz Wi-Fi.
3. If it still stutters, pick **Smooth** in Settings.

## First-time setup on the PS5

- Settings › System › Remote Play › **Enable Remote Play**
- Settings › System › Power Saving › Features Available in Rest Mode › **Stay Connected to the Internet** and **Enable Turning On PS5 from Network** (so the app can wake it)
- In Ski Play: Sign in to PlayStation › your PS5 shows up › **Link** › on the PS5 choose **Link Device** and type the code.

## Install (TestFlight)

Every push to `main` builds the Remote Play library for iPhone, compiles the app, signs it and uploads it to TestFlight.

One-time setup:
1. Repo › Settings › Secrets and variables › Actions: `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_CONTENT`, `APPLE_TEAM_ID` (same values as the other Ski apps). Using the same API key reuses the saved signing certificate in `signing/`, so no new certificate is created.
2. App Store Connect › Apps › **+** › New App, bundle ID `com.skistudio.play`, then re-run the workflow.

## Project

- `scripts/build-chiaki.sh` — cross-compiles chiaki-ng and its dependencies (OpenSSL, Opus, curl, json-c, miniupnpc, libevent) for iOS into `Vendor/` (cached in CI)
- `Bridge/` — small C layer between Swift and chiaki-ng
- `SkiPlay/` — SwiftUI app (iOS 17+). Xcode project is generated from `project.yml` with XcodeGen.

## License

AGPL-3.0, same as chiaki-ng (see `LICENSE`). If you share the app with others you must also share this source code. Not affiliated with or endorsed by Sony Interactive Entertainment.
