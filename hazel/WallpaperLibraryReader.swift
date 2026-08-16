import Foundation

enum WallpaperLibraryReader {
    struct Selection {
        let url: URL
        let isLooping: Bool
        let isMuted: Bool
        let fit: WallpaperFit
    }

    /// The user's real home directory, bypassing any sandbox container redirection.
    ///
    /// The screen saver is loaded into Apple's `legacyScreenSaver` app extension, which
    /// is sandboxed (container `com.apple.ScreenSaver.Engine.legacyScreenSaver`) even
    /// though Hazel itself is not. Inside it, `NSHomeDirectory()` and
    /// `FileManager.urls(for:in:)` resolve to *that extension's* container, so they
    /// never find `~/Library/Application Support/LiveWallpaper`. The passwd database
    /// still reports the real home, and the extension holds a read-only exception for
    /// `/`, so an absolute path built this way reads fine from both processes.
    private static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()) {
            let dir = String(cString: pw.pointee.pw_dir)
            if !dir.isEmpty {
                return URL(fileURLWithPath: dir, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    private static var storageURL: URL {
        realHomeDirectory.appendingPathComponent("Library/Application Support/LiveWallpaper/wallpapers.json")
    }

    static func currentSelection() -> Selection? {
        guard let data = try? Data(contentsOf: storageURL),
              let file = try? JSONDecoder().decode(WallpaperLibraryFile.self, from: data),
              let activeID = file.activeWallpaperID,
              let item = file.wallpapers.first(where: { $0.id == activeID }),
              FileManager.default.fileExists(atPath: item.url.path) else {
            return nil
        }
        return Selection(url: item.url, isLooping: item.isLooping, isMuted: item.isMuted, fit: file.wallpaperFit)
    }
}
