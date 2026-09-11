import XCTest
@testable import TunkCore

/// A disabled onset ceiling (`onsetCeilingG = nil`) must survive a
/// persist/relaunch. Before the fix, `encode(to:)` omitted the key for nil and
/// `init(from:)` read an absent key as the 2.5 g default, so "off" silently
/// came back as "on" at the next launch.
final class AuditConfigRoundTripTests: XCTestCase {

    func testDisabledOnsetCeilingSurvivesRoundTrip() throws {
        var config = DetectorConfig.default
        config.onsetCeilingG = nil
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(DetectorConfig.self, from: data)
        XCTAssertNil(back.onsetCeilingG,
                     "a disabled ceiling came back as \(String(describing: back.onsetCeilingG)) after one persist/relaunch")
    }

    /// An explicit JSON null is the disabled state, not "use the default".
    func testExplicitNullDecodesAsDisabled() throws {
        let json = """
        {"sensitivity":1.0,"defaultThreshold":0.032,"gateWindowNs":180000000,
         "minInterTapNs":100000000,"maxInterTapNs":220000000,
         "confirmWindowNs":220000000,"refractoryNs":600000000,
         "armedTapCounts":[2],"onsetCeilingG":null,"motionGateG":0}
        """
        let back = try JSONDecoder().decode(DetectorConfig.self, from: Data(json.utf8))
        XCTAssertNil(back.onsetCeilingG)
    }

    /// A settings file written before the ceiling existed still loads with the
    /// default ceiling; only an explicit null means disabled.
    func testAbsentKeyStillMeansDefault() throws {
        let json = """
        {"sensitivity":1.0,"defaultThreshold":0.032,"gateWindowNs":180000000,
         "minInterTapNs":100000000,"maxInterTapNs":220000000,
         "confirmWindowNs":220000000,"refractoryNs":600000000,"tapCountToFire":2}
        """
        let back = try JSONDecoder().decode(DetectorConfig.self, from: Data(json.utf8))
        XCTAssertEqual(back.onsetCeilingG, DetectorConfig.default.onsetCeilingG)
    }
}
