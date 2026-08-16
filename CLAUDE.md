# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Hazel is a free/open-source macOS menu-bar app that plays a video on loop as a live desktop wallpaper, with a companion Screen Saver that plays the same video. Pure Swift/SwiftUI + AppKit, no external dependencies, no SPM packages. Two Xcode targets: `hazel` (the menu-bar app) and `HazelScreenSaver` (a legacy `ScreenSaverView`-based `.saver` plugin).

## Build & run

No CLI test suite or lint config exists in this repo — build/run through Xcode:

```bash
open hazel.xcodeproj
```

- Targets: `hazel` (bundle id `com.live.hazel`) and `HazelScreenSaver` (bundle id `com.live.hazel.screensaver`, builds `Hazel.saver`)
- Deployment target: macOS 26.2, Swift 5.0
- `xcodebuild` requires a full Xcode install (not just Command Line Tools) — `xcode-select -p` must point at an `Xcode.app`, not `CommandLineTools`. When it does, CLI builds work and are the fastest way to verify a change:
  ```bash
  xcodebuild -project hazel.xcodeproj -target hazel -configuration Debug build
  ```
  Building `hazel` also builds `HazelScreenSaver` first (target dependency) and embeds `Hazel.saver` into `hazel.app/Contents/Resources/`.
- Xcode 27's New Target wizard still offers a "Screen Saver" template, but it generates **Objective-C** (`.h`/`.m`) — the Swift implementation here replaced those template files.
- There is no test target. Do not add one unless asked.

## Architecture

The app has no main window — it's entirely menu-bar driven, wired up in `AppDelegate` (`LiveWallpaperApp.swift`). Everything flows from three collaborating objects created in `applicationDidFinishLaunching`:

- **`WallpaperStore`** (`WallpaperStore.swift`) — the model/persistence layer. Owns the `[WallpaperItem]` library, persisted as JSON at `~/Library/Application Support/LiveWallpaper/wallpapers.json`. Imported videos are *copied* into `.../LiveWallpaper/Videos/` (not referenced in place), and a thumbnail PNG is generated synchronously (via `AVAssetImageGenerator` + a `DispatchSemaphore`) into `~/Library/Caches/LiveWallpaper/Thumbnails/`. The active wallpaper's ID is persisted alongside the library in `wallpapers.json` (`WallpaperLibraryFile`), not in `UserDefaults`.
- **`WallpaperController`** (`WallpaperController.swift`) — the runtime/presentation layer. For each `NSScreen`, it owns one `WallpaperWindow` + `VideoPlayerView` pair (keyed by screen in a dictionary), and keeps that set in sync with `NSApplication.didChangeScreenParametersNotification` (monitor connect/disconnect). It also pauses/resumes playback on `NSWorkspace` sleep/wake notifications so the video doesn't keep decoding while the display is off.
- **`VideoPlayerView`** (`VideoPlayerView.swift`) — an `NSView` wrapping `AVQueuePlayer` + `AVPlayerLayer`. Looping uses `AVPlayerLooper`, not a manual seek-to-zero. `WallpaperStore.wallpaperFit` is passed into `loadVideo(url:isLooping:isMuted:fit:)` at load time to set `AVLayerVideoGravity`.
Playback logic shared between the desktop and the screen saver lives in `WallpaperPlayerCore.swift` (the `AVQueuePlayer`/`AVPlayerLooper`/`AVPlayerLayer` setup, with no `NSView` dependency) — `VideoPlayerView` and `HazelScreenSaverView` (`HazelScreenSaver/HazelScreenSaverView.swift`) both drive it. Note the ordering contract: `WallpaperPlayerCore.load(...)` deliberately does *not* start playback; callers attach `playerCore.layer` to their layer hierarchy first, then call `playerCore.play()`. The wallpaper library, active wallpaper ID, and fit setting are persisted together in one file (`WallpaperLibraryFile.swift`'s schema, written by `WallpaperStore`, read by both the main app and — via the read-only `WallpaperLibraryReader.swift` — the screen saver process, which runs as a separate bundle identity and can't share `UserDefaults` or a sandboxed container with the main app). `HazelScreenSaverView` reads the active wallpaper once per screen saver activation (a fresh process each time), not continuously.

`WallpaperStoreRegistrar.swift` publishes the library into macOS's aerial wallpaper store (`~/Library/Application Support/com.apple.wallpaper/aerials/`) so Hazel's videos appear as their own "Hazel" section in System Settings → Wallpaper → Screen Saver. It is the ONLY code that may touch Apple's `entries.json`, which it manipulates as untyped dictionaries so unmodelled Apple fields survive round-tripping. Each video is prepared into `aerials/videos/<itemID>.mov` with a silent audio track added (the pipeline will not play an asset that has no audio track) via passthrough export, so the video stream is never re-encoded. Note this uses `WallpaperItem.id`, which is NOT the UUID in the video's own filename. Prepared files are only ever deleted for assets Hazel itself registered — ownership is read back out of Hazel's own category in `entries.json`, never inferred from the filesystem, because this directory is shared with Apple's aerials and other apps (Backdrop keeps a 210 MB video here) whose files are indistinguishable from Hazel's by name or layout. The store cannot drive the desktop — Apple's aerials still on the desktop rather than looping — so continuous desktop playback remains `WallpaperWindow`'s job.

The five files shared between both targets are `WallpaperItem.swift`, `WallpaperFit.swift`, `WallpaperLibraryFile.swift`, `WallpaperLibraryReader.swift`, and `WallpaperPlayerCore.swift`. They live in `hazel/` and are pulled into `HazelScreenSaver` via a `PBXFileSystemSynchronizedBuildFileExceptionSet` in `project.pbxproj` (the synchronized-group equivalent of ticking a second Target Membership box). **`WallpaperFit` lives in its own `WallpaperFit.swift`, not in `SettingsManager.swift`** — it was extracted precisely so the saver can use it without dragging in `SettingsManager`'s `ServiceManagement`/`SMAppService` login-item code. If you add a new type that the saver needs, give it its own file and add it to that exception set.

- **`WallpaperWindow`** (`WallpaperWindow.swift`) — a borderless `NSWindow` pinned just above the desktop icons layer (`CGWindowLevelForKey(.desktopWindow) + 1`), spans all Spaces (`canJoinAllSpaces`), ignores mouse events, and can never become key/main — this is what makes it read as "wallpaper" rather than a normal window.

Settings (`SettingsManager.swift`, an `@Observable` singleton) persist to `UserDefaults` and cover wallpaper fit (fill/fit/center/stretch) and launch-at-login (via `SMAppService`, macOS 13+ API).

`ManagementView.swift` is the SwiftUI library UI (grid of `WallpaperCard.swift` items) shown when the menu-bar icon is clicked; it drives `WallpaperStore`/`WallpaperController` via `@ObservedObject`, not by reaching into `AppDelegate`.

A custom pixel font (`GeistPixel-Square.otf` in `Resources/Fonts/`) is manually registered at launch via `CTFontManagerRegisterGraphicsFont` (Asset Catalog font registration is not used) and exposed through `Font`/`Text` extensions in `GeistFont.swift`.

## Key constraints

- **App Sandbox is off** — and it takes *two* things to keep it off. `hazel.entitlements` is an empty dict, **and** the `hazel` target sets `ENABLE_APP_SANDBOX = NO` / `ENABLE_USER_SELECTED_FILES = none`. Xcode 16+ synthesizes entitlements from those build settings and merges them into the signed app, so emptying the entitlements file alone leaves the app sandboxed. Verify with `codesign -d --entitlements - build/Debug/hazel.app` — it should show no `com.apple.security.app-sandbox` key. This is required, not optional: `HazelScreenSaver` runs as a separate process/bundle identity and cannot read a sandboxed container, and a sandboxed app's `homeDirectoryForCurrentUser` silently resolves to the container, so the saver would install to the wrong place with no error. The app is direct-download/notarized distribution, not App Store-eligible. See `docs/superpowers/specs/2026-08-03-screen-saver-support-design.md`.
- The app copies `Hazel.saver` from its own bundle into `~/Library/Screen Savers/` on every launch (`AppDelegate.installScreenSaverIfNeeded()`), overwriting any existing copy so the installed saver always matches the running app version.
- Screen/display handling must go through `WallpaperController`'s screen-diffing logic (`handleScreenChange`) — don't create `WallpaperWindow`s ad hoc elsewhere, or external-display connect/disconnect will leak or duplicate windows.
