import AppKit
import AVFoundation
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

    /// Serializes all mutating work. Callers can fire syncs in quick succession
    /// (importing several files at once calls addWallpaper per file), and each sync
    /// is a full read-modify-write of a shared manifest plus writes to shared output
    /// paths — running two at once corrupts both.
    private let workQueue = DispatchQueue(label: "com.live.hazel.wallpaper-store-registrar")

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

    // MARK: - Video preparation

    /// Writes `aerials/videos/<item.id>.mov`: the source video stream copied
    /// verbatim plus a silent audio track.
    ///
    /// The silent track is not cosmetic — the wallpaper pipeline refuses to play
    /// an asset with no audio track at all. The video stream is passed through,
    /// so this costs about a second rather than a full transcode.
    ///
    /// Skipped when an up-to-date prepared file already exists.
    func prepareVideo(for item: WallpaperItem) -> URL? {
        try? fileManager.createDirectory(at: videosURL, withIntermediateDirectories: true)
        let destination = videosURL.appendingPathComponent("\(item.id.uuidString).mov")

        guard fileManager.fileExists(atPath: item.url.path) else {
            log.error("source video missing for \(item.title, privacy: .public)")
            return nil
        }

        if isUpToDate(destination: destination, source: item.url) {
            return destination
        }

        try? fileManager.removeItem(at: destination)

        let asset = AVURLAsset(url: item.url)
        let composition = AVMutableComposition()

        guard let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                           preferredTrackID: kCMPersistentTrackID_Invalid) else {
            log.error("could not build composition for \(item.title, privacy: .public)")
            return nil
        }

        // AVFoundation's modern loading APIs are async; the callers here are
        // synchronous, so bridge with a semaphore as WallpaperStore already does
        // for thumbnail generation.
        var success = false
        let semaphore = DispatchSemaphore(value: 0)

        Task {
            do {
                let duration = try await asset.load(.duration)
                guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else {
                    self.log.error("no video track in \(item.title, privacy: .public)")
                    semaphore.signal()
                    return
                }
                let range = CMTimeRange(start: .zero, duration: duration)
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: .zero)

                // A real silent track, not insertEmptyTimeRange — an empty range does
                // not survive passthrough export and yields an audio-less file, which
                // the wallpaper pipeline refuses to play. Proven by the Task 1 spike.
                let silenceURL = try self.makeSilentAudioFile(seconds: CMTimeGetSeconds(duration))
                defer { try? self.fileManager.removeItem(at: silenceURL) }
                let silence = AVURLAsset(url: silenceURL)
                guard let silentTrack = try await silence.loadTracks(withMediaType: .audio).first else {
                    self.log.error("could not synthesize silence for \(item.title, privacy: .public)")
                    semaphore.signal()
                    return
                }
                try audioTrack.insertTimeRange(range, of: silentTrack, at: .zero)

                guard let export = AVAssetExportSession(asset: composition,
                                                        presetName: AVAssetExportPresetPassthrough) else {
                    self.log.error("passthrough export unavailable for \(item.title, privacy: .public)")
                    semaphore.signal()
                    return
                }
                export.outputURL = destination
                export.outputFileType = .mov
                await export.export()
                success = export.status == .completed
                if !success {
                    self.log.error("export failed: \(String(describing: export.error), privacy: .public)")
                }
            } catch {
                self.log.error("prepare failed for \(item.title, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 120)

        guard success else {
            // A failed or timed-out export can leave a partial file behind. Left in
            // place, isUpToDate (mtime-only) would treat it as fresh and skip
            // regeneration forever, leaving a corrupt asset in Apple's store.
            try? fileManager.removeItem(at: destination)
            return nil
        }
        return destination
    }

    /// Writes a silent stereo LPCM file at least `seconds` long.
    ///
    /// The wallpaper pipeline will not play an asset with no audio track, and an
    /// empty composition track does not survive passthrough export — so real
    /// silent samples are required. The file is temporary; callers delete it once
    /// the export has consumed it.
    private func makeSilentAudioFile(seconds: Double) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hazel-silence-\(UUID().uuidString).caf")

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(44100)) else {
            throw CocoaError(.fileWriteUnknown)
        }
        buffer.frameLength = buffer.frameCapacity   // zero-filled == silence

        // Scoped so the file is flushed and closed before anything reads it back.
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            var written = 0.0
            while written < max(seconds, 1.0) {
                try file.write(from: buffer)
                written += 1.0
            }
        }

        return url
    }

    private func isUpToDate(destination: URL, source: URL) -> Bool {
        guard let destinationAttributes = try? fileManager.attributesOfItem(atPath: destination.path),
              let sourceAttributes = try? fileManager.attributesOfItem(atPath: source.path),
              let destinationDate = destinationAttributes[.modificationDate] as? Date,
              let sourceDate = sourceAttributes[.modificationDate] as? Date else {
            return false
        }
        return destinationDate >= sourceDate
    }

    // MARK: - Thumbnails

    /// Writes `aerials/thumbnails/<item.id>.png` from the video's frame at 2s.
    ///
    /// Deliberately separate from WallpaperStore's cached thumbnails: those live
    /// in ~/Library/Caches (purgeable, which would break the manifest's
    /// previewImage) and are 440x248, too small for System Settings' tiles.
    func prepareThumbnail(for item: WallpaperItem) -> URL? {
        try? fileManager.createDirectory(at: thumbnailsURL, withIntermediateDirectories: true)
        let destination = thumbnailsURL.appendingPathComponent("\(item.id.uuidString).png")

        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }

        let asset = AVURLAsset(url: item.url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1600, height: 900)

        var image: CGImage?
        let semaphore = DispatchSemaphore(value: 0)
        let preferred = CMTime(seconds: 2, preferredTimescale: 600)

        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: preferred)]) { _, cgImage, _, _, _ in
            image = cgImage
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)

        // Clips shorter than 2s yield nothing at that timestamp; fall back to frame zero.
        if image == nil {
            let fallbackSemaphore = DispatchSemaphore(value: 0)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cgImage, _, _, _ in
                image = cgImage
                fallbackSemaphore.signal()
            }
            _ = fallbackSemaphore.wait(timeout: .now() + 10)
        }

        guard let cgImage = image else {
            log.error("thumbnail generation failed for \(item.title, privacy: .public)")
            return nil
        }

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            log.error("PNG encoding failed for \(item.title, privacy: .public)")
            return nil
        }

        do {
            try pngData.write(to: destination)
            return destination
        } catch {
            // A partial write would be treated as a finished thumbnail by the
            // existence check above, permanently pointing Apple's manifest at a
            // corrupt PNG. Same guard as prepareVideo's failed-export path.
            try? fileManager.removeItem(at: destination)
            log.error("thumbnail write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    // MARK: - Manifest entries

    private func assetEntry(for item: WallpaperItem, video: URL, thumbnail: URL) -> [String: Any] {
        let assetID = item.id.uuidString
        let shotID = "CUSTOM_\(assetID.replacingOccurrences(of: "-", with: "_"))"
        return [
            "id": assetID,
            "categories": [Self.categoryID],
            "subcategories": [Self.subcategoryID],
            "pointsOfInterest": ["0": "\(shotID)_0"],
            "shotID": shotID,
            "includeInShuffle": true,
            "previewImage": thumbnail.absoluteString,
            "accessibilityLabel": item.title,
            "localizedNameKey": item.title,
            "preferredOrder": 0,
            "url-4K-SDR-240FPS": video.absoluteString,
            "showInTopLevel": true,
        ]
    }

    private func categoryEntry(representativeID: String, thumbnail: URL) -> [String: Any] {
        [
            "id": Self.categoryID,
            "localizedNameKey": Self.sectionName,
            "localizedDescriptionKey": Self.sectionDescription,
            "previewImage": thumbnail.absoluteString,
            "preferredOrder": 99,
            "representativeAssetID": representativeID,
            "subcategories": [[
                "id": Self.subcategoryID,
                "localizedNameKey": Self.sectionName,
                "localizedDescriptionKey": Self.sectionDescription,
                "preferredOrder": 0,
                "representativeAssetID": representativeID,
                "previewImage": thumbnail.absoluteString,
            ]],
        ]
    }

    // MARK: - Sync

    /// Enqueues a sync. Returns immediately; work runs serially in FIFO order, so the
    /// most recently requested library state is the one that lands last and wins.
    func sync(library: [WallpaperItem], activeID: UUID?) {
        workQueue.async { [weak self] in
            self?.performSync(library: library, activeID: activeID)
        }
    }

    /// Makes the store reflect `library` exactly. Idempotent — safe on every launch.
    private func performSync(library: [WallpaperItem], activeID: UUID?) {
        guard var manifest = readManifest() else { return }
        backupIfNeeded()

        let before = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])

        var assets = manifest["assets"] as? [[String: Any]] ?? []
        var categories = manifest["categories"] as? [[String: Any]] ?? []

        // Files are only ever deleted for assets Hazel itself registered. Proving
        // ownership from the filesystem is impossible: Hazel's layout was copied
        // from Backdrop, so Backdrop's own videos/thumbnails look identical.
        let previouslyRegistered = Set(assets.compactMap { asset -> String? in
            guard (asset["categories"] as? [String])?.contains(Self.categoryID) == true else { return nil }
            return asset["id"] as? String
        })

        // Drop everything Hazel previously added, so removals and renames take effect.
        assets.removeAll { ($0["categories"] as? [String])?.contains(Self.categoryID) == true }
        categories.removeAll { ($0["id"] as? String) == Self.categoryID }

        var registered: [(item: WallpaperItem, thumbnail: URL)] = []
        for item in library {
            guard let video = prepareVideo(for: item),
                  let thumbnail = prepareThumbnail(for: item) else {
                log.error("skipping \(item.title, privacy: .public) — preparation failed")
                continue
            }
            assets.append(assetEntry(for: item, video: video, thumbnail: thumbnail))
            registered.append((item, thumbnail))
        }

        if let representative = registered.first(where: { $0.item.id == activeID }) ?? registered.first {
            categories.append(categoryEntry(representativeID: representative.item.id.uuidString,
                                            thumbnail: representative.thumbnail))
        }

        manifest["assets"] = assets
        manifest["categories"] = categories

        let after = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        guard before != after else {
            log.info("wallpaper store already up to date")
            return
        }

        do {
            try writeManifest(manifest)
        } catch {
            log.error("manifest write failed: \(String(describing: error), privacy: .public)")
            return
        }

        // Keep files for everything still in the library — including items whose
        // preparation failed transiently this round. Deleting those would discard a
        // perfectly good prepared copy over a temporary error.
        removeOrphans(previouslyRegistered: previouslyRegistered,
                      keeping: Set(library.map { $0.id.uuidString }))
        reloadWallpaperAgent()
        log.info("registered \(registered.count) wallpapers")
    }

    /// Removes every Hazel entry and prepared file from the store.
    func removeAll() {
        workQueue.async { [weak self] in
            self?.performRemoveAll()
        }
    }

    private func performRemoveAll() {
        guard var manifest = readManifest() else { return }
        backupIfNeeded()

        let before = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])

        var assets = manifest["assets"] as? [[String: Any]] ?? []
        var categories = manifest["categories"] as? [[String: Any]] ?? []

        let previouslyRegistered = Set(assets.compactMap { asset -> String? in
            guard (asset["categories"] as? [String])?.contains(Self.categoryID) == true else { return nil }
            return asset["id"] as? String
        })

        assets.removeAll { ($0["categories"] as? [String])?.contains(Self.categoryID) == true }
        categories.removeAll { ($0["id"] as? String) == Self.categoryID }
        manifest["assets"] = assets
        manifest["categories"] = categories

        let after = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        guard before != after else {
            log.info("wallpaper store already empty")
            return
        }

        do {
            try writeManifest(manifest)
        } catch {
            log.error("manifest write failed: \(String(describing: error), privacy: .public)")
            return
        }

        removeOrphans(previouslyRegistered: previouslyRegistered, keeping: [])
        reloadWallpaperAgent()
    }

    /// Deletes prepared files for assets Hazel previously registered and no longer
    /// has in its library.
    ///
    /// Ownership comes from the manifest, never from the filesystem: this directory
    /// also holds Apple's downloaded aerials and other apps' assets (Backdrop keeps
    /// a 210 MB video here), and those are indistinguishable from Hazel's by name
    /// or by file layout — Hazel's layout was copied from Backdrop's.
    private func removeOrphans(previouslyRegistered: Set<String>, keeping ids: Set<String>) {
        for name in previouslyRegistered.subtracting(ids) {
            try? fileManager.removeItem(at: videosURL.appendingPathComponent("\(name).mov"))
            try? fileManager.removeItem(at: thumbnailsURL.appendingPathComponent("\(name).png"))
        }
    }

    /// WallpaperAgent caches the manifest; restarting it is the only reliable way
    /// to make changes visible. It relaunches automatically. Only called when the
    /// manifest actually changed, since a restart is user-visible.
    private func reloadWallpaperAgent() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["WallpaperAgent"]
        try? process.run()
    }

    // MARK: - Reading the current screen saver (read-only)

    /// macOS records the active screen saver here. Hazel only ever READS this file:
    /// writing it would mean editing the user's live wallpaper settings, which is
    /// out of scope and far riskier than anything in the aerials manifest.
    private var storeIndexURL: URL {
        RealHomeDirectory.url
            .appendingPathComponent("Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    /// Reports which wallpaper macOS currently has as the screen saver.
    ///
    /// `library` is passed in because the registrar does not own the library and
    /// otherwise could not tell a Hazel asset from another app's.
    func currentScreenSaverSelection(library: [WallpaperItem]) -> ScreenSaverSelection {
        guard let data = try? Data(contentsOf: storeIndexURL),
              let root = (try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil)) as? [String: Any] else {
            log.error("wallpaper store index unreadable at \(self.storeIndexURL.path, privacy: .public)")
            return .unknown
        }

        guard let scope = root["AllSpacesAndDisplays"] as? [String: Any],
              let idle = scope["Idle"] as? [String: Any],
              let content = idle["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let choice = choices.first,
              let provider = choice["Provider"] as? String else {
            log.error("wallpaper store index has an unexpected shape")
            return .unknown
        }

        guard provider == "com.apple.wallpaper.choice.aerials" else {
            return .notAnAerial
        }

        guard let assetID = Self.aerialAssetID(from: choice["Configuration"]),
              let uuid = UUID(uuidString: assetID) else {
            log.error("aerial choice carried no readable assetID")
            return .unknown
        }

        return library.contains(where: { $0.id == uuid }) ? .hazelWallpaper(uuid) : .otherApp
    }

    /// `Configuration` is stored as an embedded binary plist, but tolerate it
    /// already being a decoded dictionary — the shape is undocumented and may vary.
    private static func aerialAssetID(from configuration: Any?) -> String? {
        if let dictionary = configuration as? [String: Any] {
            return dictionary["assetID"] as? String
        }
        if let data = configuration as? Data,
           let dictionary = (try? PropertyListSerialization.propertyList(
               from: data, options: [], format: nil)) as? [String: Any] {
            return dictionary["assetID"] as? String
        }
        return nil
    }
}
