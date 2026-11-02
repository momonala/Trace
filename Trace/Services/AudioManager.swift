import Foundation
import AVFoundation
import UIKit

/// Manages audio playback to keep app alive in background.
/// `audioPlayer` and `isInBackground` are only touched on `queue`.
class AudioManager {
    static let shared = AudioManager()
    private static let logger = LoggerUtil(category: "AudioManager")

    private let queue = DispatchQueue(label: "org.mnalavadi.Trace.audio")
    private var audioPlayer: AVAudioPlayer?
    /// Assumed until the first `didBecomeActive`: a background launch never posts `didEnterBackground`.
    private var isInBackground = true

    private init() {
        setupNotificationObservers()
        queue.async { [self] in
            setupAudioSession()
            setupAudioPlayer()
        }
    }

    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            Self.logger.info("Audio session setup complete")
        } catch {
            Self.logger.error("Failed to set up audio session: \(error.localizedDescription)")
        }
    }

    private func setupAudioPlayer() {
        guard let url = Bundle.main.url(forResource: "silence", withExtension: "caf") else {
            Self.logger.error("silence.caf missing from app bundle")
            return
        }
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: url)
            audioPlayer?.numberOfLoops = -1
            Self.logger.info("Audio player setup complete")
        } catch {
            Self.logger.error("Failed to create audio player: \(error.localizedDescription)")
        }
    }

    private func setupNotificationObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification,
            object: nil
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification,
            object: nil
        )
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }
        switch type {
        case .began:
            Self.logger.warning("Audio interrupted")
        case .ended:
            Self.logger.info("Audio interruption ended, resuming")
            startPlayingInBackground()
        @unknown default:
            break
        }
    }

    @objc private func handleMediaServicesReset() {
        Self.logger.warning("Media services were reset, rebuilding audio")
        queue.async { [self] in
            setupAudioSession()
            setupAudioPlayer()
        }
        startPlayingInBackground()
    }

    @objc private func handleAppDidEnterBackground() {
        Self.logger.info("App entered background mode")
        queue.async { [self] in isInBackground = true }
        startPlayingInBackground()
    }

    @objc private func handleAppDidBecomeActive() {
        Self.logger.info("App became active")
        queue.async { [self] in isInBackground = false }
        stopPlayingInBackground()
    }

    func startPlayingInBackground() {
        queue.async { [self] in
            guard isInBackground else {
                Self.logger.info("Not starting audio - app is in foreground")
                return
            }

            do {
                try AVAudioSession.sharedInstance().setActive(true)
            } catch {
                Self.logger.error("Failed to activate audio session: \(error.localizedDescription)")
            }
            if audioPlayer?.play() == true {
                Self.logger.info("Started continuous background audio")
            } else {
                Self.logger.error("Background audio did not start, iOS will suspend the app")
            }
        }
    }

    func stopPlayingInBackground() {
        queue.async { [self] in
            audioPlayer?.stop()
            Self.logger.info("Stopped background audio")
        }
    }
}
