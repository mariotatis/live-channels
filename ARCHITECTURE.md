# Channels — Architecture

A native iOS (SwiftUI) **live‑TV** client for the Xuper‑family "masnew" IPTV portal.
The app is intentionally **Live‑TV only**: browse channels by category, search, favorite,
and play. It talks to the **real portal API** (no mock/demo data).

> Historical note: earlier iterations included Movies/Series/Sports/Kids/Downloads/Profile
> and demo mode — all removed. VOD was dropped because the provider delivers it over a
> proprietary P2P/"p2sp" engine that AVPlayer/VLC can't consume; **live is clean HLS and works.**

---

## 1. Tech & conventions

- **SwiftUI**, target iOS 26, Swift 5, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  (most types are MainActor‑isolated by default).
- **State:** `@Observable` singletons for shared state; `@StateObject`/`ObservableObject` only
  where needed (the VLC player model).
- **One external dependency:** `VLCKitSPM` (MobileVLCKit) via SPM — see §7.
- **Files auto‑compile:** `Channels/` is a `PBXFileSystemSynchronizedRootGroup`, so new `.swift`
  files under it are picked up without editing the `.pbxproj`. **Exception:** `Info.plist` lives at
  the **repo root** (`INFOPLIST_FILE = Info.plist`), never inside `Channels/`.
- Entry point: `Channels/ChannelsApp.swift` → `RootView` → activation gate → `RootTabView`.

## 2. Project structure

```
Channels/
  App/            RootView (splash/gate), RootTabView (3 tabs), Router (AppTab enum)
  Core/
    Config/       AppConfig.swift          — all hosts, secrets, ids, version identity
    Networking/   CryptoBox, Endpoints, PortalClient
    Session/      ActivationService, DeviceFingerprint, KeychainStore
    Services/     ContentService, LiveStore, ParentalControl
    Models/       Common, Session, LiveModels
    Player/       PlayableStream, PlayerView (VLC), LocalStreamProxy
  DesignSystem/   Theme, Components (state/empty/error views, PosterImage)
  Features/
    Home/         HomeView (Categories list), CategoryChannelsView
    Live/         LiveView (Channels), FavoritesView, LiveChannelCard,
                  LiveComponents (grid + .livePlayer modifier), LivePlayback
    Parental/     ParentalControlView, PinViews
Info.plist        (repo root) — ATS + background audio
ARCHITECTURE.md   (this file)
```

## 3. Secrets & configuration — `Core/Config/AppConfig.swift`

Everything the API needs to authenticate is centralized here (all `let` constants, recovered from
a runtime capture of the working Android app):

> **Values are redacted here on purpose** (this file is committed). The real values live only in
> `AppConfig.swift` (git‑ignored); `AppConfig.swift.example` shows the shape with placeholders.

| Constant | Purpose |
|---|---|
| `defaultPortalHost` / `backupPortalHost` | portal + backup hostnames (DGA/rotating; client does main→backup failover) |
| `apkId` | client app id — sent as header `apk` **and** body `appId` |
| `apkVer` | header `apkVer` — client version code |
| `apkVersionBody` | body `apkVersion` — client version |
| `spkgVer` | header `spkgVer` — build/package stamp |
| `bodyKey` | the 3DES body cipher key (see §4) |
| `capturedSn` | device serial the shared account is bound to |
| `capturedDrmId`, `capturedReserve1` | body params `drmId` / `reserve1` |
| `liveColumnId` | the flat "ChannelList" column |
| `liveCategoryColumnId` | the category‑tree root column |
| `apiPrefix`, `scheme` | base URL parts (`api/portalCore`, `https`) |

> **Version gate:** the portal rejects discontinued client versions with `版本已停止使用`
> (`portal200001`). If activation starts failing with that, the `apkId`/`apkVer`/`apkVersionBody`/
> `spkgVer` values here must be refreshed from a current APK.

## 4. Body crypto — `Core/Networking/CryptoBox.swift`

Every POST body (and the `data` field of every response) is encrypted:

- **Cipher:** `3DES / ECB / PKCS7`. (NOT AES — that was an early wrong guess.)
- **Key:** the app uses a custom Base64 alphabet where `-` maps to `/`. So the real 24‑byte key =
  `base64decode(bodyKey.replacingOccurrences("-","/"))[0..<24]`.
- **Wire format:** the request body is the **raw string** `hex( base64( 3DES(json) ) )` — **not** a
  `{data,len}` envelope. Responses come back as `{returnCode, errorMessage, data}` where `data` is
  the same `hex(base64(3DES(json)))`.
- `encryptBody(json) -> String` and `decryptBody(hex) -> String` are the only entry points.

## 5. Networking — `Core/Networking/PortalClient.swift` + `Endpoints.swift`

`PortalClient.shared.call(_ endpoint, params:, as:)` is the single choke point for portal calls:

1. Builds URL `https://<host>/api/portalCore/<endpoint.path>`.
2. Merges `commonBodyParams` (loginType, appLanguage, `apkVersion`, `appId`, model=`Pixel 3a`,
   `sn`, `drmId`, `reserve1`, `sdkVer:32`, …) into `params`, plus the **session triple**
   (`userId`/`userToken`/`portalCode`) for authenticated calls (not the initial `active`).
3. **HTTP headers:** `apk`, `apkVer`, `spkgVer`, `Content-Type: application/json; charset=utf-8`,
   `User-Agent: okhttp/3.12.12`. **HTTP/2 is required** (URLSession default).
4. Encrypts the JSON body via `CryptoBox` (unless `endpoint.encrypted == false`).
5. `main → backup` host failover on transport errors only.
6. Decodes `OuterResult`; success is `returnCode == "0"` (or `isSuccessReturnCode`); decrypts
   `data`; JSON‑decodes into the requested `Decodable`.

**Endpoints actually used** (all others were removed as dead code):
`active`, `heartbeat`, `getSlbInfo`, `getColumnContents`, `getLiveData`, `startPlayLive`.

## 6. Session & activation — `Core/Session/`

- **No login screen, ever.** On launch `RootView` shows a splash and calls
  `ActivationService.shared.bootstrap()` → `activate()`.
- `activate()` POSTs `v8/active` with `DeviceFingerprint.activeBody()` (`snToken:""` — this build
  activates directly; a fresh `sn` would need a vendor cert we don't have, so we reuse the captured
  `sn`). The response yields `userId`, `userToken`, `portalCode` → a `Session`.
- The `Session` is persisted to **Keychain** (`KeychainStore`, key `session.triple`) and provided to
  `PortalClient` via `setSessionProvider`. `DeviceFingerprint.stableId` is a Keychain‑persisted UUID.
- **Heartbeat:** after activation a background task calls `v5/heartbeat` on `heartBeatTime`; a
  server auth error triggers a silent re‑activation.
- **Single active device:** the account allows one active session at a time on the shared `sn`.
  Concurrent activations (e.g. dev tooling hitting the API) transiently invalidate the app's session
  and cause empty catalog loads — a data/env quirk, not a bug.

## 7. Playback — `Core/Player/` + `Features/Live/LivePlayback.swift`

**Engine: MobileVLCKit (VLCKitSPM), not AVPlayer.** A subset of channels (the "FHD" variants,
e.g. `AMC HD`) stream **HEVC inside MPEG‑TS**, which AVFoundation cannot decode (audio‑only). VLC
decodes both H.264‑ and HEVC‑in‑TS.

How a channel becomes a stream (`ContentService.liveStream(channel:columnId:)`):
1. `startPlayLive` (with the **correct columnId**) + `getSlbInfo` run concurrently.
2. Pick CDN `cdn_type == 4` ("youshi"); build `http://<cdn>/live/<playCode>.m3u8`.
3. Auth is via **HTTP headers**: `Content-Auth` (from getSlbInfo `url_list[0].url`),
   `Content-License` (from startPlayLive `license`), plus `App`, `App-Version`,
   `User-Agent: Ranger/4.9.4-17294ac0`, `Pragma: akamai-x-cache-on`.

**columnId matters:** `startPlayLive` must use the columnId of the category the channel was listed
under. Category‑only channels (e.g. **18+** col `76208`) are absent from the flat list (`76182`) and
return `频道不存在` there. `ChannelGridView` threads a `columnIdFor` closure; favorites remember their
columnId (`FavoriteChannel`).

**libvlc can't send custom HTTP headers**, and the CDN requires them **on the `.m3u8`** (query params
→ 401). The **video segments are open** (no auth) with absolute URLs. So `LocalStreamProxy` (an
`NWListener` on `127.0.0.1`) serves the playlist: on each request it re‑fetches the real m3u8 **with
headers** (URLSession) and returns it; VLC fetches segments directly (bypasses ATS via its own HTTP
stack). Player URL = `http://127.0.0.1:<port>/<token>.m3u8`.

`PlayerView.swift` details (VLC delegate callbacks arrive on a **background thread** → hop to
`@MainActor`, else layer‑mutation crash):
- Custom controls overlay: close (X‑style chevron), **favorite heart** (gradient when on),
  **subtitle toggle** (only shown when a track exists; enforced on refresh because VLC re‑selects on
  live), **fill‑screen** (aspect‑fill via a `CGAffineTransform` scale in `VLCContainerView.layoutSubviews`
  — computed from the video vs view aspect; `videoSize` is 0 on the simulator so it falls back to the
  media track info / 16:9). No LIVE badge, no center pause (live).
- The VLC drawable `UIView` has `isUserInteractionEnabled = false` so taps reach SwiftUI to toggle
  controls.

`LivePlayback` (per‑view `@Observable`) coordinates: `play(channel, columnId)` → PIN gate check →
`ContentService.liveStream` → `playerStream` → `.livePlayer` modifier presents `PlayerView`.
On failure it shows an alert with **Refresh** (`refreshAndRetry()` = reload catalog + retry).

**Background audio:** `Info.plist` `UIBackgroundModes: [audio]` + audio session `.playback`. Audio
continues when backgrounded; there is **no native PiP/AirPlay** (VLC can't feed them — this was
explored with KSPlayer and FFmpeg‑iOS and abandoned).

## 8. Catalog data & caching — `Core/Services/LiveStore.swift`

`LiveStore.shared` (`@Observable`) is the single source of truth for Home/Channels/Favorites:
- `allChannels` (getLiveData 76182), `categories` (getColumnContents 76175 → `[LiveColumn]`),
  `categoryChannels` (lazy per‑category getLiveData, cached).
- **Disk cache, 48h TTL:** the whole catalog is written to
  `Library/Caches/live_catalog_cache.json` (`CatalogCache{timestamp, allChannels, categories,
  categoryChannels}`). `loadIfNeeded()` serves from cache instantly on cold start if < 48h; `load()`
  (also pull‑to‑refresh) refetches and rewrites. **Empty results are never cached** (guards against
  the single‑device transient).
- **Favorites** (local): `FavoriteChannel {channel, columnId}` persisted as JSON in UserDefaults
  (`live.favorites.v2`) — stores the full channel + its columnId so category‑only favorites still
  play and display.

## 9. Data models — `Core/Models/`

- `Common.swift`: `PosterList` (+ `iconURL`/`anyURL` helpers), `BaseResult`, `@LenientInt`
  (decodes String‑or‑Number), `String.isSuccessReturnCode`.
- `Session.swift`: `Session` (persisted triple + display fields), `ActiveData` (activation response),
  `PortalCode`.
- `LiveModels.swift`: `Channel` (+ `logoURL`, `displayName`), `GetLiveDataResultData`,
  `LiveColumn` / `LiveColumnContentsResultData` (category tree), `LiveAddress`,
  `StartPlayLiveResultData`, `SlbInfoData`/`SlbCdn`/`SlbUrl`.
- `PlayableStream.swift`: `StreamSource` (url + headers) and `PlayableStream`
  (title, sources, isLive, channel, columnId).

## 10. Features / UI — `Features/` + `App/`

Three tabs (`Router.AppTab`, hosted by `RootTabView`):
1. **Categories** (`HomeView`, icon `list.bullet`, title "Categories") — a plain list of the 38 live
   categories with per‑category channel counts; tap → `CategoryChannelsView` (searchable grid,
   scoped to that category, PIN‑gated for 18+).
2. **Channels** (`LiveView`) — the full ~1036‑channel grid, search‑by‑name (client‑side over
   `allChannels`), 3 columns, no channel numbers.
3. **Favorites** (`FavoritesView`) — locally‑saved channels.

Shared: `ChannelGridView` + `LiveChannelCard` (logo, name, favorite heart) and the `.livePlayer`
modifier (`LiveComponents.swift`). Design tokens in `DesignSystem/Theme.swift`.

**Branding/colors:** single accent = mid red‑orange `Theme.accent` for flat UI (tab tint, buttons,
spinners); `Theme.brandGradient` (red→orange) for the app icon, splash, favorite heart, subtitle &
parental icons, PIN dots. App display name / splash / icon are all "Channels"
(`CFBundleDisplayName`, `AppConfig.appName`, `Assets.xcassets/AppIcon`).

## 11. Parental control — `Core/Services/ParentalControl.swift` + `Features/Parental/`

- `@Observable` singleton, persisted in UserDefaults (`parental.enabled`, `parental.pin`).
- Shield icon in the Categories nav bar → `ParentalControlView` (toggle + "Pin code" row).
  Turning ON needs a PIN; turning OFF (and changing the PIN) requires entering the current PIN.
- **Gating:** any channel with `restricted != "0"` requires the PIN at **play** time (from any
  tab/category); the **18+** category also hides its whole listing behind the PIN. A correct PIN
  grants a **60‑second global unlock** (`grantTemporaryUnlock`), so back‑and‑forth doesn't re‑prompt.
- `PinViews.swift`: custom 6‑digit keypad (`PinPadView`) with light‑haptic key ticks, an error haptic
  + "no" shake on a wrong PIN, and a lighter pressed‑state per key.

## 12. Adding things — quick guide

- **New portal call:** add the path to `Endpoints.swift`, a `Decodable` result model, and a method on
  `ContentService` calling `PortalClient.shared.call(...)`. Common params + crypto + session are automatic.
- **New live‑data surface:** extend `LiveStore` (respect the disk cache + never cache empty).
- **New player capability:** edit `PlayerView`/`LivePlayback`. Remember VLC delegate callbacks are
  off‑main; auth headers only work on the m3u8 via `LocalStreamProxy`.
- **Config/secret change:** `AppConfig.swift`.
- **Don't** reintroduce two FFmpeg‑bearing libs (VLC + FFmpeg‑iOS/KSPlayer) in one binary — they
  collide on `libav*` symbols and crash.

## 13. Known limitations

- No native PiP / AirPlay video (VLC constraint; only background audio + screen mirroring).
- VOD (movies/shows) not supported (proprietary P2P delivery).
- Shared single‑device account: one active session at a time.
- `Info.plist` sets `NSAllowsArbitraryLoads` (the live CDN + local proxy are cleartext HTTP).
