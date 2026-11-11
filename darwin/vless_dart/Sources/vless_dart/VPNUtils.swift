import Foundation
import NetworkExtension
import os

#if os(iOS)
    import Flutter
#elseif os(macOS)
    import FlutterMacOS
#endif

/// Mirrors `TunnelProviderMessages.stats` in vless_tunnel_support.
///
/// Deliberately duplicated rather than imported: the plugin runs in the app
/// process, and importing the support module would pull the Xray core — and a
/// second Go runtime — in alongside WireGuard's, which fails to link.
private let vlessStatsProviderMessage = "VLESS_STATS"

/// Owns the `NETunnelProviderManager` lifecycle.
///
/// Adapted from `openvpn_dart`'s `VPNUtils`. The differences are deliberate:
/// the server address is read out of the Xray JSON rather than an `.ovpn`
/// `remote` line, and `.reasserting` maps to `connecting` so a provider that is
/// up but not yet forwarding never shows as connected.
class VPNUtils {
    var providerManager: NETunnelProviderManager?
    var providerBundleIdentifier: String?
    var localizedDescription: String?
    var status: FlutterEventSink?
    private var vpnStatusObserver: NSObjectProtocol?

    /// Picks only our own manager. The host app also has WireGuard and OpenVPN
    /// configurations, and adopting one of those would make `configureVPN`
    /// overwrite another protocol's saved profile.
    private func ours(_ managers: [NETunnelProviderManager]?) -> NETunnelProviderManager? {
        guard let bundleId = providerBundleIdentifier else { return nil }
        return managers?.first {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                .providerBundleIdentifier == bundleId
        }
    }

    func loadProviderManager(completion: @escaping (Error?) -> Void) {
        NETunnelProviderManager.loadAllFromPreferences { managers, error in
            if let error {
                completion(error)
            } else {
                self.providerManager = self.ours(managers)
                // Observe from here, not from connect: a relaunch over a live
                // tunnel, or a change made in Settings, must still report status.
                self.observeStatus()
                completion(nil)
            }
        }
    }

    func currentStatus() -> String {
        guard let manager = providerManager else { return "disconnected" }
        return Self.string(from: manager.connection.status)
    }

    /// A provider that has started but is not yet forwarding sets `reasserting`,
    /// so mapping it to `connecting` is what keeps the UI honest — see the
    /// design spec, §9.
    private static func string(from status: NEVPNStatus) -> String {
        switch status {
        case .connected: return "connected"
        case .connecting, .reasserting: return "connecting"
        case .disconnecting: return "disconnecting"
        case .disconnected, .invalid: return "disconnected"
        @unknown default: return "unknown"
        }
    }

    func checkTunnelConfiguration(result: @escaping (NETunnelProviderManager?) -> Void) {
        guard let bundleId = providerBundleIdentifier else {
            result(nil)
            return
        }
        Task {
            do {
                let managers = try await NETunnelProviderManager.loadAllFromPreferences()
                let existing = managers.first {
                    ($0.protocolConfiguration as? NETunnelProviderProtocol)?
                        .providerBundleIdentifier == bundleId
                }
                if let existing {
                    self.providerManager = existing
                    self.observeStatus()
                }
                result(existing)
            } catch {
                result(nil)
            }
        }
    }

    func setupTunnel(completion: @escaping (Error?) -> Void) {
        checkTunnelConfiguration { existing in
            if let existing {
                self.providerManager = existing
                completion(nil)
                return
            }

            guard let bundleId = self.providerBundleIdentifier else {
                completion(Self.error(-1, "providerBundleIdentifier not set"))
                return
            }

            let manager = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = bundleId
            proto.serverAddress = "127.0.0.1"
            proto.disconnectOnSleep = false

            manager.protocolConfiguration = proto
            manager.localizedDescription = self.localizedDescription
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError {
                    completion(saveError)
                    return
                }
                NETunnelProviderManager.loadAllFromPreferences { managers, error in
                    if let error {
                        completion(error)
                        return
                    }
                    self.providerManager = self.ours(managers) ?? manager
                    self.observeStatus()
                    completion(nil)
                }
            }
        }
    }

    func configureVPN(config: String, completion: @escaping (Error?) -> Void) {
        guard let manager = providerManager else {
            completion(Self.error(-10, "Tunnel not initialized. Call setupTunnel first."))
            return
        }
        guard let configData = config.data(using: .utf8) else {
            completion(Self.error(-1, "Failed to encode Xray config"))
            return
        }

        manager.loadFromPreferences { [weak self] error in
            guard let self else { return }
            if let error {
                completion(error)
                return
            }

            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = self.providerBundleIdentifier
            proto.serverAddress = Self.serverAddress(fromXrayConfig: configData)
            proto.disconnectOnSleep = false
            proto.providerConfiguration = ["config": configData]

            manager.protocolConfiguration = proto
            manager.localizedDescription = self.localizedDescription
            manager.isEnabled = true

            manager.saveToPreferences { saveError in
                if let saveError {
                    completion(saveError)
                    return
                }
                // saveToPreferences is not fully settled when its completion
                // fires; starting immediately races it.
                self.startTunnel(on: manager, attempt: 0, completion: completion)
            }
        }
    }

    /// Starts the tunnel, reloading preferences and retrying while the save is
    /// still settling.
    ///
    /// Replaces a fixed delay before the first attempt, which was simultaneously
    /// too long on a warm device — half a second added to every connect — and
    /// too short on a cold or loaded one, where it surfaced as "Failed to start
    /// VPN" and a connect the user had to tap twice.
    private func startTunnel(
        on manager: NETunnelProviderManager,
        attempt: Int,
        completion: @escaping (Error?) -> Void
    ) {
        do {
            try manager.connection.startVPNTunnel(options: [:])
            observeStatus()
            completion(nil)
        } catch {
            guard attempt + 1 < Self.startAttemptLimit, Self.isUnsettledConfiguration(error) else {
                stopVPN()
                completion(error)
                return
            }
            // Best effort: a failed reload still leaves the retry worth taking,
            // and the start error is the one worth reporting if they run out.
            manager.loadFromPreferences { _ in
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.startRetryDelay) {
                    self.startTunnel(on: manager, attempt: attempt + 1, completion: completion)
                }
            }
        }
    }

    /// Bounded at roughly 0.45 s total, well under the old unconditional 0.5 s.
    static let startAttemptLimit = 4
    static let startRetryDelay: TimeInterval = 0.15

    /// The NEVPNError cases that mean the saved configuration has not landed
    /// yet, as opposed to a configuration that is actually wrong.
    static func isUnsettledConfiguration(_ error: Error) -> Bool {
        let error = error as NSError
        guard error.domain == NEVPNErrorDomain else { return false }
        return error.code == NEVPNError.configurationInvalid.rawValue
            || error.code == NEVPNError.configurationStale.rawValue
    }

    /// Asks the extension for its byte counters. Hands back nil when the tunnel
    /// is down, the extension declines, or it never answers.
    func tunnelStatistics(completion: @escaping (String?) -> Void) {
        guard let session = providerManager?.connection as? NETunnelProviderSession,
              session.status == .connected
        else {
            completion(nil)
            return
        }

        // Both the reply and the timeout hop to the main queue, so this flag is
        // only ever touched there — a FlutterResult must not be called twice.
        var didRespond = false
        var timeout: DispatchWorkItem?
        let respond: (String?) -> Void = { json in
            DispatchQueue.main.async {
                guard !didRespond else { return }
                didRespond = true
                // cancel() alone leaves the work item — and through it this
                // closure and the completion — retained, so drop the reference.
                timeout?.cancel()
                timeout = nil
                completion(json)
            }
        }
        timeout = DispatchWorkItem { respond(nil) }

        do {
            try session.sendProviderMessage(Data(vlessStatsProviderMessage.utf8)) { response in
                respond(response.flatMap { String(data: $0, encoding: .utf8) })
            }
            // An extension that never replies would otherwise leave the Dart
            // future pending forever and stall the caller's poll loop.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: timeout!)
        } catch {
            respond(nil)
        }
    }

    func stopVPN() {
        providerManager?.connection.stopVPNTunnel()
    }

    func removeTunnelConfiguration(completion: @escaping (Error?) -> Void) {
        guard let manager = providerManager else {
            // Reporting success here would claim a removal that never happened.
            completion(Self.error(-11, "No tunnel configuration to remove"))
            return
        }
        manager.removeFromPreferences { error in
            if error == nil {
                self.providerManager = nil
            }
            completion(error)
        }
    }

    /// Shown in the system VPN settings. Read from the VLESS outbound so it
    /// names the real server rather than a placeholder.
    private static func serverAddress(fromXrayConfig data: Data) -> String {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let outbounds = root["outbounds"] as? [[String: Any]],
              let proxy = outbounds.first(where: { $0["tag"] as? String == "proxy" }),
              let settings = proxy["settings"] as? [String: Any],
              let vnext = (settings["vnext"] as? [[String: Any]])?.first,
              let address = vnext["address"] as? String
        else {
            return "127.0.0.1"
        }
        return address
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(domain: "VlessDart", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }

    func observeStatus() {
        if let observer = vpnStatusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        guard let connection = providerManager?.connection else { return }
        vpnStatusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: connection,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let current = Self.string(from: self.providerManager?.connection.status ?? .invalid)
            self.status?(current)
            os_log("[VPNUTILS] status: %@", current)
        }
    }
}
