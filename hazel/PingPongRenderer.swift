import AppKit
import AVFoundation
import OSLog

/// Renders a "forward then backward" copy of a video, once, so ping-pong
/// playback is just ordinary looping of an ordinary file.
///
/// Playing a video backwards in real time is inherently slow: H.264/HEVC store
/// most frames as differences from *earlier* frames, so showing frame N while
/// reversing means decoding from the previous keyframe forward to N — for every
/// frame. That costs roughly an order of magnitude and drops to single-digit fps.
///
/// Pre-rendering sidesteps it completely: the reversed footage is written out
/// once, and playback only ever moves forward.
enum PingPongRenderer {
    private static let log = Logger(subsystem: "com.live.hazel", category: "pingpong")

    enum Outcome {
        case rendered(URL)
        case failed(String)
    }

    /// Where a rendered ping-pong copy lives for a given library item.
    static func renderedURL(for item: WallpaperItem) -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory = caches.appendingPathComponent("LiveWallpaper/PingPong", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(item.id.uuidString).mov")
    }

    /// Deletes the rendered copy for a wallpaper that no longer exists.
    ///
    /// These are full video files — leaving one behind for every deleted
    /// wallpaper would quietly consume gigabytes.
    static func discardRender(for item: WallpaperItem) {
        try? FileManager.default.removeItem(at: renderedURL(for: item))
    }

    /// True when a usable render already exists and is newer than the source.
    static func hasCurrentRender(for item: WallpaperItem) -> Bool {
        let rendered = renderedURL(for: item)
        let manager = FileManager.default
        guard manager.fileExists(atPath: rendered.path),
              let renderedDate = try? manager.attributesOfItem(atPath: rendered.path)[.modificationDate] as? Date,
              let sourceDate = try? manager.attributesOfItem(atPath: item.url.path)[.modificationDate] as? Date
        else { return false }
        return renderedDate >= sourceDate
    }

    static func render(
        item: WallpaperItem,
        progress: @escaping (Float) -> Void,
        completion: @escaping (Outcome) -> Void
    ) {
        let source = item.url
        let destination = renderedURL(for: item)

        Task.detached(priority: .userInitiated) {
            do {
                try await renderPingPong(from: source, to: destination) { fraction in
                    Task { @MainActor in progress(fraction) }
                }
                await MainActor.run { completion(.rendered(destination)) }
            } catch {
                try? FileManager.default.removeItem(at: destination)
                let message = error.localizedDescription
                log.error("ping-pong render failed: \(message, privacy: .public)")
                await MainActor.run { completion(.failed(message)) }
            }
        }
    }

    private enum RenderError: LocalizedError {
        case noVideoTrack
        case cannotRead
        case cannotWrite
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "That file has no video track."
            case .cannotRead: return "Couldn't read the video."
            case .cannotWrite: return "Couldn't create the reversed copy."
            case .writeFailed(let detail): return detail
            }
        }
    }

    /// Writes the video out forward, then reversed, without ever holding the
    /// whole clip in memory.
    ///
    /// The forward half streams frame-by-frame. The reverse half can't stream —
    /// it needs frames in the opposite order to the decoder's — so it walks the
    /// clip backwards one short window at a time, buffering only that window.
    ///
    /// This matters more than it looks: buffering every frame of a 20-second 4K
    /// clip as BGRA is roughly 20 GB resident, which would swap-thrash or fail
    /// outright. Windowing keeps it near-constant regardless of clip length.
    ///
    /// Frames are also capped at the largest attached display, since a wallpaper
    /// is never shown at more than that.

    /// Caps a render at the largest attached display, preserving aspect ratio.
    private static func outputSize(for natural: CGSize) -> CGSize {
        let maxEdge = NSScreen.screens.reduce(1920.0) { largest, screen in
            Swift.max(largest, Swift.max(screen.frame.width, screen.frame.height) * screen.backingScaleFactor)
        }
        let longest = Swift.max(abs(natural.width), abs(natural.height))
        guard longest > maxEdge else {
            return CGSize(width: abs(natural.width).rounded(), height: abs(natural.height).rounded())
        }
        let scale = maxEdge / longest
        // Even dimensions: HEVC encoders reject odd ones.
        return CGSize(width: (abs(natural.width) * scale / 2).rounded() * 2,
                      height: (abs(natural.height) * scale / 2).rounded() * 2)
    }

    /// Decoded frames for a time range, scaled to `size`, delivered one at a time.
    private static func frames(
        of asset: AVURLAsset,
        track: AVAssetTrack,
        range: CMTimeRange?,
        size: CGSize
    ) -> AsyncThrowingStream<CVPixelBuffer, Error> {
        AsyncThrowingStream { continuation in
            do {
                let reader = try AVAssetReader(asset: asset)
                if let range { reader.timeRange = range }
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: Int(size.width),
                    kCVPixelBufferHeightKey as String: Int(size.height),
                ])
                guard reader.canAdd(output) else { throw RenderError.cannotRead }
                reader.add(output)
                reader.startReading()

                while let sample = output.copyNextSampleBuffer() {
                    if let buffer = CMSampleBufferGetImageBuffer(sample) {
                        continuation.yield(buffer)
                    }
                }
                guard reader.status == .completed else { throw RenderError.cannotRead }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    private static func renderPingPong(
        from source: URL,
        to destination: URL,
        progress: @escaping (Float) -> Void
    ) async throws {
        try? FileManager.default.removeItem(at: destination)

        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw RenderError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let nominalFrameRate = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let frameRate = nominalFrameRate > 0 ? Double(nominalFrameRate) : 30
        let frameDuration = CMTime(seconds: 1.0 / frameRate, preferredTimescale: 600)

        // Never render larger than the biggest display can show.
        let output = outputSize(for: naturalSize)

        guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .mov) else {
            throw RenderError.cannotWrite
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(output.width),
                AVVideoHeightKey: Int(output.height),
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(writerInput) else { throw RenderError.cannotWrite }
        writer.add(writerInput)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let totalSeconds = duration.seconds
        let totalFrames = max(Int(totalSeconds * frameRate), 1)
        var written = 0

        func append(_ buffer: CVPixelBuffer) throws {
            while !writerInput.isReadyForMoreMediaData {
                usleep(5_000)
            }
            let time = CMTimeMultiply(frameDuration, multiplier: Int32(written))
            guard adaptor.append(buffer, withPresentationTime: time) else {
                throw RenderError.writeFailed(
                    writer.error?.localizedDescription ?? "Couldn't write a frame.")
            }
            written += 1
            progress(min(Float(written) / Float(totalFrames * 2), 1))
        }

        // Forward half: stream straight through, one frame resident at a time.
        for try await buffer in frames(of: asset, track: track, range: nil, size: output) {
            try append(buffer)
        }

        // Reverse half: walk backwards a window at a time so memory stays bounded
        // no matter how long the clip is.
        let window = 1.0
        var end = totalSeconds
        while end > 0 {
            let start = Swift.max(end - window, 0)
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: end - start, preferredTimescale: 600))

            var chunk: [CVPixelBuffer] = []
            for try await buffer in frames(of: asset, track: track, range: range, size: output) {
                chunk.append(buffer)
            }
            // Skip the frame that ends the forward pass, or the turnaround stutters.
            if end == totalSeconds { chunk = chunk.dropLast() }
            for buffer in chunk.reversed() {
                try append(buffer)
            }
            end = start
        }

        writerInput.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw RenderError.writeFailed(
                writer.error?.localizedDescription ?? "The render didn't finish.")
        }

        log.info("rendered ping-pong: \(written) frames at \(Int(output.width))x\(Int(output.height))")
    }
}
