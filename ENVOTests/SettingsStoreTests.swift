import XCTest
@testable import ENVO

final class SettingsStoreTests: XCTestCase {

    /// Isolated UserDefaults so tests don't touch the real app's prefs.
    private func makeDefaults(_ suite: String = UUID().uuidString) -> UserDefaults {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testDefaultsAreSane() {
        let store = SettingsStore(defaults: makeDefaults())
        XCTAssertEqual(store.speedMode, .medium)
        XCTAssertEqual(store.rangeMode, .medium)
        XCTAssertTrue(store.allowIncrease)
        XCTAssertTrue(store.allowDecrease)
        XCTAssertFalse(store.autoResume)
        XCTAssertFalse(store.wasActive)
        XCTAssertFalse(store.hasCompletedOnboarding)
    }

    func testChangesPersist() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        do {
            let s1 = SettingsStore(defaults: defaults)
            s1.speedMode = .fast
            s1.rangeMode = .loud
            s1.allowIncrease = false
            s1.autoResume = true
            s1.hasCompletedOnboarding = true
        }

        let s2 = SettingsStore(defaults: defaults)
        XCTAssertEqual(s2.speedMode, .fast)
        XCTAssertEqual(s2.rangeMode, .loud)
        XCTAssertFalse(s2.allowIncrease)
        XCTAssertTrue(s2.allowDecrease)
        XCTAssertTrue(s2.autoResume)
        XCTAssertTrue(s2.hasCompletedOnboarding)
    }

    func testUnknownEnumStringFallsBackToDefault() {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set("UNKNOWN_VALUE", forKey: "envo.settings.speedMode")

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.speedMode, .medium)
    }
}
