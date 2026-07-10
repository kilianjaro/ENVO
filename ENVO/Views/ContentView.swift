import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var volumeController: VolumeController
    @EnvironmentObject var calibrationStore: CalibrationStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: EnvoEngine

    @State private var showPermissionAlert = false
    @State private var showCalibration = false
    @State private var showInfo = false
    @State private var showOnboarding = false

    var body: some View {
        Group {
            if audioManager.permissionState == .denied {
                PermissionDeniedView()
            } else {
                mainScreen
            }
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView()
                .environmentObject(settings)
        }
        .onAppear {
            if !settings.hasCompletedOnboarding {
                showOnboarding = true
            }
        }
    }

    private var mainScreen: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // ── Main Layout ──
            // Uses weighted spacers for even distribution.
            GeometryReader { geo in
                VStack(spacing: 0) {

                    // Header
                    headerView
                    Spacer()

                    // Status row: ACTIVE/STANDBY + CALIBRATE + GAP
                    statusRow
                    Spacer()

                    // Visualization. Once calibrated AND active, show the
                    // estimated ambient (what actually drives the offset)
                    // rather than the raw mic level which also includes
                    // our own playback bleed.
                    NoiseVisualizerView(
                        normalizedLevel: visualizerLevel,
                        isActive: engine.isActive,
                        levelHistory: engine.levelHistory
                    )
                    .frame(height: min(geo.size.height * 0.22, 200))
                    .padding(.horizontal, 24)
                    .accessibilityLabel("Noise visualization")
                    Spacer()

                    // Readout (fixed columns)
                    readoutView
                    Spacer()

                    // Response + Direction
                    responseAndDirectionRow
                    Spacer().frame(maxHeight: 14)

                    // Range (stays close to Response row — they're a group)
                    modeSelectorView(
                        title: "RANGE",
                        options: RangeMode.allCases.map { $0.rawValue },
                        selected: engine.rangeMode.rawValue,
                        onSelect: { val in
                            if let mode = RangeMode(rawValue: val) {
                                engine.rangeMode = mode
                            }
                        }
                    )
                    .padding(.horizontal, 24)
                    Spacer()

                    // Activate
                    activateButton
                    Spacer()

                    // Footer
                    footerView
                }
                .padding(.top, 8)
                .padding(.bottom, 4)
            }

            // ── Info Overlay ──
            if showInfo {
                infoOverlay
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: showInfo)
        .alert("Microphone Access Required", isPresented: $showPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ENVO needs microphone access to measure ambient noise. No audio is recorded or stored.")
        }
        .sheet(isPresented: $showCalibration) {
            CalibrationView()
                .environmentObject(audioManager)
                .environmentObject(volumeController)
                .environmentObject(calibrationStore)
                .environmentObject(engine)
        }
    }


    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Header
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var headerView: some View {
        HStack {
            Text("ENVO")
                .font(.envo(size: 28))
                .foregroundColor(.white)
                .kerning(8)
                .accessibilityAddTraits(.isHeader)

            Spacer()

            Button(action: { showInfo = true }) {
                Text("INFO")
                    .font(.envo(size: 11))
                    .foregroundColor(.gray)
                    .kerning(3)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .overlay(
                        Rectangle()
                            .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("About ENVO")
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Status Row
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var statusRow: some View {
        HStack(spacing: 10) {
            // Active / Standby badge
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isActive ? Color.white : Color.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .animation(
                        engine.isActive
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .default,
                        value: engine.isActive
                    )

                Text(engine.isActive ? "ACTIVE" : "STANDBY")
                    .font(.envo(size: 11))
                    .foregroundColor(engine.isActive ? .white : .gray)
                    .kerning(3)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay(
                Rectangle()
                    .stroke(engine.isActive ? Color.white : Color.gray.opacity(0.3), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(engine.isActive ? "Engine active" : "Engine standby")

            // Calibrate / Calibrated button. Drifts to a "RECAL?" tint
            // when the live silence floor disagrees with the calibrated one.
            Button(action: {
                if engine.isActive { engine.stop() }
                showCalibration = true
            }) {
                Text(calibrateButtonLabel)
                    .font(.envo(size: 9))
                    .foregroundColor(calibrateButtonForeground)
                    .kerning(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(
                        Rectangle()
                            .stroke(calibrateButtonBorder, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(engine.isCalibrated ? "Recalibrate room" : "Calibrate room")

            // Gap badge
            if engine.gapDetected {
                Text("GAP")
                    .font(.envo(size: 9))
                    .foregroundColor(.white)
                    .kerning(2)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.15))
                    .overlay(
                        Rectangle()
                            .stroke(Color.white.opacity(0.4), lineWidth: 1)
                    )
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: engine.gapDetected)
            }
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Readout (fixed columns)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var readoutView: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let sideW = w * 0.30   // NOISE and ADJ each get 30%
            let midW = w * 0.40    // VOL gets 40% (room for "100 %")

            HStack(spacing: 0) {
                // ── NOISE / AMBIENT ──
                VStack(spacing: 4) {
                    Text(engine.isCalibrated ? "AMBIENT" : "NOISE")
                        .font(.envo(size: 9))
                        .foregroundColor(.gray)
                        .kerning(2)

                    readoutNumber(
                        value: "\(engine.isCalibrated && engine.isActive ? engine.displayAmbient : audioManager.approximateDB)",
                        unit: "dB"
                    )
                }
                .frame(width: sideW, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Noise \(audioManager.approximateDB) decibels")

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1, height: 50)

                // ── VOL ──
                VStack(spacing: 4) {
                    Text("VOL")
                        .font(.envo(size: 9))
                        .foregroundColor(.gray)
                        .kerning(2)

                    readoutNumber(
                        value: "\(displayBaseVolume)",
                        unit: "%"
                    )
                }
                .frame(width: midW, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Volume \(displayBaseVolume) percent")

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1, height: 50)

                // ── ADJ ──
                VStack(spacing: 4) {
                    Text("ADJ")
                        .font(.envo(size: 9))
                        .foregroundColor(.gray)
                        .kerning(2)

                    Text(engine.displayOffset)
                        .font(.envo(size: 38))
                        .foregroundColor(offsetColor)
                        .kerning(2)
                        .monospacedDigit()
                }
                .frame(width: sideW, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Adjustment \(engine.displayOffset)")
            }
        }
        .frame(height: 70)
        .padding(.horizontal, 24)
    }

    /// Number + unit formatted consistently for the readout.
    private func readoutNumber(value: String, unit: String) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            Text(value)
                .font(.envo(size: 38))
                .foregroundColor(.white)
                .kerning(2)
                .monospacedDigit()

            Text(unit)
                .font(.envo(size: 12))
                .foregroundColor(.gray)
                .kerning(1)
        }
    }

    private var offsetColor: Color {
        let offset = engine.currentOffset
        if offset > 0.01 { return .white }
        if offset < -0.01 { return .gray }
        return .white.opacity(0.5)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Response + Direction Row
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var responseAndDirectionRow: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let gap: CGFloat = 10
            let respW = (total - gap) * 2.0 / 3.0
            let dirW = (total - gap) * 1.0 / 3.0

            HStack(alignment: .top, spacing: gap) {
                // ── RESPONSE (2/3) ──
                VStack(alignment: .leading, spacing: 8) {
                    Text("RESPONSE")
                        .font(.envo(size: 9))
                        .foregroundColor(.gray)
                        .kerning(3)

                    HStack(spacing: 0) {
                        ForEach(SpeedMode.allCases) { mode in
                            Button(action: {
                                if engine.speedMode != mode { Haptics.select() }
                                engine.speedMode = mode
                            }) {
                                Text(mode.rawValue)
                                    .font(.envo(size: 13))
                                    .foregroundColor(engine.speedMode == mode ? .black : .white)
                                    .kerning(2)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .buttonStyle(.plain)
                            .background(engine.speedMode == mode ? Color.white : Color.clear)
                            .accessibilityLabel("Response \(mode.rawValue)")
                            .accessibilityAddTraits(engine.speedMode == mode ? .isSelected : [])

                            if mode != SpeedMode.allCases.last {
                                Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1)
                            }
                        }
                    }
                    .frame(height: 44)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                }
                .frame(width: respW)

                // ── DIR (1/3) ──
                VStack(alignment: .leading, spacing: 8) {
                    Text("DIR")
                        .font(.envo(size: 9))
                        .foregroundColor(.gray)
                        .kerning(3)

                    HStack(spacing: 0) {
                        Button(action: { toggleDirection(increase: true) }) {
                            Text("+")
                                .font(.envo(size: 18))
                                .foregroundColor(engine.allowIncrease ? .black : .white.opacity(0.3))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.plain)
                        .background(engine.allowIncrease ? Color.white : Color.clear)
                        .accessibilityLabel("Increase")
                        .accessibilityValue(engine.allowIncrease ? "On" : "Off")

                        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1)

                        Button(action: { toggleDirection(increase: false) }) {
                            Text("–")
                                .font(.envo(size: 18))
                                .foregroundColor(engine.allowDecrease ? .black : .white.opacity(0.3))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                        .buttonStyle(.plain)
                        .background(engine.allowDecrease ? Color.white : Color.clear)
                        .accessibilityLabel("Decrease")
                        .accessibilityValue(engine.allowDecrease ? "On" : "Off")
                    }
                    .frame(height: 44)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.4), lineWidth: 1))
                }
                .frame(width: dirW)
            }
        }
        .frame(height: 70)
        .padding(.horizontal, 24)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Mode Selector
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private func modeSelectorView(
        title: String,
        options: [String],
        selected: String,
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.envo(size: 9))
                .foregroundColor(.gray)
                .kerning(3)

            HStack(spacing: 0) {
                ForEach(options, id: \.self) { option in
                    Button(action: {
                        if option != selected { Haptics.select() }
                        onSelect(option)
                    }) {
                        Text(option)
                            .font(.envo(size: 13))
                            .foregroundColor(option == selected ? .black : .white)
                            .kerning(2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .buttonStyle(.plain)
                    .background(option == selected ? Color.white : Color.clear)
                    .accessibilityLabel("\(title) \(option)")
                    .accessibilityAddTraits(option == selected ? .isSelected : [])

                    if option != options.last {
                        Rectangle().fill(Color.white.opacity(0.2)).frame(width: 1)
                    }
                }
            }
            .frame(height: 44)
            .overlay(Rectangle().stroke(Color.white.opacity(0.4), lineWidth: 1))
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Activate Button
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var activateButton: some View {
        Button(action: toggleEngine) {
            Text(engine.isActive ? "STOP" : "START")
                .font(.envo(size: 18))
                .foregroundColor(engine.isActive ? .white : .black)
                .kerning(6)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(engine.isActive ? Color.clear : Color.white)
                .overlay(
                    Rectangle()
                        .stroke(Color.white, lineWidth: engine.isActive ? 2 : 0)
                )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
        .accessibilityLabel(engine.isActive ? "Stop ENVO" : "Start ENVO")
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Footer
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var footerView: some View {
        Text("TOTEMPHONIA STUDIO BERLIN")
            .font(.envo(size: 8))
            .foregroundColor(.gray.opacity(0.5))
            .kerning(4)
            .padding(.bottom, 12)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Info Overlay
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var infoOverlay: some View {
        ZStack {
            Color.black.opacity(0.96).ignoresSafeArea()

            VStack(spacing: 0) {
                // Close header
                HStack {
                    Text("ENVO")
                        .font(.envo(size: 22))
                        .foregroundColor(.white)
                        .kerning(6)

                    Spacer()

                    Button(action: { showInfo = false }) {
                        Text("CLOSE")
                            .font(.envo(size: 11))
                            .foregroundColor(.gray)
                            .kerning(3)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .overlay(
                                Rectangle()
                                    .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)
                .padding(.bottom, 16)

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 24)

                // Scrollable content
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 24) {

                        infoSection(
                            title: "CONCEPT",
                            body: "ENVO is an adaptive volume controller. It listens to the ambient noise in your environment and automatically adjusts your device volume to compensate. When your surroundings get louder, ENVO raises the volume. When they get quieter, it brings it back down."
                        )

                        infoSection(
                            title: "HOW IT WORKS",
                            body: "ENVO reads your device microphone to measure ambient noise levels. It does not record, store, or transmit any audio data. Only instantaneous power levels are calculated and immediately discarded. Your set volume is the baseline — ENVO applies a small adjustment on top of it. You remain in full control of your volume at all times."
                        )

                        infoSection(
                            title: "CONTROLS",
                            body: "RESPONSE sets how quickly ENVO reacts: SLOW averages over 60 seconds, MED over 30, and FAST over 10. RANGE limits how much adjustment is applied: ±3dB, ±6dB, or ±9dB. DIR controls the direction of adjustment. Enable + to allow volume increases, – for decreases, or both."
                        )

                        infoSection(
                            title: "CALIBRATION",
                            body: "For best results, calibrate ENVO to your room and setup. Calibration plays a test noise at several volume levels and measures how your device speaker sounds to the microphone. This allows ENVO to separate your music from actual ambient noise, preventing feedback loops. Calibration takes about 30 seconds and is saved until you recalibrate."
                        )

                        infoSection(
                            title: "USAGE",
                            body: "Set your preferred volume, choose your response speed and range, then tap START. ENVO works in the background with any audio app. Adjust your volume at any time; ENVO will adopt it as the new baseline."
                        )

                        infoSection(
                            title: "PRIVACY",
                            body: "ENVO does not record, store, or transmit any audio. No user data is collected. Microphone access is used exclusively for real-time noise level measurement. Calibration profiles are stored locally on your device and are never shared."
                        )

                        optionsSection

                        Spacer().frame(height: 40)
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 24)
                }

                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(height: 1)
                    .padding(.horizontal, 24)

                // Footer (always visible) — links to totemphonia.com
                Button(action: {
                    if let url = URL(string: "https://totemphonia.com") {
                        UIApplication.shared.open(url)
                    }
                }) {
                    Text("TOTEMPHONIA STUDIO BERLIN")
                        .font(.envo(size: 8))
                        .foregroundColor(.white)
                        .kerning(4)
                        .underline(true, color: .white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .padding(.vertical, 16)
                .accessibilityLabel("Visit Totemphonia Studio Berlin website")
            }
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("OPTIONS")
                .font(.envo(size: 10))
                .foregroundColor(.white)
                .kerning(4)

            Toggle(isOn: $settings.autoResume) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AUTO-RESUME")
                        .font(.envo(size: 11))
                        .foregroundColor(.white)
                        .kerning(2)
                    Text("Start ENVO on launch if it was running at last quit.")
                        .font(.envo(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(.white)
            .accessibilityLabel("Auto-resume on launch")
        }
    }

    private func infoSection(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.envo(size: 10))
                .foregroundColor(.white)
                .kerning(4)

            Text(body)
                .font(.envo(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Actions
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Volume readout reads from VolumeController directly. No engine cache.
    private var displayBaseVolume: Int {
        Int((volumeController.baseVolume * 100).rounded())
    }

    /// What the visualizer should pulse to. Raw mic when uncalibrated /
    /// inactive (so the user can still see ENVO is "listening"); estimated
    /// ambient otherwise, so the visual matches what's driving the offset.
    private var visualizerLevel: Float {
        if engine.isActive && engine.isCalibrated {
            return engine.estimatedAmbient
        }
        return audioManager.normalizedLevel
    }

    private var calibrateButtonLabel: String {
        if engine.calibrationStale { return "RECAL?" }
        return engine.isCalibrated ? "CALIBRATED" : "CALIBRATE"
    }

    private var calibrateButtonForeground: Color {
        if engine.calibrationStale { return .white }
        return engine.isCalibrated ? .gray : .white
    }

    private var calibrateButtonBorder: Color {
        if engine.calibrationStale { return .white.opacity(0.8) }
        return engine.isCalibrated ? .gray.opacity(0.3) : .white.opacity(0.6)
    }

    /// Toggle one of the DIR buttons but keep at least one direction enabled.
    /// Disabling both would silently turn ENVO into a no-op while ACTIVE.
    private func toggleDirection(increase: Bool) {
        Haptics.tap()
        if increase {
            // Tapping "+" while "+" is on and "–" is off would leave both off.
            // Flip the other one on instead so the engine keeps doing work.
            if engine.allowIncrease && !engine.allowDecrease {
                engine.allowDecrease = true
                engine.allowIncrease = false
            } else {
                engine.allowIncrease.toggle()
            }
        } else {
            if engine.allowDecrease && !engine.allowIncrease {
                engine.allowIncrease = true
                engine.allowDecrease = false
            } else {
                engine.allowDecrease.toggle()
            }
        }
    }

    private func toggleEngine() {
        if engine.isActive {
            Haptics.bump()
            engine.stop()
            return
        }
        if audioManager.permissionGranted {
            Haptics.bump()
            engine.start()
            return
        }
        // Ask for permission and start only AFTER the user has answered the
        // system prompt. The previous version raced the iOS dialog with a
        // 0.5s timer and could show our fallback alert on top of it.
        audioManager.checkPermission { granted in
            if granted {
                Haptics.bump()
                engine.start()
            } else {
                Haptics.warning()
                showPermissionAlert = true
            }
        }
    }
}

#Preview {
    ContentViewPreviewWrapper()
}

private struct ContentViewPreviewWrapper: View {
    @StateObject private var am = AudioManager()
    @StateObject private var vc = VolumeController()
    @StateObject private var cs = CalibrationStore()
    @StateObject private var st = SettingsStore()
    @StateObject private var engine: EnvoEngine

    init() {
        let am = AudioManager()
        let vc = VolumeController()
        let cs = CalibrationStore()
        let st = SettingsStore()
        _am = StateObject(wrappedValue: am)
        _vc = StateObject(wrappedValue: vc)
        _cs = StateObject(wrappedValue: cs)
        _st = StateObject(wrappedValue: st)
        _engine = StateObject(wrappedValue: EnvoEngine(
            audioManager: am,
            volumeController: vc,
            calibrationStore: cs,
            settings: st
        ))
    }

    var body: some View {
        ContentView()
            .environmentObject(am)
            .environmentObject(vc)
            .environmentObject(cs)
            .environmentObject(st)
            .environmentObject(engine)
    }
}
