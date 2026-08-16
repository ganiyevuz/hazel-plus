import AppKit
import AVFoundation
import OSLog

/// Keeps the *real* macOS desktop picture in sync with the active wallpaper video.
///
/// Hazel paints a borderless window just above the desktop picture rather than
/// replacing it, so whatever the user set as their desktop is always sitting
/// underneath. macOS composites that desktop on its own during Space switches,
/// before Hazel's window is drawn into the destination Space — which is why a
/// swipe briefly reveals the old picture and then the video appears.
///
/// The gap is macOS's compositing and cannot be prevented from an app. What can
/// be fixed is *what shows through*: setting the desktop picture to a still frame
/// of the same video makes the gap invisible.
///
/// Uses the public `NSWorkspace.setDesktopImageURL` API — Apple's private
/// wallpaper store is never written.
final class DesktopPictureBridge {
    static let shared = DesktopPictureBridge()

    private let log = Logger(subsystem: "com.live.hazel", category: "desktop-picture")
    private let fileManager = FileManager.default
    /// Serial so two rapid wallpaper switches can't extract frames concurrently.
    private let workQueue = DispatchQueue(label: "com.live.hazel.desktop-picture", qos: .utility)

    /// The user's own desktop picture per display, remembered so it can be put
    /// back. Persisted because a crash must not cost the user their setting.
    private static let savedOriginalsKey = "originalDesktopImageURLs"

    private var framesURL: URL {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let directory = caches.appendingPathComponent("LiveWallpaper/DesktopFrames", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - Public API

    /// Sets every screen's desktop picture to a still frame of `item`'s video.
    ///
    /// Returns immediately. Extracting a full-resolution frame takes long enough
    /// that doing it inline would freeze the UI — this is called from
    /// `setWallpaper`, which runs on the main thread every time a card is tapped.
    func apply(item: WallpaperItem) {
        // Screen state must be read on the main thread; the decode must not be.
        let targets: [(screen: NSScreen, size: CGSize)] = NSScreen.screens.map {
            ($0, pixelSize(of: $0))
        }
        rememberOriginalsIfNeeded()

        workQueue.async { [weak self] in
            guard let self else { return }
            for target in targets {
                guard let frameURL = self.stillFrame(for: item, sized: target.size) else { continue }
                DispatchQueue.main.async {
                    do {
                        try NSWorkspace.shared.setDesktopImageURL(frameURL, for: target.screen, options: [:])
                    } catch {
                        self.log.error("couldn't set desktop picture: \(String(describing: error), privacy: .public)")
                    }
                }
            }
        }
    }

    /// Deletes cached still frames for a wallpaper that no longer exists.
    ///
    /// Frames are named `<item id>-<width>x<height>.png`, so one wallpaper can
    /// have several (one per display size it has been shown on).
    func discardFrames(for item: WallpaperItem) {
        let prefix = item.id.uuidString
        guard let files = try? fileManager.contentsOfDirectory(at: framesURL,
                                                               includingPropertiesForKeys: nil) else { return }
        for file in files where file.lastPathComponent.hasPrefix(prefix) {
            try? fileManager.removeItem(at: file)
        }
    }

    /// Puts the user's own desktop picture back on every screen.
    func restore() {
        guard let saved = UserDefaults.standard.dictionary(forKey: Self.savedOriginalsKey) as? [String: String] else {
            return
        }

        for screen in NSScreen.screens {
            guard let key = screenKey(for: screen),
                  let path = saved[key],
                  let url = URL(string: path) else { continue }
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            } catch {
                log.error("couldn't restore desktop picture: \(String(describing: error), privacy: .public)")
            }
        }

        UserDefaults.standard.removeObject(forKey: Self.savedOriginalsKey)
    }

    // MARK: - Remembering the user's picture

    /// Records the current desktop picture per display, once.
    ///
    /// Re-recording later would capture a frame Hazel itself installed and
    /// destroy the only copy of the user's real setting — the same trap as
    /// overwriting a backup with already-modified content.
    private func rememberOriginalsIfNeeded() {
        guard UserDefaults.standard.dictionary(forKey: Self.savedOriginalsKey) == nil else { return }

        var originals: [String: String] = [:]
        for screen in NSScreen.screens {
            guard let key = screenKey(for: screen),
                  let current = NSWorkspace.shared.desktopImageURL(for: screen) else { continue }
            // Never record one of our own frames as if it were the user's.
            guard !current.path.hasPrefix(framesURL.path) else { continue }
            originals[key] = current.absoluteString
        }

        guard !originals.isEmpty else { return }
        UserDefaults.standard.set(originals, forKey: Self.savedOriginalsKey)
        log.info("remembered \(originals.count) original desktop picture(s)")
    }

    private func screenKey(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
        return number.stringValue
    }

    private func pixelSize(of screen: NSScreen) -> CGSize {
        CGSize(width: screen.frame.width * screen.backingScaleFactor,
               height: screen.frame.height * screen.backingScaleFactor)
    }

    // MARK: - Frame extraction

    /// A full-resolution still from the video, cached per item and size.
    ///
    /// Deliberately not the library thumbnail: those are 1600x900 and sized for
    /// tiles, so stretching one across a Retina display would look obviously soft
    /// at exactly the moment this is meant to be unnoticeable.
    private func stillFrame(for item: WallpaperItem, sized size: CGSize) -> URL? {
        let name = "\(item.id.uuidString)-\(Int(size.width))x\(Int(size.height)).png"
        let destination = framesURL.appendingPathComponent(name)

        if fileManager.fileExists(atPath: destination.path) {
            return destination
        }

        guard fileManager.fileExists(atPath: item.url.path) else { return nil }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: item.url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size

        var image: CGImage?
        let semaphore = DispatchSemaphore(value: 0)
        // Frame zero: it is what the loop starts on, so the still matches the
        // first thing the video shows after the compositing gap closes.
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { _, cgImage, _, _, _ in
            image = cgImage
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)

        guard let cgImage = image,
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            log.error("couldn't extract a still frame for \(item.title, privacy: .public)")
            return nil
        }

        do {
            try data.write(to: destination)
            return destination
        } catch {
            try? fileManager.removeItem(at: destination)
            log.error("couldn't write still frame: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
