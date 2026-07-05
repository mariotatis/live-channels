# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Read this first

**`ARCHITECTURE.md` (repo root) is the source of truth** for how this app works — crypto, networking, session/activation, playback, caching, and the reasons behind non-obvious choices. Read it before making changes; keep it updated when architecture changes.

## What this is

A native iOS (SwiftUI) **live-TV only** client for the Xuper-family "masnew" IPTV portal. It talks to the **real portal API** (no mock/demo data). VOD (movies/series) was deliberately removed — the provider delivers it over a proprietary P2P engine no player can consume; live is clean HLS. The project, target, app display name, icon, and splash are all "Channels" (bundle id `com.mariotatis.Channels`).

## Build & run

Single Xcode project, single scheme/target `Channels`, one SPM dependency (`vlckit-spm`, MobileVLCKit). **No test target exists.**

```bash
# Build for simulator
xcodebuild -project Channels.xcodeproj -scheme Channels \
  -destination 'platform=iOS Simulator,name=iPhone 16' build

# Clean
xcodebuild -project Channels.xcodeproj -scheme Channels clean
```

Normal workflow is building/running from Xcode. iOS 26 target, Swift 5.

## Critical conventions (easy to get wrong)

- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`** — most types are MainActor-isolated by default. VLC delegate callbacks arrive **off-main**; hop to `@MainActor` before mutating layers or you get a crash.
- **Files auto-compile:** `Channels/` is a `PBXFileSystemSynchronizedRootGroup` — new `.swift` files under it are picked up without touching `.pbxproj`.
- **`Info.plist` lives at the repo root**, not inside `Channels/` (`INFOPLIST_FILE = Info.plist`). It sets `NSAllowsArbitraryLoads` (cleartext CDN + local proxy) and `UIBackgroundModes: [audio]`.
- **Don't** add a second FFmpeg-bearing library (VLC + FFmpeg-iOS/KSPlayer) — they collide on `libav*` symbols and crash.

## Where things live (see ARCHITECTURE.md for detail)

- `Core/Config/AppConfig.swift` — all hosts, secrets, ids, version identity (recovered from an Android capture). If activation starts failing with `版本已停止使用` / `portal200001`, the `apkId`/`apkVer`/`apkVersionBody`/`spkgVer` values must be refreshed from a current APK.
- `Core/Networking/` — `CryptoBox` (3DES/ECB/PKCS7 body crypto, custom base64 alphabet), `Endpoints`, `PortalClient` (single choke point: common params + crypto + session + main→backup failover all automatic).
- `Core/Session/` — `ActivationService` (no login screen; splash → `bootstrap()` → `activate()`), `KeychainStore`, `DeviceFingerprint`. Account is **single-active-device** on a shared `sn`.
- `Core/Player/` + `Features/Live/LivePlayback.swift` — MobileVLCKit (not AVPlayer; some channels are HEVC-in-TS). `LocalStreamProxy` serves the m3u8 locally because libvlc can't send the required auth headers.
- `Core/Services/LiveStore.swift` — single source of truth for catalog. Disk cache with 48h TTL; **empty results are never cached** (guards the single-device transient).

## Adding things

- **New portal call:** add path to `Endpoints.swift`, a `Decodable` result model, and a method on `ContentService` calling `PortalClient.shared.call(...)`.
- **New live-data surface:** extend `LiveStore` — respect the disk cache and never cache empty.
- **Config/secret change:** `AppConfig.swift`.
- **columnId matters for playback:** `startPlayLive` must use the columnId of the category the channel was listed under, or category-only channels return `频道不存在`. Favorites store their columnId for this reason.
