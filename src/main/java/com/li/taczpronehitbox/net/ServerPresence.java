package com.li.taczpronehitbox.net;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Client-side knowledge about whether the server this client is currently connected to runs
 * TaCZ Prone Hitbox.
 *
 * <p>Three states:</p>
 * <ul>
 *   <li><b>unknown</b> - just logged in, the server hello has not arrived yet and the grace
 *       period has not elapsed. Debug rendering stays off while {@code requireServerMod}
 *       is enabled, because the hitbox may not match the server's real hit detection.</li>
 *   <li><b>present</b> - the server sent a hello (or this is singleplayer, where the
 *       integrated server always has the same jar). Full functionality.</li>
 *   <li><b>absent</b> - the grace period elapsed without a hello: the server does not run
 *       this mod. The client cannot fix hit registration for other players, so we warn once
 *       and hide the misleading debug box by default.</li>
 * </ul>
 *
 * <p>All state is mutated on the client thread (packet handler is enqueued to the main
 * thread); fields are volatile only so that a stray read from another thread never sees a
 * torn/late value.</p>
 */
public final class ServerPresence {

    private static final Logger LOGGER = LoggerFactory.getLogger("taczpronehitbox");

    private static volatile boolean known;
    private static volatile boolean present;

    private ServerPresence() {
    }

    /** Forgets everything; called on every (dis)connect so a new server starts out unknown. */
    public static void reset() {
        known = false;
        present = false;
    }

    /** The server hello arrived: the server has this mod. */
    public static void onServerHello(String modVersion) {
        known = true;
        present = true;
        LOGGER.info("[taczpronehitbox] Server hello received (server mod version '{}'); "
                + "prone hit registration and debug rendering are authoritative on this connection.", modVersion);
    }

    /** Integrated server: the same jar runs on both sides, so the server always has the mod. */
    public static void onLocalServer() {
        known = true;
        present = true;
        LOGGER.info("[taczpronehitbox] Singleplayer/integrated server detected: treating the server as modded.");
    }

    /** Grace period elapsed without a hello: the remote server does not have this mod. */
    public static void onServerMissing() {
        known = true;
        present = false;
        LOGGER.info("[taczpronehitbox] No server hello after the handshake grace period: "
                + "the remote server does not run this mod. Prone hit detection there is vanilla TaCZ only.");
    }

    public static boolean isKnown() {
        return known;
    }

    public static boolean isPresent() {
        return present;
    }

    /** Short human-readable state, used in debug logs. */
    public static String describe() {
        if (!known) {
            return "unknown";
        }
        return present ? "present" : "absent";
    }
}
