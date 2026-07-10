import SwiftUI
import AVFoundation

@main
struct ENVOApp: App {
    @StateObject private var audioManager: AudioManager
    @StateObject private var volumeController: VolumeController
    @StateObject private var calibrationStore: CalibrationStore
    @StateObject private var settings: SettingsStore
    @StateObject private var envoEngine: EnvoEngine
    @StateObject private var nowPlaying = NowPlayingController()
    @StateObject private var lifecycle = AppLifecycleCoordinator()

    @Environment(\.scenePhase) private var scenePhase

    init() {
        let am = AudioManager()
        let vc = VolumeController()
        let cs = CalibrationStore()
        let st = SettingsStore()
        let engine = EnvoEngine(
            audioManager: am,
            volumeController: vc,
            calibrationStore: cs,
            settings: st
        )

        _audioManager = StateObject(wrappedValue: am)
        _volumeController = StateObject(wrappedValue: vc)
        _calibrationStore = StateObject(wrappedValue: cs)
        _settings = StateObject(wrappedValue: st)
        _envoEngine = StateObject(wrappedValue: engine)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(audioManager)
                .environmentObject(volumeController)
                .environmentObject(calibrationStore)
                .environmentObject(settings)
                .environmentObject(envoEngine)
                .onAppear {
                    lifecycle.bootstrap(
                        audioManager: audioManager,
                        volumeController: volumeController,
                        engine: envoEngine,
                        settings: settings
                    )
                    nowPlaying.attach(engine: envoEngine, volumeController: volumeController)
                    if #available(iOS 16.0, *) {
                        EnvoIntentBridge.engine = envoEngine
                    }
                }
        }
        .onChange(of: scenePhase) { phase in
            lifecycle.handleScenePhase(phase)
        }
    }
}

/// Owns the cross-cutting audio-session / interruption / route lifecycle.
final class AppLifecycleCoordinator: ObservableObject {

    private weak var audioManager: AudioManager?
    private weak var volumeController: VolumeController?
    private weak var engine: EnvoEngine?
    private weak var settings: SettingsStore?

    private var hasBootstrapped = false
    private var wasActiveBeforeInterruption = false
    private var interruptionToken: NSObjectProtocol?

    deinit {
        if let token = interruptionToken {
            NotificationCenter.default.removeObserver(token)
        }
    }

    func bootstrap(audioManager: AudioManager,
                   volumeController: VolumeController,
                   engine: EnvoEngine,
                   settings: SettingsStore) {
        self.audioManager = audioManager
        self.volumeController = volumeController
        self.engine = engine
        self.settings = settings

        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        configureAudioSession()
        registerForInterruptions()
        audioManager.prepare()

        // VolumeController needs a keyWindow; defer setup briefly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak volumeController] in
            volumeController?.setup()
        }

        // Auto-resume: if the user has opted in AND the engine was active
        // at last quit, start the engine once VolumeController is ready
        // and mic permission is granted.
        if settings.autoResume && settings.wasActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.attemptAutoResume()
            }
        }
    }

    private func attemptAutoResume() {
        guard let engine = engine, !engine.isActive else { return }
        guard let audioManager = audioManager, audioManager.permissionGranted else { return }
        engine.start()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .active:
            // Returning from background: ensure VolumeController is set up
            // even if bootstrap fired before any scene was available.
            volumeController?.setup()
        case .background, .inactive:
            break
        @unknown default:
            break
        }
    }

    private func configureAudioSession() {
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
        } catch {
            Log.session.error("Audio session error: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func registerForInterruptions() {
        if let token = interruptionToken {
            NotificationCenter.default.removeObserver(token)
        }

        interruptionToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let info = notification.userInfo,
                  let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

            switch type {
            case .began:
                if self.engine?.isActive == true {
                    self.wasActiveBeforeInterruption = true
                    self.engine?.stop()
                } else {
                    self.wasActiveBeforeInterruption = false
                }

            case .ended:
                self.configureAudioSession()
                if let optionsValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
                    if options.contains(.shouldResume), self.wasActiveBeforeInterruption {
                        self.engine?.start()
                    }
                }
                self.wasActiveBeforeInterruption = false

            @unknown default:
                break
            }
        }
    }
}
