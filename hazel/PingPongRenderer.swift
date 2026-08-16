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

    /// Reads every frame, then writes them out forward followed by reversed.
    ///
    /// Frames are held as CVPixelBuffers, so memory scales with the clip. That is
    /// acceptable for wallpaper-length videos and is why this is a deliberate,
    /// user-triggered action rather than something that runs automatically.
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
        let frameRate = nominalFrameRate > 0 ? nominalFrameRate : 30
        let frameDuration = CMTime(seconds: 1.0 / Double(frameRate), preferredTimescale: 600)

        guard let reader = try? AVAssetReader(asset: asset) else { throw RenderError.cannotRead }
        let readerOutput = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        )
        guard reader.canAdd(readerOutput) else { throw RenderError.cannotRead }
        reader.add(readerOutput)

        guard let writer = try? AVAssetWriter(outputURL: destination, fileType: .mov) else {
            throw RenderError.cannotWrite
        }
        let writerInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: Int(abs(naturalSize.width)),
                AVVideoHeightKey: Int(abs(naturalSize.height)),
            ]
        )
        writerInput.expectsMediaDataInRealTime = false
        writerInput.transform = transform

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: nil
        )
        guard writer.canAdd(writerInput) else { throw RenderError.cannotWrite }
        writer.add(writerInput)

        // Pass 1: collect every frame.
        reader.startReading()
        var frames: [CVPixelBuffer] = []
        while let sample = readerOutput.copyNextSampleBuffer() {
            if let buffer = CMSampleBufferGetImageBuffer(sample) {
                frames.append(buffer)
            }
        }
        guard reader.status == .completed, !frames.isEmpty else { throw RenderError.cannotRead }

        // Pass 2: write forward, then backward. The last forward frame is not
        // repeated as the first reverse frame — that would visibly stutter at
        // the turnaround.
        let ordered = frames + frames.dropLast().reversed()
        let total = Float(ordered.count)

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var index = 0
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.live.hazel.pingpong-render")
            writerInput.requestMediaDataWhenReady(on: queue) {
                while writerInput.isReadyForMoreMediaData {
                    guard index < ordered.count else {
                        writerInput.markAsFinished()
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                let detail = writer.error?.localizedDescription ?? "The render didn't finish."
                                continuation.resume(throwing: RenderError.writeFailed(detail))
                            }
                        }
                        return
                    }

                    let time = CMTimeMultiply(frameDuration, multiplier: Int32(index))
                    if !adaptor.append(ordered[index], withPresentationTime: time) {
                        let detail = writer.error?.localizedDescription ?? "Couldn't write a frame."
                        continuation.resume(throwing: RenderError.writeFailed(detail))
                        return
                    }
                    index += 1
                    progress(Float(index) / total)
                }
            }
        }

        log.info("rendered ping-pong: \(ordered.count) frames")
    }
}
