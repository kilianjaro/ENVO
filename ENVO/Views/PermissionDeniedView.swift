import SwiftUI
import UIKit

/// Shown in place of the main screen when the user has explicitly denied
/// microphone access. ENVO is fundamentally unable to function without the
/// mic, so we surface a clear instructions panel rather than letting the
/// user mash a START button that silently refuses.
struct PermissionDeniedView: View {

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer().frame(height: 24)

                Text("ENVO")
                    .font(.envo(size: 28))
                    .foregroundColor(.white)
                    .kerning(8)

                Spacer()

                VStack(alignment: .leading, spacing: 16) {
                    Text("MICROPHONE OFF")
                        .font(.envo(size: 14))
                        .foregroundColor(.white)
                        .kerning(4)
                        .accessibilityAddTraits(.isHeader)

                    Rectangle()
                        .fill(Color.white.opacity(0.4))
                        .frame(width: 40, height: 1)

                    Text("ENVO needs the microphone to measure ambient noise. No audio is recorded or stored.")
                        .font(.envo(size: 12))
                        .foregroundColor(.white.opacity(0.75))
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("To enable: Settings ▸ ENVO ▸ Microphone")
                        .font(.envo(size: 11))
                        .foregroundColor(.gray)
                        .lineSpacing(4)
                }
                .padding(20)
                .overlay(
                    Rectangle()
                        .stroke(Color.white.opacity(0.2), lineWidth: 1)
                )
                .padding(.horizontal, 24)

                Spacer()

                Button(action: openSettings) {
                    Text("OPEN SETTINGS")
                        .font(.envo(size: 16))
                        .foregroundColor(.black)
                        .kerning(4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .accessibilityLabel("Open Settings to enable microphone")

                Spacer().frame(height: 32)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func openSettings() {
        Haptics.tap()
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }
}
