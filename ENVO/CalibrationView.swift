import SwiftUI
import AVFoundation

struct CalibrationView: View {
    @EnvironmentObject var audioManager: AudioManager
    @EnvironmentObject var volumeController: VolumeController
    @EnvironmentObject var calibrationStore: CalibrationStore
    @EnvironmentObject var engine: EnvoEngine
    @StateObject private var calibrationManager = CalibrationManager()
    @Environment(\.dismiss) private var dismiss

    @State private var hasStarted = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {

                // MARK: - Header
                HStack {
                    Text("CALIBRATE")
                        .font(.envo(size: 22))
                        .foregroundColor(.white)
                        .kerning(6)

                    Spacer()

                    Button(action: { handleClose() }) {
                        Text("✕")
                            .font(.envo(size: 20))
                            .foregroundColor(.gray)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                Spacer().frame(height: 20)

                // MARK: - Instructions (before start)
                if !hasStarted {
                    instructionsView
                }

                // MARK: - Progress Bar
                if hasStarted && calibrationManager.state != .finished {
                    progressBar
                        .padding(.horizontal, 24)
                        .padding(.bottom, 12)
                }

                // MARK: - Console Output
                if hasStarted {
                    consoleView
                }

                Spacer().frame(height: 20)

                // MARK: - Action Button
                actionButton

                Spacer().frame(height: 24)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            // Attach injected managers so calibration can control volume,
            // read the mic, and persist its result via the store.
            calibrationManager.attach(
                audioManager: audioManager,
                volumeController: volumeController,
                calibrationStore: calibrationStore
            )
        }
        .interactiveDismissDisabled(hasStarted && calibrationManager.state != .finished)
    }

    // MARK: - Instructions

    private var instructionsView: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ROOM SETUP")
                .font(.envo(size: 12))
                .foregroundColor(.white)
                .kerning(4)

            VStack(alignment: .leading, spacing: 12) {
                instructionRow("1", "Place your device where you normally use it.")
                instructionRow("2", "Keep the room as quiet as possible during calibration.")
                instructionRow("3", "ENVO will play a test tone at different volumes and measure how your speaker sounds to the microphone.")
                instructionRow("4", "This takes about 30 seconds.")
            }
            .padding(16)
            .overlay(
                Rectangle()
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )

            loudnessWarning

            Text("After calibration, ENVO can distinguish between your music and ambient noise — preventing feedback loops where the volume drifts up or down uncontrollably.")
                .font(.envo(size: 11))
                .foregroundColor(.gray)
                .lineSpacing(4)

            if calibrationStore.isCalibrated {
                Text("QUICK RECAL refreshes only the room's silence floor — fast and useful when the room hasn't physically changed but feels noisier or quieter than before.")
                    .font(.envo(size: 11))
                    .foregroundColor(.gray)
                    .lineSpacing(4)
            }
        }
        .padding(.horizontal, 24)
    }

    /// Calibration sweeps the test noise up to 100% device volume.
    /// A cable-connected speaker is a legitimate setup, so this warns
    /// rather than blocks — but headphones must come off.
    private var loudnessWarning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isExternalOutputRoute ? "⚠ EXTERNAL OUTPUT CONNECTED" : "⚠ LOUD TEST NOISE")
                .font(.envo(size: 11))
                .foregroundColor(.yellow)
                .kerning(3)

            Text("Calibration plays test noise up to 100% device volume. Never wear headphones during calibration. A cable- or Bluetooth-connected speaker is fine.")
                .font(.envo(size: 11))
                .foregroundColor(.yellow.opacity(0.8))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)

            if isExternalOutputRoute {
                Text("Audio is currently routed to \(currentOutputName). If these are headphones, take them off before starting.")
                    .font(.envo(size: 11))
                    .foregroundColor(.yellow.opacity(0.8))
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .overlay(
            Rectangle()
                .stroke(Color.yellow.opacity(0.5), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private var isExternalOutputRoute: Bool {
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver
        }
    }

    private var currentOutputName: String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "an external device"
    }

    private func instructionRow(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.envo(size: 14))
                .foregroundColor(.white)
                .frame(width: 20, alignment: .trailing)

            Text(text)
                .font(.envo(size: 12))
                .foregroundColor(.white.opacity(0.8))
                .lineSpacing(3)
        }
    }

    // MARK: - Progress Bar

    private var progressBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 4)

                    Rectangle()
                        .fill(Color.white)
                        .frame(width: geo.size.width * CGFloat(calibrationManager.progress), height: 4)
                        .animation(.easeInOut(duration: 0.3), value: calibrationManager.progress)
                }
            }
            .frame(height: 4)

            Text(stateLabel)
                .font(.envo(size: 9))
                .foregroundColor(.gray)
                .kerning(2)
        }
    }

    private var stateLabel: String {
        switch calibrationManager.state {
        case .idle: return "READY"
        case .measuringSilence: return "MEASURING SILENCE"
        case .measuringVolume(let step, let total, let vol):
            return "STEP \(step)/\(total) — \(Int(vol * 100))%"
        case .finished: return "COMPLETE"
        case .error(let msg): return "ERROR: \(msg)"
        }
    }

    // MARK: - Console

    private var consoleView: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(calibrationManager.logLines.enumerated()), id: \.offset) { index, line in
                        Text(line)
                            .font(.system(size: 11, weight: .regular, design: .monospaced))
                            .foregroundColor(lineColor(for: line))
                            .id(index)
                    }
                }
                .padding(12)
            }
            .background(Color.white.opacity(0.03))
            .overlay(
                Rectangle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .padding(.horizontal, 24)
            .onChange(of: calibrationManager.logLines.count) { _ in
                withAnimation {
                    proxy.scrollTo(calibrationManager.logLines.count - 1, anchor: .bottom)
                }
            }
        }
    }

    private func lineColor(for line: String) -> Color {
        if line.hasPrefix("───") { return .white }
        if line.hasPrefix("STEP") { return .white.opacity(0.9) }
        if line.contains("█") { return .white.opacity(0.7) }
        if line.hasPrefix("Warning") { return .yellow }
        return .white.opacity(0.5)
    }

    // MARK: - Action Button

    private var actionButton: some View {
        Group {
            if !hasStarted {
                VStack(spacing: 10) {
                    Button(action: {
                        // Resolve mic permission first — launch no longer
                        // pre-prompts, so this may be the first ask.
                        audioManager.checkPermission { _ in
                            hasStarted = true
                            calibrationManager.startCalibration()
                        }
                    }) {
                        Text("FULL CALIBRATION")
                            .font(.envo(size: 16))
                            .foregroundColor(.black)
                            .kerning(4)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Color.white)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Full calibration, about 30 seconds")

                    // Quick recal only makes sense when a profile already exists.
                    if calibrationStore.isCalibrated {
                        Button(action: {
                            audioManager.checkPermission { _ in
                                hasStarted = true
                                calibrationManager.startQuickRecalibration()
                            }
                        }) {
                            Text("QUICK RECAL · 5s")
                                .font(.envo(size: 12))
                                .foregroundColor(.white)
                                .kerning(3)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .overlay(
                                    Rectangle()
                                        .stroke(Color.white.opacity(0.4), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Quick recalibration, silence floor only")
                    }
                }
                .padding(.horizontal, 24)
            } else if calibrationManager.state == .finished {
                Button(action: {
                    // CalibrationManager already saved into the store; no
                    // extra reload step needed — engine observes the store.
                    dismiss()
                }) {
                    Text("DONE")
                        .font(.envo(size: 16))
                        .foregroundColor(.black)
                        .kerning(4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            } else {
                Button(action: {
                    calibrationManager.cancelCalibration()
                    dismiss()
                }) {
                    Text("CANCEL")
                        .font(.envo(size: 14))
                        .foregroundColor(.white)
                        .kerning(4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .overlay(
                            Rectangle()
                                .stroke(Color.white.opacity(0.4), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
            }
        }
    }

    // MARK: - Close

    private func handleClose() {
        if hasStarted && calibrationManager.state != .finished {
            calibrationManager.cancelCalibration()
        }
        dismiss()
    }
}
