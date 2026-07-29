import Foundation
import MediaPlayer
import Combine
import UIKit

/// Surfaces ENVO on the lock screen / Control Center via
/// MPNowPlayingInfoCenter + MPRemoteCommandCenter.
///
/// We aren't actually playing audio the user wants to hear — we're a
/// background-audio "session holder." But publishing a Now Playing entry
/// has two real benefits:
///   1. The user can see "ENVO is running" without unlocking.
///   2. The remote-command stop button gives them a one-tap exit.
///
/// We never claim playback control of OTHER apps' audio. The Now Playing
/// entry is purely informational about ENVO's own activity state.
final class NowPlayingController: ObservableObject {

    private weak var engine: EnvoEngine?
    private weak var volumeController: VolumeController?

    private var cancellables = Set<AnyCancellable>()
    private var registered = false

    func attach(engine: EnvoEngine, volumeController: VolumeController) {
        self.engine = engine
        self.volumeController = volumeController

        registerRemoteCommands()

        // Sync the lock-screen tile whenever ENVO state changes.
        engine.$isActive
            .removeDuplicates()
            .sink { [weak self] active in
                self?.updateNowPlaying(isActive: active)
            }
            .store(in: &cancellables)

        engine.$currentOffsetDB
            .throttle(for: .seconds(0.5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)

        engine.$estimatedAmbientDB
            .throttle(for: .seconds(0.5), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in
                self?.refresh()
            }
            .store(in: &cancellables)
    }

    // MARK: - Remote commands

    private func registerRemoteCommands() {
        guard !registered else { return }
        registered = true

        let cc = MPRemoteCommandCenter.shared()

        cc.stopCommand.isEnabled = true
        cc.stopCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.engine?.stop()
            }
            return .success
        }

        cc.pauseCommand.isEnabled = true
        cc.pauseCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.engine?.stop()
            }
            return .success
        }

        // Resume from lock screen mirrors start. Useful but optional —
        // if mic permission isn't granted, the engine silently no-ops.
        cc.playCommand.isEnabled = true
        cc.playCommand.addTarget { [weak self] _ in
            DispatchQueue.main.async {
                self?.engine?.start()
            }
            return .success
        }

        // Disable controls we don't model (skip / scrub / etc.).
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
        cc.changePlaybackPositionCommand.isEnabled = false
        cc.seekForwardCommand.isEnabled = false
        cc.seekBackwardCommand.isEnabled = false
    }

    // MARK: - Now Playing tile

    private func updateNowPlaying(isActive: Bool) {
        if isActive {
            refresh()
        } else {
            // Wipe the tile when stopped so the lock screen doesn't lie.
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    private func refresh() {
        guard let engine = engine, engine.isActive else { return }

        let center = MPNowPlayingInfoCenter.default()
        let ambient = engine.displayAmbient.map { "ambient \($0) dB" } ?? "ambient —"
        let offset = engine.displayOffset
        let subtitle = offset == "0.0" ? ambient : "\(offset) dB · \(ambient)"

        var info: [String: Any] = [:]
        info[MPMediaItemPropertyTitle] = "ENVO — adapting volume"
        info[MPMediaItemPropertyArtist] = subtitle
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        center.nowPlayingInfo = info
    }
}
