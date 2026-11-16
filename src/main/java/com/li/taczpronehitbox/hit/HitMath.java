package com.li.taczpronehitbox.hit;

/**
 * Pure numeric helpers shared by the TaCZ hit takeover and its self test.
 *
 * <p>This class deliberately references neither Minecraft nor TaCZ types, so
 * {@code HitboxSelfTest} can exercise it on a plain JVM without bootstrapping Forge
 * or loading the TaCZ mod jar (TaCZ is a {@code compileOnly} dependency).</p>
 */
public final class HitMath {

    /**
     * Candidate-search inflation used in place of TaCZ's {@code inflate(1.0)} while the
     * body-shaped prone hitbox is active.
     *
     * <p>TaCZ searches hit candidates with {@code projectile.getBoundingBox()
     * .expandTowards(deltaMovement).inflate(1.0)}. The prone body box reaches up to
     * {@code bodyLength / 2 + forwardOffset} (~1.25 blocks) in front of the player's
     * position, which can stick out of that search volume for slow/steep shots, so the
     * search volume is widened to 2 blocks. This only changes which entities are
     * considered, never the hit result itself.</p>
     */
    public static final double WIDENED_SEARCH_INFLATE = 2.0D;

    private HitMath() {
    }

    /**
     * Target rewind in ticks for a shooter ping, exactly matching TaCZ's own latency fix
     * ({@code HitboxHelper.getFixedBoundingBox}):
     * {@code Mth.ceil(pingMs / 1000.0 * 20.0 + 0.5)}.
     *
     * <p>Negative pings clamp to 0. The result is intentionally not capped here;
     * {@code ProneHistory.peek} clamps to the oldest sample it still has.</p>
     */
    public static int rewindTicks(int pingMillis) {
        if (pingMillis <= 0) {
            return 0;
        }
        double ticks = pingMillis / 1000.0D * 20.0D + 0.5D;
        return (int) Math.ceil(ticks);
    }

    /**
     * Widens a requested inflation amount to at least {@link #WIDENED_SEARCH_INFLATE}.
     * A larger amount requested by TaCZ (or a future version) is never shrunk.
     */
    public static double widenedSearchInflate(double originalAmount) {
        if (Double.isNaN(originalAmount) || originalAmount >= WIDENED_SEARCH_INFLATE) {
            return originalAmount;
        }
        return WIDENED_SEARCH_INFLATE;
    }
}
