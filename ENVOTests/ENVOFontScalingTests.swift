import XCTest
@testable import ENVO

final class ENVOFontScalingTests: XCTestCase {

    func testScaledSizeIsAlwaysAtLeastInput() {
        // The brutalist design's sizes are deliberate; Dynamic Type may
        // scale UP for accessibility but must never shrink them.
        for size in [CGFloat(9), 12, 14, 22, 28] {
            let result = ENVOFontScaling.scale(size: size)
            XCTAssertGreaterThanOrEqual(
                result, size,
                "Font size \(size) shrank to \(result)"
            )
        }
    }

    func testScaledSizeRespectsCap() {
        // The cap is 1.35×. With the largest accessibility size,
        // raw scaledValue can be ~2× input. We must clamp.
        let size: CGFloat = 14
        let result = ENVOFontScaling.scale(size: size)
        XCTAssertLessThanOrEqual(result, size * ENVOFontScaling.maxMultiplier + 0.5)
    }
}
