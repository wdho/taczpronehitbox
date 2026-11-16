package com.li.taczpronehitbox.prone;

import com.li.taczpronehitbox.config.ProneHitboxConfig;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.phys.Vec3;

import javax.annotation.Nullable;
import java.util.ArrayDeque;
import java.util.Map;
import java.util.WeakHashMap;

/**
 * Short per-player history of position + body yaw.
 *
 * <p>TaCZ rewinds target players by the shooter's ping when doing hit detection
 * ({@code HitboxHelper.getFixedBoundingBox}). A single AABB can simply grow, but an
 * oriented body box cannot, so we keep real samples and rewind the body shape to the
 * state the shooter actually saw.</p>
 *
 * <p><b>Thread safety:</b> this map is written from whatever thread ticks a player. In a
 * heavily multithreaded pack (Harium / Bons and Furious / Async etc.) the same player can
 * be ticked from different threads, or two players can be ticked concurrently; an
 * unsynchronized {@link WeakHashMap}/{@link ArrayDeque} combination can then throw
 * {@link java.util.NoSuchElementException} from {@code removeLast()} and crash the server
 * tick. All access is therefore guarded by {@link #LOCK} and removal is defensive.</p>
 */
public final class ProneHistory {

    /** ~1 second of history; enough for any reasonable ping. */
    public static final int CAPACITY = 24;

    private static final Object LOCK = new Object();
    private static final Map<Player, ArrayDeque<ProneSample>> HISTORY = new WeakHashMap<>();

    private ProneHistory() {
    }

    /** Record the current tick. Called once per tick and per player (both sides). */
    public static void record(Player player) {
        if (player == null) {
            return;
        }
        // Build the sample before taking the lock: position()/yBodyRot are cheap and only
        // this thread mutates the player state.
        ProneSample sample = new ProneSample(player.position(), currentYaw(player));
        synchronized (LOCK) {
            ArrayDeque<ProneSample> queue = HISTORY.get(player);
            if (queue == null) {
                queue = new ArrayDeque<>(CAPACITY + 1);
                HISTORY.put(player, queue);
            }
            queue.addFirst(sample);
            while (queue.size() > CAPACITY) {
                if (queue.pollLast() == null) {
                    // Defensive: should never happen while the lock is held, but never let
                    // bookkeeping throw inside a player tick.
                    break;
                }
            }
        }
    }

    /** Newest recorded sample, or a sample built from the current state. */
    public static ProneSample latest(Player player) {
        ProneSample sample = peek(player, 0);
        if (sample != null) {
            return sample;
        }
        return new ProneSample(player.position(), currentYaw(player));
    }

    /**
     * The yaw used for the prone body box.
     *
     * <p>TaCZ's crawling model lies along the player's look direction (head yaw). The body yaw
     * ({@code yBodyRot}) only follows movement and lags by up to 90 degrees when the player
     * turns while standing still, which made the box point away from the rendered model.</p>
     */
    private static float currentYaw(Player player) {
        return ProneHitboxConfig.yawSource() == ProneHitboxConfig.YawSource.HEAD
                ? player.getYRot()
                : player.yBodyRot;
    }

    /**
     * Sample {@code ticksAgo} ticks in the past (0 = newest recorded sample).
     * Returns null when no history exists.
     */
    @Nullable
    public static ProneSample peek(Player player, int ticksAgo) {
        if (player == null) {
            return null;
        }
        synchronized (LOCK) {
            ArrayDeque<ProneSample> queue = HISTORY.get(player);
            if (queue == null || queue.isEmpty()) {
                return null;
            }
            int index = Math.max(0, ticksAgo);
            if (index >= queue.size()) {
                // Not enough history: clamp to the oldest sample instead of returning null,
                // so a high-ping shooter still gets a plausible position.
                index = queue.size() - 1;
            }
            int i = 0;
            for (ProneSample sample : queue) {
                if (i == index) {
                    return sample;
                }
                i++;
            }
            return null;
        }
    }

    /** Remove a player's history (logout / world change). */
    public static void forget(Player player) {
        if (player == null) {
            return;
        }
        synchronized (LOCK) {
            HISTORY.remove(player);
        }
    }

    /** Current sample for rendering (no ping compensation). */
    @Nullable
    public static ProneSample current(Player player) {
        if (player == null) {
            return null;
        }
        synchronized (LOCK) {
            ArrayDeque<ProneSample> queue = HISTORY.get(player);
            if (queue != null && !queue.isEmpty()) {
                return queue.peekFirst();
            }
        }
        return new ProneSample(player.position(), currentYaw(player));
    }
}