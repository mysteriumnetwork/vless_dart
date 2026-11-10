import NetworkExtension
import os

#if os(iOS)
    import Flutter
    import UIKit
#elseif os(macOS)
    import Cocoa
    import FlutterMacOS
#else
    #error("Unsupported platform")
#endif

/// Control plane for the VLESS tunnel.
///
/// Drives `NETunnelProviderManager` and hands the Xray config to the packet
/// tunnel extension; it never touches packets itself. Ported from
/// `openvpn_dart`'s plugin so both engines behave identically from Dart.
public class VlessDartPlugin: NSObject, FlutterPlugin {
    private static var utils: VPNUtils! = VPNUtils()

    private static let eventChannelVpnStatus = "id.mysteriumvpn.vless_dart/vpnstatus"
    private static let methodChannelVpnControl = "id.mysteriumvpn.vless_dart/vpncontrol"

    private var initialized = false

    /// Held for the process lifetime. Nothing else owns the plugin — the
    /// channel only holds the handler closure — so without this the instance
    /// deallocates immediately and every method call silently never replies.
    private static var shared: VlessDartPlugin?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let plugin = VlessDartPlugin()
        shared = plugin
        plugin.onRegister(registrar)
    }

    public func onRegister(_ registrar: FlutterPluginRegistrar) {
        #if os(iOS)
            let messenger = registrar.messenger()
        #else
            let messenger = registrar.messenger
        #endif

        let control = FlutterMethodChannel(
            name: VlessDartPlugin.methodChannelVpnControl,
            binaryMessenger: messenger)
        let status = FlutterEventChannel(
            name: VlessDartPlugin.eventChannelVpnStatus,
            binaryMessenger: messenger)

        status.setStreamHandler(StatusHandler())
        control.setMethodCallHandler { [weak self] call, result in
            self?.route(call, result: result)
        }
    }

    private func route(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "initialize":
            guard let args = call.arguments as? [String: Any],
                  let bundleId = args["providerBundleIdentifier"] as? String,
                  let description = args["localizedDescription"] as? String
            else {
                result(FlutterError(code: "-2", message: "Initialization parameters missing", details: nil))
                return
            }

            VlessDartPlugin.utils.providerBundleIdentifier = bundleId
            VlessDartPlugin.utils.localizedDescription = description

            VlessDartPlugin.utils.loadProviderManager { error in
                if let error {
                    os_log("[PLUGIN] loadProviderManager failed: %@", error.localizedDescription)
                    result(FlutterError(code: "-3", message: error.localizedDescription, details: nil))
                } else {
                    self.initialized = true
                    result(VlessDartPlugin.utils.currentStatus())
                }
            }

        case "checkTunnelConfiguration":
            VlessDartPlugin.utils.checkTunnelConfiguration { result($0 != nil) }

        case "setupTunnel":
            guard initialized else {
                result(FlutterError(code: "-1", message: "VLESS engine must be initialized", details: nil))
                return
            }
            VlessDartPlugin.utils.setupTunnel { error in
                if let error {
                    result(FlutterError(code: "98", message: "Failed to setup tunnel", details: error.localizedDescription))
                } else {
                    result(VlessDartPlugin.utils.currentStatus())
                }
            }

        case "connect":
            guard initialized else {
                result(FlutterError(code: "-1", message: "VLESS engine must be initialized", details: nil))
                return
            }
            guard let config = (call.arguments as? [String: Any])?["config"] as? String else {
                result(FlutterError(code: "-2", message: "Config is empty or nil", details: nil))
                return
            }
            VlessDartPlugin.utils.configureVPN(config: config) { error in
                if let error {
                    result(FlutterError(code: "99", message: "Failed to start VPN", details: error.localizedDescription))
                } else {
                    result(nil)
                }
            }

        case "disconnect":
            VlessDartPlugin.utils.stopVPN()
            result(nil)

        case "dispose":
            initialized = false
            result(nil)

        case "removeTunnelConfiguration":
            VlessDartPlugin.utils.removeTunnelConfiguration { error in
                if let error {
                    result(FlutterError(code: "96", message: "Failed to remove tunnel", details: error.localizedDescription))
                } else {
                    result(true)
                }
            }

        case "tunnelStatistics":
            VlessDartPlugin.utils.tunnelStatistics { result($0) }

        case "status":
            result(VlessDartPlugin.utils.currentStatus())

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    class StatusHandler: NSObject, FlutterStreamHandler {
        func onListen(withArguments _: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
            VlessDartPlugin.utils.status = events
            return nil
        }

        func onCancel(withArguments _: Any?) -> FlutterError? {
            VlessDartPlugin.utils.status = nil
            return nil
        }
    }
}
