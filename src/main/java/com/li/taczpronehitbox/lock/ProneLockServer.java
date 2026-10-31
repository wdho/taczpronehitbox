package com.li.taczpronehitbox.lock;

import net.minecraft.server.level.ServerPlayer;

import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

/** Server-side per-player lock state + tick application. */
public final class ProneLockServer {

    private static final Map<UUID, Boolean> LOCKED = new ConcurrentHashMap<>();
    private static final Set<UUID> ACTIVE = ConcurrentHashMap.newKeySet();

    private ProneLockServer() {
    }

    public static void setLocked(ServerPlayer player, boolean locked) {
        if (player == null) {
            return;
        }
        UUID id = player.getUUID();
        if (locked) {
            LOCKED.put(id, Boolean.TRUE);
        } else {
            LOCKED.remove(id);
            ACTIVE.remove(id);
            ProneLockApplier.release(player);
        }
    }

    /** Called from the server player tick (after TaCZ's own crawl tick). */
    public static void tick(ServerPlayer player) {
        if (player == null) {
            return;
        }
        UUID id = player.getUUID();
        if (!LOCKED.containsKey(id)) {
            return;
        }
        if (!ACTIVE.contains(id) && ProneLockApplier.isProneNow(player)) {
            ACTIVE.add(id);
        }
        if (ACTIVE.contains(id)) {
            ProneLockApplier.hold(player);
        }
    }

    public static void onLoggedOut(ServerPlayer player) {
        if (player == null) {
            return;
        }
        UUID id = player.getUUID();
        LOCKED.remove(id);
        ACTIVE.remove(id);
        ProneLockApplier.release(player);
    }
}
