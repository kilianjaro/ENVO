import SwiftUI
import UIKit

/// Extension to gracefully handle the custom HemingVariable font.
/// Falls back to a system monospaced font if the custom font is not installed.
extension Font {

    /// Creates the ENVO branded font at the given size.
    /// Tries HemingVariable first, falls back to system monospaced bold.
    ///
    /// Scales with Dynamic Type within a sensible range so the layout
    /// (fixed grid of 30/40/30 readout columns, tightly-packed mode
    /// selectors) stays intact at the largest accessibility sizes.
    static func envo(size: CGFloat) -> Font {
        let scaled = ENVOFontScaling.scale(size: size)

        // Try exact PostScript name variants the font might register as.
        let candidates = [
            "HemingVariable",
            "Heming-Variable",
            "HemingVariable-Regular",
            "Heming Variable"
        ]

        for name in candidates {
            if UIFont(name: name, size: scaled) != nil {
                return .custom(name, size: scaled)
            }
        }

        return .system(size: scaled, weight: .bold, design: .monospaced)
    }
}

/// Pulled out so the scale rule is testable and consistent.
enum ENVOFontScaling {

    /// Maximum scale multiplier. The layout uses fixed-width readout
    /// columns; allowing arbitrary scaling causes "100 %" to clip.
    static let maxMultiplier: CGFloat = 1.35

    /// Minimum scale multiplier. The brutalist design's sizes are
    /// deliberate; we never shrink below them just because the user's
    /// Dynamic Type setting is small. Accessibility scaling is one-way:
    /// up only.
    static let minMultiplier: CGFloat = 1.0

    static func scale(size: CGFloat) -> CGFloat {
        guard size > 0 else { return size }
        let metrics = UIFontMetrics(forTextStyle: .body)
        let scaled = metrics.scaledValue(for: size)
        let multiplier = scaled / size
        let bounded = min(max(multiplier, minMultiplier), maxMultiplier)
        return (size * bounded).rounded()
    }
}
