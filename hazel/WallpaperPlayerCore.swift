import AppKit
import AVFoundation

final class WallpaperPlayerCore {
    private(set) var layer: AVPlayerLayer?

    private var player: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?

    var isPlaying: Bool {
        player?.rate ?? 0 > 0
    }

    func load(url: URL, isLooping: Bool, isMuted: Bool, fit: WallpaperFit, bounds: CGRect) {
        cleanup()

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2.0

        let queuePlayer = AVQueuePlayer(playerItem: playerItem)

        if isLooping {
            playerLooper = AVPlayerLooper(player: queuePlayer, templateItem: playerItem)
        }

        let playerLayer = AVPlayerLayer(player: queuePlayer)
        playerLayer.videoGravity = fit.videoGravity
        playerLayer.frame = bounds

        self.layer = playerLayer
        self.player = queuePlayer
        queuePlayer.isMuted = isMuted
    }

    func setMuted(_ muted: Bool) {
        player?.isMuted = muted
    }

    func play() {
        player?.play()
    }

    func pause() {
        player?.pause()
    }

    func resize(to bounds: CGRect) {
        layer?.frame = bounds
    }

    func cleanup() {
        player?.pause()
        layer?.removeFromSuperlayer()
        playerLooper?.disableLooping()
        playerLooper = nil
        player = nil
        layer = nil
    }

    deinit {
        cleanup()
    }
}
