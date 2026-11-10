//
//  Shared packet tunnel provider for iOS and macOS.
//
//  Structure follows flutter_vless's provider (MIT, 13FOX Studio); the Xray and
//  hev wiring below is adapted from it. See docs/superpowers/specs §16.
//
//  Each platform's extension target subclasses this, so the data plane lives in
//  one place rather than being copied per platform.
//

import Foundation
import NetworkExtension
import Tun2SocksKit
import XRay
import os

private let tunnelMTU = 1500
private let tunnelAddress = "198.18.0.1"
private let hevStartupGrace: TimeInterval = 0.25
private let hevShutdownTimeout: TimeInterval = 2

private let log = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "vless_dart.tunnel",
    category: "tunnel"
)

open class VlessPacketTunnelProvider: NEPacketTunnelProvider {
    private let hev = TunnelProcessLifecycle()
    private let runtimeQueue = DispatchQueue(label: "com.mysteriumvpn.vless.runtime")
    private var hevLogURL: URL?
    private var started = false

    override public init() { super.init() }

    override open func startTunnel(
        options _: [String: NSObject]?,
        completionHandler: @escaping (Error?) -> Void
    ) {
        os_log("[TUNNEL] startTunnel", log: log, type: .info)

        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let raw = proto.providerConfiguration?["config"] as? Data
        else {
            completionHandler(TunnelConfigError.malformedConfig)
            return
        }

        let prepared: PreparedTunnelConfig
        do {
            prepared = try TunnelXrayConfigPreparer.prepare(raw)
        } catch {
            os_log("[TUNNEL] config prepare failed: %@", log: log, type: .error, "\(error)")
            completionHandler(error)
            return
        }

        // Not yet forwarding — the app maps `reasserting` to `connecting`, so
        // the UI cannot show connected over a tunnel that drops packets.
        reasserting = true

        applyNetworkSettings(serverAddress: prepared.serverAddress) { [weak self] error in
            guard let self else { return }
            if let error {
                completionHandler(error)
                return
            }
            self.runtimeQueue.async {
                do {
                    try self.startRuntime(prepared)
                    self.reasserting = false
                    self.started = true
                    os_log("[TUNNEL] forwarding ready", log: log, type: .info)
                    completionHandler(nil)
                } catch {
                    os_log("[TUNNEL] start failed: %@", log: log, type: .error, "\(error)")
                    self.teardown()
                    completionHandler(error)
                }
            }
        }
    }

    override open func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        os_log("[TUNNEL] stopTunnel: %d", log: log, type: .info, reason.rawValue)
        teardown()
        completionHandler()
    }

    override open func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard String(data: messageData, encoding: .utf8) == vlessStatsProviderMessage else {
            completionHandler?(nil)
            return
        }
        let stats = Socks5Tunnel.stats
        let payload: [String: Any] = [
            "totalDownload": stats.down.bytes,
            "totalUpload": stats.up.bytes,
            "latestHandshake": 0,
        ]
        completionHandler?(try? JSONSerialization.data(withJSONObject: payload))
    }

    // MARK: - Runtime

    private func startRuntime(_ prepared: PreparedTunnelConfig) throws {
        XRaySetMemoryLimit()

        var xrayError: NSError?
        XRayStart(prepared.config, &xrayError)
        if let xrayError { throw xrayError }

        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("hev-socks5-tunnel.log")
        hevLogURL = logURL

        let hevConfig = TunnelHEVConfiguration.make(
            port: prepared.socksPort,
            credentials: prepared.credentials,
            mtu: tunnelMTU,
            logURL: logURL
        )

        hev.beginStart()
        Thread {
            self.hev.markThreadEntered()
            guard !self.hev.isStopRequested else {
                _ = self.hev.markExited(code: 0)
                return
            }
            let code = Socks5Tunnel.run(withConfig: .string(content: hevConfig))
            _ = self.hev.markExited(code: code)
        }.start()

        switch hev.waitForStableStartup(gracePeriod: hevStartupGrace) {
        case .running:
            return
        default:
            throw TunnelConfigError.noFreePort
        }
    }

    private func teardown() {
        guard started || hev.isRunning else {
            XRayStop()
            return
        }
        started = false
        if hev.requestStop(), !hev.waitForExit(timeout: hevShutdownTimeout) {
            Socks5Tunnel.quit()
        }
        XRayStop()
    }

    // MARK: - Network settings

    /// The direct route for [serverAddress] is load-bearing: without it the
    /// tunnel routes its own VLESS transport back into itself and deadlocks.
    private func applyNetworkSettings(
        serverAddress: String,
        completion: @escaping (Error?) -> Void
    ) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: serverAddress)
        settings.mtu = NSNumber(value: tunnelMTU)

        let ipv4 = NEIPv4Settings(addresses: [tunnelAddress], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        if let serverIP = resolve(serverAddress) {
            ipv4.excludedRoutes = [NEIPv4Route(destinationAddress: serverIP,
                                               subnetMask: "255.255.255.255")]
        }
        settings.ipv4Settings = ipv4

        let dns = NEDNSSettings(servers: [TunnelDNSPolicy.virtualServer])
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        setTunnelNetworkSettings(settings, completionHandler: completion)
    }

    private func resolve(_ host: String) -> String? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }

        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard let addr = first.pointee.ai_addr else { return nil }
        let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var sinAddr = sin.sin_addr
        guard inet_ntop(AF_INET, &sinAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return nil
        }
        return String(cString: buffer)
    }
}
