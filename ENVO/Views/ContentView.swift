import SwiftUI

struct ContentView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var volumeController: VolumeController
    @EnvironmentObject var calibrationStore: CalibrationStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var engine: EnvoEngine

    @State private var showPermissionAlert = false
    @State private var startFailureMessage: String?
    @State private var showCalibration = false
    @State private var showInfo = false
    @State private var showOnboarding = false

    #if DEBUG
    /// Bumped to force the diagnostics section to re-read the log directory,
    /// which is filesystem state SwiftUI cannot observe.
    @State private var logRefreshToken = 0
    @State private var listenerMarkCount = 0
    #endif

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

                    // Calm, specific explanation whenever ENVO is running but
                    // deliberately not adapting. Occupies no space otherwise.
                    if engine.isActive, advisoryNotice != nil {
                        Spacer().frame(maxHeight: 12)
                        advisoryView
                    }
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
        .alert("ENVO Could Not Start",
               isPresented: Binding(get: { startFailureMessage != nil },
                                    set: { if !$0 { startFailureMessage = nil } })) {
            Button("OK", role: .cancel) { startFailureMessage = nil }
        } message: {
            Text(startFailureMessage ?? "")
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

            markButton

            // The GAP badge used to live here. It reported a diagnostic that
            // stopped meaning anything once ambient tracking no longer needed
            // pauses in playback to read the room — and with nothing playing it
            // was simply lit the whole time. The detection it was based on is
            // still running; it now only feeds the RECAL? hint on the button
            // above, which is a conclusion rather than a raw signal.
        }
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Readout (fixed columns)
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    private var readoutView: some View {
        GeometryReader { geo in
            // Three equal columns. The two 1pt dividers are taken out of the
            // total first, so each value block is centred in a genuinely equal
            // share rather than sitting slightly off-centre.
            let columnW = (geo.size.width - 2) / 3

            HStack(spacing: 0) {
                // ── NOISE / AMBIENT ──
                VStack(spacing: 4) {
                    Text(engine.isActive ? "AMBIENT" : "NOISE")
                        .font(.envo(size: 9))
                        .foregroundColor(.gray)
                        .kerning(2)

                    readoutNumber(
                        value: noiseReadoutValue,
                        unit: "dB"
                    )
                }
                .frame(width: columnW, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(noiseAccessibilityLabel)

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
                .frame(width: columnW, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Volume \(displayBaseVolume) percent")

                // Divider
                Rectangle()
                    .fill(Color.white.opacity(0.15))
                    .frame(width: 1, height: 50)

                // ── ADJ ──
                // Shown in decibels, with the unit. This used to print the
                // slider offset as a bare percentage, so a 14% slider move
                // read as "-14" and was naturally taken for -14 dB.
                VStack(spacing: 4) {
                    Text("ADJ")
                        .font(.envo(size: 9))
                        .foregroundColor(.gray)
                        .kerning(2)

                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text(engine.displayOffset)
                            .font(.envo(size: 38))
                            .foregroundColor(offsetColor)
                            // Half the tracking of the other readouts: this
                            // value carries a sign and a decimal, so the wider
                            // spacing pushed it out of balance with them.
                            .kerning(1)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.5)

                        Text("dB")
                            .font(.envo(size: 12))
                            .foregroundColor(.gray)
                            .kerning(1)
                    }
                }
                .frame(width: columnW, alignment: .center)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Adjustment \(engine.displayOffset) decibels")
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
                .lineLimit(1)
                .minimumScaleFactor(0.5)

            Text(unit)
                .font(.envo(size: 12))
                .foregroundColor(.gray)
                .kerning(1)
        }
    }

    private var offsetColor: Color {
        // Matches `engine.displayOffset`, which reports the control law's intent.
        let offsetDB = engine.currentOffsetDB
        if offsetDB > 0.05 { return .white }
        if offsetDB < -0.05 { return .gray }
        return .white.opacity(0.5)
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Advisory Notice
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// The one thing, if any, currently stopping ENVO from adapting.
    ///
    /// All four of these states used to be invisible: ENVO went on reporting an
    /// adjustment while the microphone was in a pocket, while the input was
    /// clipping, while nothing was playing, or while the route quietly discarded
    /// every volume write. A controller that cannot say "I am not able to do
    /// this right now" leaves the user to conclude the app is broken.
    ///
    /// Ordered by how much it matters that the user knows.
    private var advisoryNotice: (title: String, detail: String)? {
        if !volumeController.isVolumeControlAvailable {
            return ("OUTPUT NOT CONTROLLABLE",
                    "This output keeps its own volume, so ENVO can't change the level. AirPlay receivers, HDMI and some external audio devices work this way. Adjust on the device itself, or switch to the phone speaker, headphones or a Bluetooth speaker.")
        }
        if engine.isMicrophoneObstructed {
            return ("MIC COVERED",
                    "The microphone sounds muffled — a pocket, a bag, or the phone lying face-down. ENVO is holding its current adjustment rather than acting on a reading it can't trust. Set the phone down with the bottom edge clear and it will resume on its own.")
        }
        if engine.isInputClipping {
            return ("ROOM TOO LOUD TO MEASURE",
                    "The microphone is at its limit, so the level has stopped tracking the room. ENVO is holding its adjustment until it can measure again.")
        }
        if engine.isWaitingForPlayback {
            return ("NOTHING PLAYING",
                    "ENVO has handed the volume back and is still reading the room. It picks up again as soon as something plays.")
        }
        return nil
    }

    @ViewBuilder
    private var advisoryView: some View {
        if engine.isActive, let notice = advisoryNotice {
            VStack(alignment: .leading, spacing: 4) {
                Text(notice.title)
                    .font(.envo(size: 9))
                    .foregroundColor(.white)
                    .kerning(2)
                Text(notice.detail)
                    .font(.envo(size: 9))
                    .foregroundColor(.gray)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .overlay(
                Rectangle().stroke(Color.white.opacity(0.35), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(notice.title). \(notice.detail)")
        }
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
                            body: "RESPONSE sets how quickly ENVO reacts: SLOW averages over 60 seconds, MED over 30, and FAST over 10. RANGE is a hard limit on the adjustment, not a sensitivity: ±3dB, ±6dB or ±9dB is the most ENVO will ever move, in either direction. DIR controls the direction of adjustment. Enable + to allow volume increases, – for decreases, or both."
                        )

                        infoSection(
                            title: "CALIBRATION",
                            body: "For best results, calibrate ENVO to your room and setup. Calibration plays a test noise at several volume levels and measures how your device speaker sounds to the microphone. This does two things: it lets ENVO separate your music from actual ambient noise, and it measures how much real loudness each step of your volume slider produces. Until you calibrate, ENVO assumes a deliberately cautious volume curve and will adjust by somewhat less than the range you selected. Calibration takes about 35 seconds and is saved until you recalibrate."
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

                        #if DEBUG
                        diagnosticsSection
                        #endif

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
    // MARK: - Diagnostics
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Tuning and verification controls. **Debug builds only** — see
    /// `DiagnosticLog` for why the gate is here and not at each call site.
    ///
    /// Deliberately in the info panel rather than on the main screen: this is for
    /// establishing whether the constants are right on real hardware, which is
    /// not something a listener should trip over by accident. The one exception
    /// is the MARK button, which has to be reachable in one tap while listening —
    /// see `markButton`.
    #if DEBUG
    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DIAGNOSTICS")
                .font(.envo(size: 10))
                .foregroundColor(.white)
                .kerning(4)

            Text("Records one row per second to a CSV file while ENVO runs: measured levels, the six octave bands, the noise floor, the speech scores, the self-coupling estimate and every volume step. Levels only — no audio, and nothing leaves the device unless you share it.\n\nWith the phone tethered to a Mac you can also watch it live in Console.app: filter on category \"diag\".")
                .font(.envo(size: 12))
                .foregroundColor(.white.opacity(0.6))
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(isOn: $settings.diagnosticsEnabled) {
                Text("RECORD A SESSION LOG")
                    .font(.envo(size: 11))
                    .foregroundColor(.white)
                    .kerning(2)
            }
            .tint(.white)

            let logs = DiagnosticLog.shared.existingLogs()
            if let newest = logs.first {
                HStack(spacing: 10) {
                    ShareLink(item: newest) {
                        Text("SHARE NEWEST LOG")
                            .font(.envo(size: 10))
                            .foregroundColor(.black)
                            .kerning(2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.white)
                    }

                    Button(action: {
                        DiagnosticLog.shared.deleteAllLogs()
                        logRefreshToken += 1
                    }) {
                        Text("DELETE ALL")
                            .font(.envo(size: 10))
                            .foregroundColor(.gray)
                            .kerning(2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .overlay(Rectangle().stroke(Color.gray.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }

                Text("\(logs.count) log\(logs.count == 1 ? "" : "s") · newest \(newest.lastPathComponent)")
                    .font(.envo(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }

        }
        .id(logRefreshToken)
    }
    #endif

    /// One tap to stamp "this is the moment it sounded wrong" into the log.
    ///
    /// The whole point of the diagnostic file is to line up numbers against
    /// perception, and perception has to be recorded *when it happens* — a note
    /// written afterwards cannot say which second it referred to. Only shown
    /// while actually recording, so it never clutters normal use.
    @ViewBuilder
    private var markButton: some View {
        #if DEBUG
        if settings.diagnosticsEnabled, engine.isActive {
            Button(action: {
                listenerMarkCount += 1
                DiagnosticLog.shared.mark("#\(listenerMarkCount)")
                Haptics.bump()
            }) {
                Text("MARK \(listenerMarkCount > 0 ? "· \(listenerMarkCount)" : "")")
                    .font(.envo(size: 9))
                    .foregroundColor(.white)
                    .kerning(2)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .overlay(Rectangle().stroke(Color.white.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Mark this moment in the diagnostic log")
        }
        #endif
    }

    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    // MARK: - Actions
    // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    /// Volume readout reads from VolumeController directly. No engine cache.
    private var displayBaseVolume: Int {
        Int((volumeController.baseVolume * 100).rounded())
    }

    /// NOISE/AMBIENT readout. The mic doesn't run in standby, so a number
    /// there would be a frozen lie — show an honest idle placeholder instead.
    /// "—" now also covers the case where our own playback is masking the
    /// room, which is a real state the engine can be in rather than something
    /// to paper over with a stale number.
    /// While ENVO is running this shows the **ambient floor** — the quantity
    /// the engine actually steers on — for calibrated and uncalibrated alike.
    ///
    /// It previously showed the raw microphone level whenever uncalibrated,
    /// which includes your own playback. On a phone playing music that reads
    /// tens of dB above the room: a quiet room could display 90+ dB, which is
    /// simply a different measurement than the label promises.
    private var noiseReadoutValue: String {
        if engine.isActive {
            guard let ambient = engine.displayAmbient else { return "—" }
            return "\(ambient)"
        }
        // Calibration runs the mic without the engine; the raw level is the
        // only thing available then, and it is what calibration measures.
        if audioManager.isMonitoring {
            return "\(audioManager.approximateDB)"
        }
        return "—"
    }

    private var noiseAccessibilityLabel: String {
        noiseReadoutValue == "—"
            ? "Noise idle, not measuring"
            : "Noise \(noiseReadoutValue) decibels"
    }

    /// What the visualizer should pulse to. Raw mic when uncalibrated /
    /// inactive (so the user can still see ENVO is "listening"); estimated
    /// ambient otherwise, so the visual matches what's driving the offset.
    /// Falls back to the raw mic level while the ambient estimate is
    /// unavailable (playback masking the room), so the visualizer keeps
    /// showing that ENVO is listening instead of collapsing to nothing.
    private var visualizerLevel: Float {
        if engine.isActive, engine.estimatedAmbientDB != nil {
            return engine.visualizerLevel
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

    /// Starts the engine and surfaces the reason if it refused. `start()` has
    /// several legitimate ways to decline (no permission, calibration running,
    /// session unavailable) and previously did all of them silently, so a tap
    /// on START could appear to do nothing at all.
    private func startEngineReportingFailure() {
        Haptics.bump()
        engine.start()
        if !engine.isActive, let reason = engine.lastStartFailure {
            Haptics.warning()
            startFailureMessage = reason
        }
    }

    private func toggleEngine() {
        if engine.isActive {
            Haptics.bump()
            engine.stop()
            return
        }
        if audioManager.permissionGranted {
            startEngineReportingFailure()
            return
        }
        // Ask for permission and start only AFTER the user has answered the
        // system prompt. The previous version raced the iOS dialog with a
        // 0.5s timer and could show our fallback alert on top of it.
        audioManager.checkPermission { granted in
            if granted {
                startEngineReportingFailure()
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
