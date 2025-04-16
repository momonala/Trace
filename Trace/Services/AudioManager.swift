import Foundation
import AVFoundation
import os.log

/// Manages silent audio playback to keep app alive in background
class AudioManager {
    static let shared = AudioManager()
    private static let logger = Logger(subsystem: "com.trace", category: "audioManager")
    
    private var audioEngine: AVAudioEngine?
    private var silentPlayer: AVAudioPlayerNode?
    private var timer: Timer?
    
    private init() {
        setupAudioSession()
        setupAudioEngine()
    }
    
    private func setupAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            Self.logger.info("✅ Audio session setup complete")
        } catch {
            Self.logger.error("❌ Failed to set up audio session: \(error.localizedDescription)")
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
    
    func startPlayingInBackground() {
        guard let audioEngine = audioEngine,
              let silentPlayer = silentPlayer else { return }
        
        do {
            try audioEngine.start()
            silentPlayer.play()
            
            // Periodically check and restart if needed
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                if audioEngine.isRunning {
                    Self.logger.info("🔊 Silent audio still playing")
                } else {
                    Self.logger.warning("🔇 Silent audio stopped, restarting...")
                    self?.restartAudioEngine()
                }
            }
            Self.logger.info("✅ Started background audio")
        } catch {
            Self.logger.error("❌ Failed to start audio engine: \(error.localizedDescription)")
        }
    }
    
    private func restartAudioEngine() {
        setupAudioSession()
        setupAudioEngine()
        startPlayingInBackground()
    }
    
    func stopPlayingInBackground() {
        timer?.invalidate()
        timer = nil
        silentPlayer?.stop()
        audioEngine?.stop()
        Self.logger.info("🛑 Stopped background audio")
    }
} 