import XCTest

@testable import Dayflow

final class PrivacyOptInTests: XCTestCase {
  @MainActor
  func testDailyBriefRequiresAnExplicitOptIn() {
    let key = "dailyBriefEnabled"
    let defaults = UserDefaults.standard
    let original = defaults.object(forKey: key)
    defer { restore(original, forKey: key) }

    defaults.removeObject(forKey: key)
    XCTAssertFalse(DailyBriefStore.shared.isUserEnabled)
    defaults.set(true, forKey: key)
    XCTAssertTrue(DailyBriefStore.shared.isUserEnabled)
    defaults.set(false, forKey: key)
    XCTAssertFalse(DailyBriefStore.shared.isUserEnabled)
  }

  func testAccessibilityCaptureRequiresAnExplicitOptInEvenInDebug() {
    let key = AccessibilityCaptureConfig.enabledKey
    let defaults = UserDefaults.standard
    let original = defaults.object(forKey: key)
    defer { restore(original, forKey: key) }

    defaults.removeObject(forKey: key)
    XCTAssertFalse(AccessibilityCaptureConfig.isEnabled)
    defaults.set(true, forKey: key)
    XCTAssertTrue(AccessibilityCaptureConfig.isEnabled)
    defaults.set(false, forKey: key)
    XCTAssertFalse(AccessibilityCaptureConfig.isEnabled)
  }

  private func restore(_ value: Any?, forKey key: String) {
    if let value {
      UserDefaults.standard.set(value, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
}
