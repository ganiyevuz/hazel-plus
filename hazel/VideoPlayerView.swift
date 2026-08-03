import AppKit
import AVFoundation

class VideoPlayerView: NSView {
    private let playerCore = WallpaperPlayerCore()
    private var currentURL: URL?
    private var currentIsLooping: Bool = true
    private var currentIsMuted: Bool = true
    private var currentFit: WallpaperFit = .fill

    var isPlaying: Bool {
        playerCore.isPlaying
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func loadVideo(url: URL, isLooping: Bool = true, isMuted: Bool = true, fit: WallpaperFit) {
        currentURL = url
        currentIsLooping = isLooping
        currentIsMuted = isMuted
        currentFit = fit

        playerCore.load(url: url, isLooping: isLooping, isMuted: isMuted, fit: fit, bounds: bounds)
        if let playerLayer = playerCore.layer {
            layer?.addSublayer(playerLayer)
        }
    }

    func setMuted(_ muted: Bool) {
        playerCore.setMuted(muted)
        currentIsMuted = muted
    }

    func reloadWithSettings() {
        guard let url = currentURL else { return }
        loadVideo(url: url, isLooping: currentIsLooping, isMuted: currentIsMuted, fit: currentFit)
    }

    func play() {
        playerCore.play()
    }

    func pause() {
        playerCore.pause()
    }

    func cleanup() {
        playerCore.cleanup()
        currentURL = nil
    }

    override func layout() {
        super.layout()
        playerCore.resize(to: bounds)
    }

    deinit {
        cleanup()
    }
}
