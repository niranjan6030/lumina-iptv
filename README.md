# Lumina — IPTV player for iPhone and CarPlay

Native Swift / SwiftUI. Liquid Glass on iOS 26, graceful material fallback on iOS 17–25.
Lumina ships **no channels**; you add your own M3U / Xtream provider.

## Status — what has and hasn't been verified

| Part | Verified how |
|---|---|
| `Packages/LuminaCore` (playlist + guide parsing, Xtream, search, failover helpers, user data) | 29 automated tests pass (`scripts/test-core.sh`), incl. a 60k-channel parse in 0.7 s and an end-to-end HTTP + gzip guide test |
| App model, player, all SwiftUI screens | Type-checked against the macOS 26 SDK (`scripts/typecheck-app-macos.sh`). **Not compiled for iOS, never run.** |
| UIKit bits (PiP layer, AirPlay button, share sheet, image loader), `@main`, notifications | Syntax-checked only |
| CarPlay scene (`App/CarPlay`) | Syntax-checked only. Needs Xcode + simulator/car |

Expect a handful of compile errors on the first Xcode build. They'll be small; paste them back and they get fixed.

## Setup (once)

1. Install **Xcode 26+** from the App Store, open it once, accept the licence.
2. `brew install xcodegen`
3. Edit `Config/Signing.xcconfig`: set `DEVELOPMENT_TEAM` (and change `LUMINA_BUNDLE_ID` if you like).
4. `xcodegen generate` → open `Lumina.xcodeproj` → run on your iPhone or a simulator.
5. First launch → **Try the demo first** to confirm playback works, then add your provider.

## CarPlay

* **Simulator (works today, no Apple approval needed):** run the app, then in the Simulator menu
  *I/O → External Displays → CarPlay*. Open Lumina on the CarPlay screen.
* **Real car:** Apple must grant a CarPlay entitlement to your developer account.
  1. Request it at <https://developer.apple.com/contact/carplay/> (paid Developer Program required).
  2. Suggested wording: *"Live TV and radio player for user-supplied playlists. Browse favorites/recents/groups,
     search, play with Now Playing controls (next/previous channel). Audio-only playback while driving."*
     Ask for **CarPlay Audio**, and also the **CarPlay Video** category if Apple's form offers it.
  3. When approved, in `Config/Signing.xcconfig` set `LUMINA_DEVICE_ENTITLEMENTS = App/Lumina.entitlements`,
     enable the capability on your App ID, re-run `xcodegen generate`, rebuild to the phone.
* Approval is Apple's decision and can take days or be declined for the audio category. Video on the car screen
  only works in cars that support "video in car", and (per Apple) only while parked; otherwise it falls back to audio.
  **CarPlay video is not implemented yet** — it needs the entitlement and Xcode's CarPlay headers to build against.

### What the CarPlay scene does
Tabs: Favorites · Recent · Browse (search + groups). Tap a channel → Now Playing with next/previous channel and a
favorite button. Audio-only by default (setting). Lists are capped and updated in place, artwork is 120 px and lazy.

## Features

Playlists: M3U/M3U8 links, files (also "Open in Lumina" from Files/Safari), Xtream Codes login. Pasting a provider's
`get.php?username=…` link auto-switches to the Xtream API.
Live TV: groups with region filter, favorites, recents, list/grid, now/next with progress, per-channel schedule,
catch-up/replay (Xtream timeshift + common M3U catch-up styles), reminders (local notifications), quality badges.
Playback: shared player for phone/lock screen/AirPlay/CarPlay, Picture in Picture, audio/subtitle track menu,
audio-only mode, sleep timer with fade, swipe up/down to change channel, resume where you left off.
Library: movies, series (seasons/episodes, auto-play next), continue watching, Xtream details.
Search: one box for channels, programmes airing in the next 36 h, movies and series.
Guide: XMLTV (plain or `.gz`), per-source time shift, extra guide URLs, cached for instant start.
Beyond the usual: **automatic failover to backup streams**, **duplicate-channel merging** (ESPN / ESPN HD / ESPN FHD
become one channel with fallbacks), **dead-channel scan**, parental PIN with per-group locks (also enforced in CarPlay),
adult-group hiding, backup/restore, friendly error messages.

## Known limits (honest list)
* AVPlayer cannot play raw MPEG-TS over HTTP. Xtream-style `.ts` links are tried as `.m3u8` first. Providers that only
  offer raw TS will fail until an FFmpeg/VLC engine is added behind `PlayerController` (planned seam).
* No full multi-channel timeline grid yet (per-channel schedule only).
* No iCloud sync (needs a capability); use Backup/Restore.
* Xtream passwords are stored in the app's sandbox, not the Keychain (yet).
* Android app: not started.

## Layout
```
Packages/LuminaCore/   pure Swift logic + tests (runs on macOS without Xcode)
App/Model/             AppModel (library, guide, user data), PlayerController, image loader
App/UI/                SwiftUI screens
App/CarPlay/           CarPlay scene + templates
Config/Signing.xcconfig, project.yml (XcodeGen), scripts/
```
