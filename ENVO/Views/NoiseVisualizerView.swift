import SwiftUI

/// A brutalist visualization that reacts to ambient noise level.
/// Noise spikes flash on quickly but fade out slowly (ease-out decay).
struct NoiseVisualizerView: View {
    let normalizedLevel: Float
    let isActive: Bool
    let levelHistory: [Float]

    @State private var phase: Double = 0.0

    /// The display level used for rendering. Rises instantly with noise
    /// but decays slowly, creating the lingering flash / ease-out effect.
    @State private var displayLevel: Float = 0.0

    /// Tracks the peak for an extra-bright flash layer.
    @State private var peakLevel: Float = 0.0

    private let columns = 16
    private let rows = 6
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// How fast the display level decays toward the real level (0…1).
    /// Lower = slower fade. 0.04 ≈ ~0.7 seconds to fade to half.
    private let decayRate: Float = 0.04

    /// How fast the peak flash fades (even slower for dramatic effect).
    private let peakDecayRate: Float = 0.025

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // Background grid of reactive blocks
                Canvas { context, size in
                    drawBlocks(context: context, size: size)
                }

                // Center waveform line
                if isActive {
                    waveformOverlay(size: geo.size)
                }

                // Border frame
                Rectangle()
                    .stroke(Color.white.opacity(0.3), lineWidth: 1)
            }
        }
        .onReceive(timer) { _ in
            guard isActive else {
                displayLevel = 0
                peakLevel = 0
                return
            }

            phase += 0.04

            let current = normalizedLevel

            // Instant rise: if noise is louder than display, snap up.
            // Slow decay: if noise is quieter, ease down gradually.
            if current > displayLevel {
                displayLevel = current
            } else {
                displayLevel += (current - displayLevel) * decayRate
            }

            // Peak tracking: captures spikes and fades even slower.
            if current > peakLevel {
                peakLevel = current
            } else {
                peakLevel += (0 - peakLevel) * peakDecayRate
            }
        }
    }

    // MARK: - Block Grid

    private func drawBlocks(context: GraphicsContext, size: CGSize) {
        let blockW = size.width / CGFloat(columns)
        let blockH = size.height / CGFloat(rows)
        let level = CGFloat(displayLevel)
        let peak = CGFloat(peakLevel)

        for row in 0..<rows {
            for col in 0..<columns {
                let x = CGFloat(col) * blockW
                let y = CGFloat(row) * blockH

                let cx = CGFloat(columns) / 2.0
                let cy = CGFloat(rows) / 2.0
                let dx = (CGFloat(col) - cx) / cx
                let dy = (CGFloat(row) - cy) / cy
                let dist = sqrt(dx * dx + dy * dy)

                // Wave pattern based on distance + phase.
                let wave = sin(dist * 4.0 + phase * 2.0) * 0.5 + 0.5

                // Base intensity from smoothed display level.
                let baseIntensity = level * CGFloat(wave)

                // Peak flash: brighter layer from recent spikes.
                let peakIntensity = peak * CGFloat(wave) * 0.3

                let intensity = baseIntensity + peakIntensity

                guard intensity > 0.04 else { continue }

                let opacity = isActive ? min(intensity * 1.2, 1.0) : 0.03

                let inset: CGFloat = 1.5
                let rect = CGRect(
                    x: x + inset,
                    y: y + inset,
                    width: blockW - inset * 2,
                    height: blockH - inset * 2
                )

                context.fill(
                    Path(rect),
                    with: .color(.white.opacity(opacity))
                )
            }
        }
    }

    // MARK: - Waveform Overlay

    private func waveformOverlay(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let midY = canvasSize.height / 2.0
            // Waveform also uses the slow-decaying display level.
            let level = CGFloat(displayLevel)

            var path = Path()
            let segments = 80

            for i in 0...segments {
                let t = CGFloat(i) / CGFloat(segments)
                let x = t * canvasSize.width

                let freq1 = sin(t * .pi * 6.0 + phase * 3.0)
                let freq2 = sin(t * .pi * 10.0 - phase * 1.5) * 0.4
                let freq3 = sin(t * .pi * 16.0 + phase * 5.0) * 0.15

                let envelope = sin(t * .pi)
                let amplitude = level * 60.0 * envelope
                let y = midY + (freq1 + freq2 + freq3) * amplitude

                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(path, with: .color(.white.opacity(0.9)), lineWidth: 1.5)
            context.stroke(path, with: .color(.white.opacity(0.15)), lineWidth: 6)
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        NoiseVisualizerView(
            normalizedLevel: 0.5,
            isActive: true,
            levelHistory: Array(repeating: 0.5, count: 30)
        )
        .frame(height: 200)
        .padding()
    }
}
