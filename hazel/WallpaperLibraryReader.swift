import Foundation

enum WallpaperLibraryReader {
    struct Selection {
        let url: URL
        let isLooping: Bool
        let isMuted: Bool
        let fit: WallpaperFit
    }

    private static var storageURL: URL {
        RealHomeDirectory.url.appendingPathComponent("Library/Application Support/LiveWallpaper/wallpapers.json")
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
