package com.li.taczpronehitbox.hit;

import com.li.taczpronehitbox.config.ProneHitboxConfig;
import com.li.taczpronehitbox.prone.ProneHistory;
import com.li.taczpronehitbox.prone.ProneSample;
import com.li.taczpronehitbox.prone.ProneState;
import com.li.taczpronehitbox.shape.ProneShape;
import com.tacz.guns.entity.EntityKineticBullet;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.entity.projectile.Projectile;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;

import javax.annotation.Nullable;

/**
 * Body-shaped hit tests for TaCZ bullets.
 *
 * <p>TaCZ's {@code EntityUtil.getHitResult} tests bullets against
 * {@code HitboxHelper.getFixedBoundingBox(...)}, which is a plain AABB. A crawling
 * player is forced into {@code Pose.SWIMMING}, whose vanilla hitbox is a tiny 0.6 cube,
 * and expanding that cube for a rotated body is exactly the "hitbox balloons when the
 * body turns" bug. Here we instead clip the bullet segment against the oriented body
 * box of {@link ProneShape}, which has the same size for every body yaw.</p>
 *
 * <p>All methods are called from {@code EntityUtilMixin}; the geometry itself is
 * delegated to {@link ProneShape} so the exact same shape is rendered by the debug
 * renderer.</p>
 */
public final class TaCZBulletHitHandler {

    /**
     * Result of an authoritative body hit test.
     *
     * <p>A non-null {@code Outcome} means "the body test decided this shot": the
     * {@link #result()} field is then either the hit (with headshot flag) or {@code null}
     * for a clean miss. A {@code null} return from {@link #handle} instead means
     * "not our business, let TaCZ run its vanilla hit test".</p>
     */
    public record Outcome(@Nullable EntityKineticBullet.EntityResult result) {
    }

    private TaCZBulletHitHandler() {
    }

    /**
     * Head-of-{@code EntityUtil.getHitResult} takeover.
     *
     * @return {@code null} when the vanilla TaCZ test should run, otherwise an
     *         authoritative outcome (a hit, or a deliberate miss)
     */
    @Nullable
    public static Outcome handle(Projectile projectile, Entity target, Vec3 start, Vec3 end) {
        if (projectile == null || target == null || start == null || end == null) {
            return null;
        }
        if (!bodyHitboxEnabled()) {
            return null;
        }
        if (!(target instanceof Player player)) {
            return null;
        }
        // TaCZ already filters the shooter out before calling getHitResult; keep the
        // guard so any future call site cannot make a bullet hit its own shooter.
        if (projectile.getOwner() == player) {
            return null;
        }
        if (!ProneState.isProne(player)) {
            return null;
        }

        ProneShape shape = ProneShape.fromSample(rewindSample(player, projectile.getOwner()));
        Vec3 hit = shape.clip(start, end);
        if (hit == null) {
            // Authoritative miss: suppress TaCZ's tiny SWIMMING bounding box. The bullet
            // has to physically pass through the drawn body shape to damage the player.
            return new Outcome(null);
        }
        // Body orientation: the front (head) part of the box is the headshot zone.
        boolean headshot = shape.isHeadshot(hit);
        return new Outcome(new EntityKineticBullet.EntityResult(player, hit, headshot));
    }

    /**
     * {@code AABB.inflate(double)} redirect used by
     * {@code EntityUtil.findEntityOnPath}/{@code findEntitiesOnPath}.
     *
     * <p>Keeps TaCZ's original inflation whenever the body hitbox is disabled, so a
     * player turning the feature off gets byte-for-byte vanilla TaCZ behaviour.</p>
     */
    public static AABB widenCandidateSearch(AABB searchBox, double originalInflate) {
        if (!bodyHitboxEnabled()) {
            return searchBox.inflate(originalInflate);
        }
        return searchBox.inflate(HitMath.widenedSearchInflate(originalInflate));
    }

    /**
     * {@code enabled && applyToTaczBullets}, with a defensive fallback to the config
     * defaults if the Forge config is not loaded yet (cannot happen during normal play,
     * but a mixin-injected static path should never throw).
     */
    public static boolean bodyHitboxEnabled() {
        try {
            return ProneHitboxConfig.enabled() && ProneHitboxConfig.COMMON.applyToTaczBullets.get();
        } catch (RuntimeException notLoadedYet) {
            return true;
        }
    }

    private static boolean latencyRewindEnabled() {
        try {
            return ProneHitboxConfig.COMMON.latencyRewind.get();
        } catch (RuntimeException notLoadedYet) {
            return true;
        }
    }

    /**
     * Picks the recorded body sample to test against.
     *
     * <p>For a server-side shooter we rewind by the shooter's ping exactly like TaCZ's
     * latency fix, because the shooter aimed at the body state they saw {@code ping}
     * milliseconds ago. Client-side shots (and non-player shooters) use the latest
     * recorded sample.</p>
     */
    private static ProneSample rewindSample(Player target, @Nullable Entity shooter) {
        if (!latencyRewindEnabled() || !(shooter instanceof ServerPlayer serverShooter)) {
            return ProneHistory.latest(target);
        }
        int ticksAgo = HitMath.rewindTicks(serverShooter.latency);
        ProneSample rewound = ProneHistory.peek(target, ticksAgo);
        // peek() clamps to the oldest sample it has; latest() also covers an empty
        // history (e.g. the player was just added to the level).
        return rewound != null ? rewound : ProneHistory.latest(target);
    }
}
