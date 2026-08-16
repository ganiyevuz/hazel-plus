import AppKit
import AVFoundation
import OSLog

final class WallpaperPlayerCore {
    private let log = Logger(subsystem: "com.live.hazel", category: "playback")

    private(set) var layer: AVPlayerLayer?

    private var player: AVQueuePlayer?
    private var playerLooper: AVPlayerLooper?

    /// Ping-pong (play forward, then backward, repeat) state.
    ///
    /// AVPlayerLooper only loops forward, so ping-pong drives the rate by hand
    /// and cannot use it. Reverse playback also needs the whole item buffered,
    /// which is why `automaticallyWaitsToMinimizeStalling` is turned off below.
    private var isPingPong = false
    private var endObserver: NSObjectProtocol?
    private var reverseObserver: Any?

    var isPlaying: Bool {
        player?.rate ?? 0 != 0
    }

    func load(url: URL, isLooping: Bool, isMuted: Bool, isPingPong: Bool = false, fit: WallpaperFit, bounds: CGRect) {
        cleanup()

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2.0

        let queuePlayer = AVQueuePlayer(playerItem: playerItem)
        self.isPingPong = isPingPong && isLooping

        if self.isPingPong {
            // AVQueuePlayer ADVANCES off a finished item by default, and with a
            // single item that empties the queue and blanks the layer. The normal
            // path never sees this because AVPlayerLooper keeps re-inserting the
            // item; ping-pong has no looper, so it must hold position instead.
            queuePlayer.actionAtItemEnd = .pause
            // Reverse playback stalls badly when the player is allowed to wait
            // on buffering, so let it decide for itself when to start.
            queuePlayer.automaticallyWaitsToMinimizeStalling = false
            observePingPong(on: queuePlayer, item: playerItem)
        } else if isLooping {
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

    /// Flips direction at each end instead of jumping back to the start.
    ///
    /// Forward end is signalled by the standard did-play-to-end notification.
    /// There is no equivalent for reaching the start while playing backwards, so
    /// that edge is detected by watching the clock.
    private func observePingPong(on queuePlayer: AVQueuePlayer, item: AVPlayerItem) {
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self, weak queuePlayer] _ in
            guard let self, let queuePlayer, self.isPingPong else { return }

            // Not every asset can be played backwards. Rather than sit on a
            // frozen frame, degrade to an ordinary loop and say so.
            guard queuePlayer.currentItem?.canPlayReverse == true else {
                self.log.info("asset can't play in reverse — falling back to a normal loop")
                self.isPingPong = false
                queuePlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    queuePlayer.play()
                }
                return
            }

            // Step off the exact end before reversing: at duration the item is
            // "ended", and a rate change there is ignored.
            let nudge = CMTime(seconds: 0.05, preferredTimescale: 600)
            let target = CMTimeSubtract(queuePlayer.currentTime(), nudge)
            queuePlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                queuePlayer.rate = -1.0
            }
        }

        reverseObserver = queuePlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak queuePlayer] time in
            guard let self, let queuePlayer, self.isPingPong else { return }
            guard queuePlayer.rate < 0, time.seconds <= 0.05 else { return }
            queuePlayer.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            queuePlayer.rate = 1.0
        }
    }

    func play() {
        guard let player else { return }
        // Preserve direction: a resume mid-reverse should not jump forwards.
        if isPingPong && player.rate < 0 {
            player.rate = -1.0
        } else {
            player.play()
        }
    }

    func pause() {
        player?.pause()
    }

    func resize(to bounds: CGRect) {
        layer?.frame = bounds
    }

    func cleanup() {
        player?.pause()
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        if let reverseObserver {
            player?.removeTimeObserver(reverseObserver)
        }
        reverseObserver = nil
        isPingPong = false
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
