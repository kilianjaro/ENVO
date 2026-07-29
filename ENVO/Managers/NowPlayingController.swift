import Foundation
import MediaPlayer
import Combine

/// Keeps ENVO **out** of the system Now Playing surface.
///
/// WHY THIS TYPE NO LONGER PUBLISHES ANYTHING
/// ------------------------------------------
/// ENVO used to populate `MPNowPlayingInfoCenter` with a title, a playback rate
/// of 1.0 and a live-stream flag, and register play/pause/stop remote commands.
/// The intention was benign — show that ENVO is running, and offer a one-tap
/// exit from the lock screen.
///
/// The effect was not. ENVO holds an active audio session and plays a silent
/// keep-alive track, so as far as iOS is concerned it is a playing audio app;
/// publishing Now Playing info makes it eligible to *become* the now-playing
/// app. In the situation ENVO is built for — running in the background while
/// Spotify, Music, Podcasts or YouTube plays — that meant the lock screen and
/// Control Center stopped showing the user's track and showed "ENVO — adapting
/// volume" instead, and the transport buttons stopped the engine rather than
/// the music. A utility that runs alongside the user's media player must not
/// take the media player's controls away from them.
///
/// So ENVO now claims nothing. Starting and stopping happen in the app, through
/// the Action Button, or via Siri and Shortcuts (`EnvoIntents`), all of which
/// work from the lock screen already and none of which cost the user their
/// transport controls.
///
/// This type remains as the one place that guarantees the tile stays clear:
/// `MPNowPlayingInfoCenter` is process-global, and an entry left behind by an
/// earlier build or an earlier launch persists until something clears it.
final class NowPlayingController: ObservableObject {

    private var cancellables = Set<AnyCancellable>()

    /// Clear anything ENVO may have published, and make sure the remote command
    /// centre is not holding handlers that would let ENVO win the tile.
    func attach(engine: EnvoEngine, volumeController: VolumeController) {
        relinquish()

        // Also clear on every stop, in case a future change ever publishes
        // something while running.
        engine.$isActive
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.relinquish() }
            .store(in: &cancellables)
    }

    private func relinquish() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil

        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.isEnabled = false
        cc.pauseCommand.isEnabled = false
        cc.stopCommand.isEnabled = false
        cc.togglePlayPauseCommand.isEnabled = false
        cc.nextTrackCommand.isEnabled = false
        cc.previousTrackCommand.isEnabled = false
        cc.changePlaybackPositionCommand.isEnabled = false
        cc.seekForwardCommand.isEnabled = false
        cc.seekBackwardCommand.isEnabled = false
    }
}
