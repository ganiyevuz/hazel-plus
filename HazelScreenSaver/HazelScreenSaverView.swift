import ScreenSaver
import AVFoundation
import OSLog

class HazelScreenSaverView: ScreenSaverView {
    // The saver runs inside Apple's sandboxed legacyScreenSaver extension, where no
    // debugger is practical — diagnose with:
    //   log stream --predicate 'subsystem == "com.live.hazel.screensaver"'
    private static let log = Logger(subsystem: "com.live.hazel.screensaver", category: "playback")

    private let playerCore = WallpaperPlayerCore()
    private var refreshTimer: Timer?

    // macOS 26 Tahoe has been observed passing the wrong `isPreview` value to
    // init(frame:isPreview:) for the System Settings preview thumbnail. That
    // thumbnail is always small, so a frame-size heuristic backstops the flag.
    private static let previewSizeThreshold: CGFloat = 300
    private var isLikelyPreview: Bool {
        isPreview || bounds.width < Self.previewSizeThreshold || bounds.height < Self.previewSizeThreshold
    }

    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        animationTimeInterval = 1.0 / 30.0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func startAnimation() {
        super.startAnimation()
        loadCurrentSelection()

        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    override func stopAnimation() {
        super.stopAnimation()
        teardown()
    }

    override func draw(_ rect: NSRect) {
        super.draw(rect)
    }

    override func layout() {
        super.layout()
        playerCore.resize(to: bounds)
    }

    private func loadCurrentSelection() {
        guard let selection = WallpaperLibraryReader.currentSelection() else {
            Self.log.error("no active wallpaper — library unreadable or nothing selected; showing black")
            return
        }

        Self.log.info("loading \(selection.url.lastPathComponent, privacy: .public), preview=\(self.isLikelyPreview)")

        playerCore.load(
            url: selection.url,
            isLooping: selection.isLooping,
            isMuted: selection.isMuted || isLikelyPreview,
            fit: selection.fit,
            bounds: bounds
        )

        if let playerLayer = playerCore.layer {
            layer?.addSublayer(playerLayer)
        }
        playerCore.play()
    }

    private func tick() {
        // Defensive backstop for Tahoe's unreliable animateOneFrame/stopAnimation
        // lifecycle: if playback ever silently stops (e.g. the underlying window
        // went away without stopAnimation firing), tear down instead of leaking
        // a dead AVPlayerLayer.
        if window == nil {
            teardown()
        }
    }

    private func teardown() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        playerCore.cleanup()
    }

    deinit {
        teardown()
    }
}
