import XCTest

@testable import vless_tunnel_support

/// The tunnel-support module is shared between iOS and macOS. The full suite
/// lives in the macOS example, which can run it on a Mac; this mirrors the
/// cases that are cheap to run on a device.
final class TunnelSupportTests: XCTestCase {

    func testPreparerFillsPortAndCredentials() throws {
        let config = """
        {
          "inbounds": [{"protocol": "socks", "port": 0,
                        "settings": {"auth": "password", "accounts": []}}],
          "outbounds": [{"tag": "proxy", "protocol": "vless",
                         "settings": {"vnext": [{"address": "example.com", "port": 443}]}}]
        }
        """
        let prepared = try TunnelXrayConfigPreparer.prepare(Data(config.utf8))

        XCTAssertGreaterThan(prepared.socksPort, 0)
        XCTAssertEqual(prepared.serverAddress, "example.com")
        XCTAssertFalse(prepared.credentials.username.isEmpty)
    }

    func testCredentialsAreRedactedInDescription() throws {
        let credentials = try ProxyCredentials.random()
        XCTAssertFalse("\(credentials)".contains(credentials.password))
    }
}
