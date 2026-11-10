/// Messages the app sends the packet tunnel extension.
///
/// Lives in the Flutter-free support module because both sides need it: the
/// plugin links Flutter, the extension cannot.
public enum TunnelProviderMessages {
    /// Asks the provider for its byte counters.
    public static let stats = "VLESS_STATS"
}

/// Convenience alias used by the plugin and the provider.
public let vlessStatsProviderMessage = TunnelProviderMessages.stats
