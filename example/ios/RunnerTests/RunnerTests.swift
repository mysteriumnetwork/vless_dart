import NetworkExtension
import XCTest

@testable import vless_dart

/// The plugin's own Swift — the control plane.
///
/// The tunnel-support module moved to vless-apple, which tests it with
/// `swift test` and no signing. Mirroring that suite here only let the copy
/// drift from the one CI actually runs.
final class VPNUtilsTests: XCTestCase {

    func testAnUnsettledConfigurationIsWorthRetrying() {
        for code in [NEVPNError.configurationInvalid, NEVPNError.configurationStale] {
            let error = NSError(domain: NEVPNErrorDomain, code: code.rawValue)
            XCTAssertTrue(VPNUtils.isUnsettledConfiguration(error), "code \(code.rawValue)")
        }
    }

    /// A tunnel that genuinely failed must surface, not be retried into a
    /// timeout the user waits through.
    func testOtherVPNErrorsAreNotRetried() {
        let error = NSError(domain: NEVPNErrorDomain, code: NEVPNError.connectionFailed.rawValue)
        XCTAssertFalse(VPNUtils.isUnsettledConfiguration(error))
    }

    func testTheCodeAloneDoesNotQualifyWithoutTheDomain() {
        let error = NSError(domain: NSURLErrorDomain, code: NEVPNError.configurationStale.rawValue)
        XCTAssertFalse(VPNUtils.isUnsettledConfiguration(error))
    }

    /// The retry budget replaced an unconditional 0.5 s delay; it must not cost
    /// more than what it replaced.
    func testTheRetryBudgetStaysUnderTheOldFixedDelay() {
        let worstCase = Double(VPNUtils.startAttemptLimit - 1) * VPNUtils.startRetryDelay
        XCTAssertLessThanOrEqual(worstCase, 0.5)
    }
}
