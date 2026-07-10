import SwiftUI

/// Three-step intro shown the first time the app launches.
/// Sets `settings.hasCompletedOnboarding = true` when dismissed.
struct OnboardingView: View {
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var page: Int = 0

    private let pages: [Page] = [
        Page(
            title: "LISTENS",
            body: "ENVO reads ambient noise through your microphone — only as instantaneous power levels. No audio is recorded, stored, or transmitted."
        ),
        Page(
            title: "ADAPTS",
            body: "When the room gets louder, ENVO nudges your volume up. When it quiets down, it eases back. Your chosen volume is always the baseline."
        ),
        Page(
            title: "STAY IN CONTROL",
            body: "Hardware buttons and Control Center always win. Any volume change you make becomes the new baseline immediately. RANGE caps how far ENVO will go."
        )
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer().frame(height: 30)

                Text("ENVO")
                    .font(.envo(size: 28))
                    .foregroundColor(.white)
                    .kerning(8)

                Spacer()

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { idx, p in
                        pageView(p).tag(idx)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity)

                // Manual dots so we control color.
                HStack(spacing: 8) {
                    ForEach(0..<pages.count, id: \.self) { i in
                        Circle()
                            .fill(i == page ? Color.white : Color.white.opacity(0.25))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.vertical, 24)

                Spacer()

                Button(action: advance) {
                    Text(page == pages.count - 1 ? "BEGIN" : "NEXT")
                        .font(.envo(size: 16))
                        .foregroundColor(.black)
                        .kerning(4)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(Color.white)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
                .accessibilityLabel(page == pages.count - 1 ? "Begin" : "Next page")
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }

    private func pageView(_ p: Page) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(p.title)
                .font(.envo(size: 18))
                .foregroundColor(.white)
                .kerning(6)
                .accessibilityAddTraits(.isHeader)

            Rectangle()
                .fill(Color.white.opacity(0.4))
                .frame(width: 40, height: 1)

            Text(p.body)
                .font(.envo(size: 14))
                .foregroundColor(.white.opacity(0.75))
                .lineSpacing(6)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(.horizontal, 32)
    }

    private func advance() {
        Haptics.tap()
        if page < pages.count - 1 {
            page += 1
        } else {
            settings.hasCompletedOnboarding = true
            dismiss()
        }
    }

    private struct Page {
        let title: String
        let body: String
    }
}
