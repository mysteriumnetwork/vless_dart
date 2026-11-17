package network.mysterium.vless_dart

/**
 * Connection lifecycle states.
 *
 * Names MUST match `lib/vpn_status.dart` exactly — they cross the event
 * channel as `status.name` and are matched there by string.
 */
enum class ConnectionStatus {
    connecting,
    connected,
    disconnecting,
    disconnected,
    unknown,
}
