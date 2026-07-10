import Foundation
import AVFoundation

/// Keeps the app alive in the background by maintaining an active audio session.
///
/// Uses a silent audio loop combined with the `audio` UIBackgroundMode.
/// This is necessary because ENVO must continuously monitor ambient noise
/// and adjust volume even when the user switches to Spotify/Music/YouTube.
final class BackgroundAudioHandler {

    static let shared = BackgroundAudioHandler()

    private var silentPlayer: AVAudioPlayer?
    private var routeChangeToken: NSObjectProtocol?
    private var mediaServicesResetToken: NSObjectProtocol?
    private var mediaServicesLostToken: NSObjectProtocol?

    private init() {}

    func enableBackgroundAudio() {
        guard silentPlayer == nil else { return }

        do {
            let session = AVAudioSession.sharedInstance()
            // A2DP (not HFP): Bluetooth headphones keep hi-fi stereo output
            // while ambient noise is sensed by the iPhone's built-in mic.
            try session.setCategory(
                .playAndRecord,
                mode: .measurement,
                options: [.defaultToSpeaker, .allowBluetoothA2DP, .mixWithOthers]
            )
            try session.setActive(true)

            if let player = createSilentPlayer() {
                player.numberOfLoops = -1
                player.volume = 0.0
                player.play()
                silentPlayer = player
            }
        } catch {
            Log.session.error("BackgroundAudioHandler error: \(error.localizedDescription, privacy: .public)")
        }

        // Replace any prior route observer (start/stop cycles must not leak).
        if let token = routeChangeToken {
            NotificationCenter.default.removeObserver(token)
            routeChangeToken = nil
        }
        routeChangeToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self = self, let player = self.silentPlayer else { return }
            if !player.isPlaying { player.play() }
        }

        // iOS may tear down the entire media subsystem (rare but real).
        // When that happens we need to rebuild the silent player from
        // scratch or background audio silently dies.
        if let token = mediaServicesResetToken {
            NotificationCenter.default.removeObserver(token)
        }
        mediaServicesResetToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.silentPlayer?.stop()
            self?.silentPlayer = nil
            self?.enableBackgroundAudio()
        }

        if let token = mediaServicesLostToken {
            NotificationCenter.default.removeObserver(token)
        }
        mediaServicesLostToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.silentPlayer?.stop()
            self?.silentPlayer = nil
        }
    }

    func disableBackgroundAudio() {
        silentPlayer?.stop()
        silentPlayer = nil

        if let token = routeChangeToken {
            NotificationCenter.default.removeObserver(token)
            routeChangeToken = nil
        }
        if let token = mediaServicesResetToken {
            NotificationCenter.default.removeObserver(token)
            mediaServicesResetToken = nil
        }
        if let token = mediaServicesLostToken {
            NotificationCenter.default.removeObserver(token)
            mediaServicesLostToken = nil
        }

        // Politely yield the session so other apps' playback can resume.
        do {
            try AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
        } catch {
            // Non-fatal: another component may still hold the session.
        }
    }

    private func createSilentPlayer() -> AVAudioPlayer? {
        // Minimal WAV: 44-byte header + 2 bytes silence.
        var wav = Data()

        wav.append(contentsOf: Array("RIFF".utf8))
        wav.append(contentsOf: uint32LE(36 + 2))
        wav.append(contentsOf: Array("WAVE".utf8))

        wav.append(contentsOf: Array("fmt ".utf8))
        wav.append(contentsOf: uint32LE(16))
        wav.append(contentsOf: uint16LE(1))
        wav.append(contentsOf: uint16LE(1))
        wav.append(contentsOf: uint32LE(8000))
        wav.append(contentsOf: uint32LE(16000))
        wav.append(contentsOf: uint16LE(2))
        wav.append(contentsOf: uint16LE(16))

        wav.append(contentsOf: Array("data".utf8))
        wav.append(contentsOf: uint32LE(2))
        wav.append(contentsOf: [0x00, 0x00])

        return try? AVAudioPlayer(data: wav)
    }

    private func uint32LE(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF),
         UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func uint16LE(_ v: UInt16) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }
}
