import Foundation
import AVFoundation
import UIKit

/// Manages silent audio playback to keep app alive in background
class AudioManager {
    static let shared = AudioManager()
    private static let logger = LoggerUtil(category: "audioManager")
    
    private var audioEngine: AVAudioEngine?
    private var silentPlayer: AVAudioPlayerNode?
    private var cycleTimer: Timer?
    private var isInBackground = false
    
    // Audio cycle configuration
    private let playDuration: TimeInterval = 0.5  // Duration to play audio
    private let cycleDuration: TimeInterval = 20.0  // Total cycle duration
    
    private init() {
        setupAudioSession()
        setupAudioEngine()
        setupNotificationObservers()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            Self.logger.info("✅ Audio session setup complete")
        } catch {
            Self.logger.error("Failed to set up audio session: \(error.localizedDescription)")
        }
    }
    
    private func setupAudioEngine() {
        audioEngine = AVAudioEngine()
        silentPlayer = AVAudioPlayerNode()
        
        guard let audioEngine = audioEngine,
              let silentPlayer = silentPlayer else { return }
        
        // Create a silent audio buffer
        let sampleRate = 44100.0
        let duration = 1.0  // 1 second of silence
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else { return }
        buffer.frameLength = frameCount
        
        // Fill with silence (all zeros)
        if let channelData = buffer.floatChannelData?[0] {
            for frame in 0..<Int(frameCount) {
                channelData[frame] = 0.0
            }
        }
        
        // Connect nodes
        audioEngine.attach(silentPlayer)
        audioEngine.connect(silentPlayer, to: audioEngine.mainMixerNode, format: format)
        
        // Schedule the buffer to play on loop
        silentPlayer.scheduleBuffer(buffer, at: nil, options: .loops)
        Self.logger.info("✅ Audio engine setup complete")
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
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func handleAppDidEnterBackground() {
        Self.logger.info("🌚 App entered background mode")
        isInBackground = true
        startPlayingInBackground()
    }
    
    @objc private func handleAppWillEnterForeground() {
        Self.logger.info("🌞 App entering foreground mode")
        isInBackground = false
        stopPlayingInBackground()
    }
    
    func startPlayingInBackground() {
        Self.logger.info("🎵 Starting background audio cycle (play: \(playDuration)s, cycle: \(cycleDuration)s)")
        startAudioCycle()
    }
    
    private func startAudioCycle() {
        // Start the first cycle
        startAudio()
        
        // Setup the cycle timer
        cycleTimer?.invalidate()
        cycleTimer = Timer.scheduledTimer(withTimeInterval: cycleDuration, repeats: true) { [weak self] _ in
            self?.startAudio()
        }
    }
    
    private func startAudio() {
        guard let audioEngine = audioEngine,
              let silentPlayer = silentPlayer else { return }
        
        do {
            try audioEngine.start()
            silentPlayer.play()
             Self.logger.info("🔊 Started audio for \(playDuration)s")
            
            // Schedule stop after playDuration
            DispatchQueue.main.asyncAfter(deadline: .now() + playDuration) { [weak self] in
                self?.stopAudio()
            }
        } catch {
            Self.logger.error("Failed to start audio engine: \(error.localizedDescription)")
        }
    }
    
    private func stopAudio() {
        silentPlayer?.stop()
        audioEngine?.stop()
        // Self.logger.info("🔇 Stopped audio, waiting \(cycleDuration - playDuration)s")
    }
    
    func stopPlayingInBackground() {
        cycleTimer?.invalidate()
        cycleTimer = nil
        stopAudio()
        Self.logger.info("🛑 Stopped background audio cycle")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        stopPlayingInBackground()
    }
} 
