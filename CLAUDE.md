# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Hazel is a free/open-source macOS menu-bar app that plays a video on loop as a live desktop wallpaper. Pure Swift/SwiftUI + AppKit, no external dependencies, no SPM packages, single Xcode target.

## Build & run

No CLI test suite or lint config exists in this repo — build/run through Xcode:

```bash
open hazel.xcodeproj
```

- Scheme/target: `hazel` (bundle id `com.live.hazel`)
- Deployment target: macOS 26.2, Swift 5.0
- `xcodebuild` requires a full Xcode install (not just Command Line Tools) to build this project — `xcode-select -p` must point at `/Applications/Xcode.app/...`, not `CommandLineTools`.
- There is no test target. Do not add one unless asked.

## Architecture

The app has no main window — it's entirely menu-bar driven, wired up in `AppDelegate` (`LiveWallpaperApp.swift`). Everything flows from three collaborating objects created in `applicationDidFinishLaunching`:

- **`WallpaperStore`** (`WallpaperStore.swift`) — the model/persistence layer. Owns the `[WallpaperItem]` library, persisted as JSON at `~/Library/Application Support/LiveWallpaper/wallpapers.json`. Imported videos are *copied* into `.../LiveWallpaper/Videos/` (not referenced in place), and a thumbnail PNG is generated synchronously (via `AVAssetImageGenerator` + a `DispatchSemaphore`) into `~/Library/Caches/LiveWallpaper/Thumbnails/`. The active wallpaper's ID is persisted separately in `UserDefaults`.
- **`WallpaperController`** (`WallpaperController.swift`) — the runtime/presentation layer. For each `NSScreen`, it owns one `WallpaperWindow` + `VideoPlayerView` pair (keyed by screen in a dictionary), and keeps that set in sync with `NSApplication.didChangeScreenParametersNotification` (monitor connect/disconnect). It also pauses/resumes playback on `NSWorkspace` sleep/wake notifications so the video doesn't keep decoding while the display is off.
- **`VideoPlayerView`** (`VideoPlayerView.swift`) — an `NSView` wrapping `AVQueuePlayer` + `AVPlayerLayer`. Looping uses `AVPlayerLooper`, not a manual seek-to-zero. `SettingsManager.shared.wallpaperFit` is read at load time to set `AVLayerVideoGravity`.
- **`WallpaperWindow`** (`WallpaperWindow.swift`) — a borderless `NSWindow` pinned just above the desktop icons layer (`CGWindowLevelForKey(.desktopWindow) + 1`), spans all Spaces (`canJoinAllSpaces`), ignores mouse events, and can never become key/main — this is what makes it read as "wallpaper" rather than a normal window.

Settings (`SettingsManager.swift`, an `@Observable` singleton) persist to `UserDefaults` and cover wallpaper fit (fill/fit/center/stretch) and launch-at-login (via `SMAppService`, macOS 13+ API).

`ManagementView.swift` is the SwiftUI library UI (grid of `WallpaperCard.swift` items) shown when the menu-bar icon is clicked; it drives `WallpaperStore`/`WallpaperController` via `@ObservedObject`, not by reaching into `AppDelegate`.

A custom pixel font (`GeistPixel-Square.otf` in `Resources/Fonts/`) is manually registered at launch via `CTFontManagerRegisterGraphicsFont` (Asset Catalog font registration is not used) and exposed through `Font`/`Text` extensions in `GeistFont.swift`.

## Key constraints

- **App Sandbox is on** (`hazel.entitlements`): `com.apple.security.app-sandbox` + `com.apple.security.files.user-selected.read-only`. Any new file access outside the sandbox (beyond user-selected video imports via the security-scoped `NSOpenPanel`/file importer flow) needs a matching entitlement.
- Video URLs from `WallpaperStore` are resolved through security-scoped resource APIs (`startAccessingSecurityScopedResource`/`stopAccessingSecurityScopedResource`) — since videos are copied into app-owned storage rather than bookmarked, this scoping is mostly relevant at import time and should be preserved if that copy-on-import behavior changes.
- Screen/display handling must go through `WallpaperController`'s screen-diffing logic (`handleScreenChange`) — don't create `WallpaperWindow`s ad hoc elsewhere, or external-display connect/disconnect will leak or duplicate windows.
