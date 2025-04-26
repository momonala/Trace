import Foundation
import AVFoundation
import UIKit

/// Manages silent audio playback to keep app alive in background
class AudioManager {
    static let shared = AudioManager()
    private static let logger = LoggerUtil(category: "audioManager")
    
    private var audioPlayer: AVAudioPlayer?
    private var cycleTimer: Timer?
    private var isInBackground = false
    
    // Audio cycle configuration
    private let playDuration: TimeInterval = 0.5  // Duration to play audio
    private let cycleDuration: TimeInterval = 20.0  // Total cycle duration
    
    private init() {
        setupAudioSession()
        setupAudioPlayer()
        setupNotificationObservers()
    }
    
    private func setupAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)
            Self.logger.info("✅ Audio session setup complete")
        } catch {
            Self.logger.error("Failed to set up audio session: \(error.localizedDescription)")
        }
    }
    
    private func setupAudioPlayer() {
        // Create a sine wave
        let sampleRate = 44100.0
        let duration = 1.0  // 1 second
        let frequency = 440.0  // A4 note
        let numSamples = Int(duration * sampleRate)
        
        // Create an audio format
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        
        // Create a buffer
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
            Self.logger.error("Failed to create audio buffer")
            return
        }
        
        // Fill the buffer with a sine wave
        let data = buffer.floatChannelData?[0]
        buffer.frameLength = AVAudioFrameCount(numSamples)
        
        for i in 0..<numSamples {
            let time = Double(i) / sampleRate
            data?[i] = Float(0.7 * sin(2.0 * .pi * frequency * time))
        }
        
        // Convert buffer to Data
        var audioFormat = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        
        var audioFile: ExtAudioFileRef?
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("test_tone.wav")
        
        // Create audio file
        guard ExtAudioFileCreateWithURL(
            tempURL as CFURL,
            kAudioFileWAVEType,
            &audioFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &audioFile
        ) == noErr else {
            Self.logger.error("Failed to create audio file")
            return
        }
        
        guard let audioFile = audioFile else { return }
        
        // Write buffer to file
        var asbd = format.streamDescription.pointee
        ExtAudioFileSetProperty(audioFile, kExtAudioFileProperty_ClientDataFormat, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &asbd)
        
        var frames = buffer.frameLength
        ExtAudioFileWrite(audioFile, frames, buffer.audioBufferList)
        ExtAudioFileDispose(audioFile)
        
        do {
            audioPlayer = try AVAudioPlayer(contentsOf: tempURL)
            audioPlayer?.numberOfLoops = -1  // Loop indefinitely
            audioPlayer?.volume = 0.7
            Self.logger.info("✅ Audio player setup complete")
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
            selector: #selector(handleAppWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    @objc private func handleAppDidEnterBackground() {
        Self.logger.info("🌚 App entered background mode")
        isInBackground = true
        
        // Ensure audio session is active
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            Self.logger.info("✅ Reactivated audio session in background")
        } catch {
            Self.logger.error("❌ Failed to reactivate audio session: \(error.localizedDescription)")
        }
        
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
        audioPlayer?.play()
        Self.logger.info("🔊 Started audio for \(playDuration)s")
        
        // Schedule stop
        DispatchQueue.main.asyncAfter(deadline: .now() + playDuration) { [weak self] in
            self?.stopAudio()
        }
    }
    
    private func stopAudio() {
        audioPlayer?.stop()
        Self.logger.info("🔇 Stopped audio, waiting \(cycleDuration - playDuration)s")
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
