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
            log.error("thumbnail write failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
