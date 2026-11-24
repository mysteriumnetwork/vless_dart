package network.mysterium.vless_dart;

/**
 * What the plugin's process may ask of the tunnel's. See VlessIpc.
 *
 * Deliberately not how status travels: that is a broadcast, which needs no
 * binding and so still works when a start fails before anything has bound.
 * This carries what a broadcast cannot: an answer on demand, and a binder
 * whose death is the only signal left when the tunnel's process is killed.
 */
interface IVlessCore {
    /** Cumulative proxy counters, as { upload, download } in bytes. */
    long[] counters();

    /** Re-sends the status broadcast if a session is live, and not otherwise. */
    oneway void announce();
}
