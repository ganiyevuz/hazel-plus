import Foundation

struct WallpaperLibraryFile: Codable {
    var wallpapers: [WallpaperItem]
    var activeWallpaperID: UUID?
    var wallpaperFit: WallpaperFit
}
