import Foundation
import OSLog

/// Registers Hazel's videos into macOS's aerial wallpaper store so they appear
/// as their own section in System Settings → Wallpaper → Screen Saver.
///
/// This is the ONLY type permitted to read or write Apple's manifest. The format
/// is undocumented and Apple-owned, so all of that fragility is quarantined here.
///
/// The manifest is manipulated as untyped dictionaries on purpose: it holds ~163
/// Apple assets with fields this project does not model, and typed round-tripping
/// would silently drop every unknown key.
final class WallpaperStoreRegistrar {
    static let shared = WallpaperStoreRegistrar()

    static let categoryID = "FADE0000-0000-4000-8000-000000000001"
    static let subcategoryID = "FADE0000-0000-4000-8000-000000000002"
    static let sectionName = "Hazel"
    static let sectionDescription = "Use Hazel to add and manage live wallpapers"

    private let log = Logger(subsystem: "com.live.hazel", category: "store-registrar")
    private let fileManager = FileManager.default

    private var aerialsURL: URL {
        RealHomeDirectory.url
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/aerials", isDirectory: true)
    }

    private var entriesURL: URL {
        aerialsURL.appendingPathComponent("manifest/entries.json")
    }

    private var backupURL: URL {
        aerialsURL.appendingPathComponent("manifest/entries.json.hazel-backup")
    }

    private var videosURL: URL {
        aerialsURL.appendingPathComponent("videos", isDirectory: true)
    }

    private var thumbnailsURL: URL {
        aerialsURL.appendingPathComponent("thumbnails", isDirectory: true)
    }

    // MARK: - Manifest I/O

    /// Returns nil when the store does not exist (a Mac that never downloaded
    /// aerials) or the manifest cannot be parsed. Callers must abort rather than
    /// write, so a bad parse can never clobber Apple's file.
    func readManifest() -> [String: Any]? {
        guard fileManager.fileExists(atPath: entriesURL.path) else {
            log.info("no aerial manifest at \(self.entriesURL.path, privacy: .public) — skipping")
            return nil
        }
        guard let data = try? Data(contentsOf: entriesURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.error("aerial manifest unparseable — leaving it untouched")
            return nil
        }
        return object
    }

    /// Copies the pristine manifest aside once, before Hazel ever modifies it.
    func backupIfNeeded() {
        guard !fileManager.fileExists(atPath: backupURL.path) else { return }
        try? fileManager.copyItem(at: entriesURL, to: backupURL)
    }

    func writeManifest(_ manifest: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        let temporaryURL = entriesURL.appendingPathExtension("hazel-tmp")
        try data.write(to: temporaryURL)
        _ = try fileManager.replaceItemAt(entriesURL, withItemAt: temporaryURL)
    }
}
