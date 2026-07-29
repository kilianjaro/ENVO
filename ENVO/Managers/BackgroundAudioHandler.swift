import Foundation
import AVFoundation

/// Keeps the app alive in the background with a silent looping player,
/// paired with the `audio` UIBackgroundMode. Necessary because ENVO must
/// keep monitoring ambient noise while the user is in Spotify/Music/YouTube.
///
/// This type deliberately does NOT configure or activate the audio session
/// any more — `AudioSessionController` owns that, so session ownership is
/// reference-counted and nothing activates a record session before the user
/// has actually started ENVO. See AudioSessionController for why that
/// mattered (opening the app used to quieten all playback).
final class BackgroundAudioHandler {

    static let shared = BackgroundAudioHandler()

    private var silentPlayer: AVAudioPlayer?
    private var routeChangeToken: NSObjectProtocol?
    private var mediaServicesResetToken: NSObjectProtocol?
    private var mediaServicesLostToken: NSObjectProtocol?

    private init() {}

    /// Call only while `AudioSessionController` already holds an active
    /// session — the silent player needs one to keep the process alive.
    func enableBackgroundAudio() {
        guard silentPlayer == nil else { return }

        if let player = createSilentPlayer() {
            player.numberOfLoops = -1
            player.volume = 0.0
            player.play()
            silentPlayer = player
        } else {
            Log.session.error("Could not create the background keep-alive player.")
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
            // AudioSessionController observes the same notification and
            // re-applies the category; give it a beat to win the race before
            // we ask for a player that needs an active session.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard AudioSessionController.shared.isSessionActive else { return }
                self?.enableBackgroundAudio()
            }
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
        // Session deactivation is AudioSessionController's job — calibration
        // may still be holding it.
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
