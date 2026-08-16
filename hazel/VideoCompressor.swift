import AVFoundation
import AppKit
import OSLog

/// Re-encodes a wallpaper video down to the resolution this Mac can actually
/// display, using HEVC for a materially smaller file at the same visual quality.
///
/// Uses AVFoundation rather than an external encoder: it is built in (Hazel ships
/// no dependencies), and on Apple Silicon it is hardware-accelerated.
enum VideoCompressor {
    private static let log = Logger(subsystem: "com.live.hazel", category: "compressor")

    struct Savings {
        let originalBytes: Int64
        let compressedBytes: Int64
        let originalSize: CGSize
        let compressedSize: CGSize

        var percentSaved: Int {
            guard originalBytes > 0 else { return 0 }
            return Int((1 - Double(compressedBytes) / Double(originalBytes)) * 100)
        }
    }

    enum Outcome {
        case compressed(Savings)
        /// Already at or below the target — re-encoding would cost quality for nothing.
        case alreadyOptimal(CGSize)
        case failed(String)
    }

    /// The largest pixel size any attached display can show.
    static func maxDisplayPixelSize() -> CGSize {
        NSScreen.screens.reduce(CGSize(width: 1920, height: 1080)) { largest, screen in
            let pixels = CGSize(width: screen.frame.width * screen.backingScaleFactor,
                                height: screen.frame.height * screen.backingScaleFactor)
            return pixels.width > largest.width ? pixels : largest
        }
    }

    /// Picks the smallest HEVC preset that still covers the display.
    ///
    /// Returns nil when the video is already no larger than the target, so the
    /// caller can skip rather than re-encode and lose quality for no saving.
    static func preset(for videoSize: CGSize, display: CGSize) -> String? {
        let longestVideoEdge = max(videoSize.width, videoSize.height)
        let longestDisplayEdge = max(display.width, display.height)

        guard longestVideoEdge > longestDisplayEdge * 1.1 else { return nil }

        if longestDisplayEdge <= 1920 { return AVAssetExportPresetHEVC1920x1080 }
        return AVAssetExportPresetHEVC3840x2160
    }

    static func videoSize(of url: URL) async -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let size = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform) else { return nil }
        let transformed = size.applying(transform)
        return CGSize(width: abs(transformed.width), height: abs(transformed.height))
    }

    static func fileSize(of url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Compresses `item`'s video in place.
    ///
    /// The re-encode goes to a temporary file and only replaces the original once
    /// it completes — a failure or a quit mid-export must never leave the user
    /// with a truncated wallpaper where their video used to be.
    static func compress(
        item: WallpaperItem,
        progress: @escaping (Float) -> Void,
        completion: @escaping (Outcome) -> Void
    ) {
        let source = item.url
        let display = maxDisplayPixelSize()

        Task {
            guard let size = await videoSize(of: source) else {
                await MainActor.run { completion(.failed("Couldn't read the video's dimensions.")) }
                return
            }

            guard let presetName = preset(for: size, display: display) else {
                await MainActor.run { completion(.alreadyOptimal(size)) }
                return
            }

            let asset = AVURLAsset(url: source)
            guard let export = AVAssetExportSession(asset: asset, presetName: presetName) else {
                await MainActor.run { completion(.failed("This Mac can't apply that compression preset.")) }
                return
            }

            let temporary = FileManager.default.temporaryDirectory
                .appendingPathComponent("hazel-compress-\(UUID().uuidString).mov")
            export.outputURL = temporary
            export.outputFileType = .mov

            let ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                progress(export.progress)
            }

            await export.export()
            ticker.invalidate()

            guard export.status == .completed else {
                try? FileManager.default.removeItem(at: temporary)
                let message = export.error?.localizedDescription ?? "The export didn't finish."
                log.error("compression failed: \(message, privacy: .public)")
                await MainActor.run { completion(.failed(message)) }
                return
            }

            let originalBytes = fileSize(of: source)
            let compressedBytes = fileSize(of: temporary)

            // Refuse a "compression" that made the file bigger — that happens on
            // already-efficient sources and would be a pure downgrade.
            guard compressedBytes > 0, compressedBytes < originalBytes else {
                try? FileManager.default.removeItem(at: temporary)
                await MainActor.run { completion(.alreadyOptimal(size)) }
                return
            }

            do {
                _ = try FileManager.default.replaceItemAt(source, withItemAt: temporary)
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                await MainActor.run { completion(.failed("Couldn't replace the original video.")) }
                return
            }

            let newSize = await videoSize(of: source) ?? size
            let savings = Savings(originalBytes: originalBytes,
                                  compressedBytes: compressedBytes,
                                  originalSize: size,
                                  compressedSize: newSize)
            log.info("compressed \(item.title, privacy: .public): saved \(savings.percentSaved)%")
            await MainActor.run { completion(.compressed(savings)) }
        }
    }
}
