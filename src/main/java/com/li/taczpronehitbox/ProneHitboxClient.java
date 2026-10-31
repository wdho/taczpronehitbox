package com.li.taczpronehitbox;

import com.li.taczpronehitbox.client.ProneHitboxDebugCommands;
import com.li.taczpronehitbox.net.ClientPresenceHooks;
import com.li.taczpronehitbox.net.ProneHitboxNetwork;
import net.minecraftforge.api.distmarker.Dist;
import net.minecraftforge.api.distmarker.OnlyIn;

/**
 * Client-only bootstrap. Kept in a separate class so that dedicated servers can load
 * {@link ProneHitboxMod} without touching client classes.
 */
@OnlyIn(Dist.CLIENT)
public final class ProneHitboxClient {

    private static boolean initialized;

    private ProneHitboxClient() {
    }

    public static void init() {
        if (initialized) {
            return;
        }
        initialized = true;

        // Common network channel + S2C server hello. The mod constructor also registers the
        // channel (needed on a dedicated server); ProneHitboxNetwork.register() is idempotent,
        // so exactly one channel is created no matter which call runs first.
        ProneHitboxNetwork.register();

        // Track whether the current server runs this mod: reset on login, warn once when a
        // remote server has no mod, and hide the misleading debug box (see ServerPresence /
        // ProneHitboxDebugRenderer).
        ClientPresenceHooks.init();

        // Debug hitbox rendering: registers a RenderLevelStageEvent listener (Stage.AFTER_ENTITIES)
        // on the Forge game bus. The CLIENT config spec is registered by ProneHitboxMod before this.
        ClientRenderHooks.init();

        // /pronehitbox status: client-side diagnosis command for TaCZ crawl state / key / gun data.
        ProneHitboxDebugCommands.init();

        // "Prone lock" key: keep the crawl pose while climbing stairs/blocks.
        com.li.taczpronehitbox.lock.ProneLockClient.init();

        // NOTE: the standalone Seamless Sprint mod is intentionally kept as a SEPARATE mod.
        // This mod only implements the prone hitbox (+ its client debug rendering / server
        // presence handshake) and never touches sprinting.
    }
}