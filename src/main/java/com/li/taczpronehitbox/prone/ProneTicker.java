package com.li.taczpronehitbox.prone;

import com.li.taczpronehitbox.lock.ProneLockServer;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.entity.player.Player;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.event.entity.player.PlayerEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.concurrent.atomic.AtomicBoolean;

/**
 * Forge event hooks that feed {@link ProneHistory}.
 *
 * <p>History bookkeeping must never be able to break a player tick, so any unexpected
 * exception is logged once and swallowed. (A crash report from 1.2.0 showed that an
 * unsynchronized history could throw inside the server tick in a heavily multithreaded
 * pack; the history is now thread-safe, and this guard is the second line of defence.)</p>
 */
public final class ProneTicker {

    private static final Logger LOGGER = LoggerFactory.getLogger("taczpronehitbox");
    private static final AtomicBoolean RECORD_FAILURE_LOGGED = new AtomicBoolean(false);

    private ProneTicker() {
    }

    @SubscribeEvent
    public static void onPlayerTick(TickEvent.PlayerTickEvent event) {
        if (event.phase != TickEvent.Phase.END || event.player == null) {
            return;
        }
        try {
            ProneHistory.record(event.player);
            if (event.player instanceof ServerPlayer serverPlayer) {
                ProneLockServer.tick(serverPlayer);
            }
        } catch (Throwable throwable) {
            if (RECORD_FAILURE_LOGGED.compareAndSet(false, true)) {
                LOGGER.error("[taczpronehitbox] Failed to record prone history; "
                        + "further failures will not be logged. The hitbox still works with the current sample.",
                        throwable);
            }
        }
    }

    @SubscribeEvent
    public static void onLoggedOut(PlayerEvent.PlayerLoggedOutEvent event) {
        Player player = event.getEntity();
        if (player != null) {
            try {
                ProneHistory.forget(player);
                if (player instanceof ServerPlayer serverPlayer) {
                    ProneLockServer.onLoggedOut(serverPlayer);
                }
            } catch (Throwable ignored) {
            }
        }
    }
}