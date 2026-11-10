//
//  Lifted from flutter_vless (https://github.com/XIIIFOX/flutter_vless), MIT.
//  Copyright (c) 2024-2026 13FOX Studio / tfox.dev.
//  Reduced to the credential type; the surrounding access policy was not taken.
//  See docs/superpowers/specs §16 for provenance.
//

import Foundation
import Security

public enum LocalProxyAccessError: Error {
    case invalidCredentials
    case randomGenerationFailed
}

/// Credentials for the loopback SOCKS inbound.
///
/// Minted fresh per session so no other process on the device can use the
/// proxy, and never logged — `description` is deliberately opaque.
public struct LocalProxyCredentials: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    public let username: String
    public let password: String

    public init(username: String, password: String) throws {
        guard [username, password].allSatisfy({ value in
            (1 ... 255).contains(value.utf8.count)
                && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
        }) else { throw LocalProxyAccessError.invalidCredentials }
        self.username = username
        self.password = password
    }

    /// 128-bit username and 256-bit password from Apple's system CSPRNG.
    public static func generate() throws -> Self {
        var bytes = [UInt8](repeating: 0, count: 48)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw LocalProxyAccessError.randomGenerationFailed
        }
        return try Self(
            username: bytes.prefix(16).map { String(format: "%02x", $0) }.joined(),
            password: bytes.suffix(32).map { String(format: "%02x", $0) }.joined()
        )
    }

    public var socksAuthenticationRequest: Data {
        Data([1, UInt8(username.utf8.count)] + Array(username.utf8)
            + [UInt8(password.utf8.count)] + Array(password.utf8))
    }

    public var description: String { "LocalProxyCredentials(<private>)" }
    public var debugDescription: String { description }
}
