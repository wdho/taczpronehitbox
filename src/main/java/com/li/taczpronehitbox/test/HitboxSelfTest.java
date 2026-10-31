package com.li.taczpronehitbox.test;

import com.li.taczpronehitbox.hit.HitMath;
import com.li.taczpronehitbox.prone.ProneSample;
import com.li.taczpronehitbox.shape.ProneShape;
import net.minecraft.util.Mth;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;

import java.util.ArrayList;
import java.util.List;

/**
 * Plain-JVM self test for the prone body hitbox geometry and the TaCZ helpers.
 *
 * <p>Everything tested here is reachable without a running game: {@link ProneShape}
 * only needs {@code Vec3}/{@code AABB} (and falls back to the config defaults when no
 * Forge config is loaded) and {@link HitMath} has no game dependencies at all. The
 * TaCZ-specific glue ({@code EntityUtilMixin}, {@code TaCZBulletHitHandler}) is NOT
 * loaded, because TaCZ is {@code compileOnly} and therefore absent from the self test
 * runtime classpath.</p>
 *
 * <p>Covered:</p>
 * <ul>
 *   <li>a ray from above and horizontal rays from front/rear/sides hit the body for
 *       every body yaw (the hit shape is constant, only its orientation changes);</li>
 *   <li>the body box keeps its configured size at every yaw and the enclosing AABB
 *       never grows beyond the body diagonal (the classic "sideways hitbox balloons"
 *       bug is impossible here);</li>
 *   <li>the headshot zone is the front 30% of the body;</li>
 *   <li>rays that miss the body return {@code null} (no phantom hits), and grazing
 *       shots just inside the box still hit;</li>
 *   <li>the ping rewind formula is bit-for-bit the one TaCZ uses.</li>
 * </ul>
 *
 * <p>Run with {@code cmd /c build-offline.bat selfTest}; terminates with exit code 1 on
 * any failure.</p>
 */
public final class HitboxSelfTest {

    // Mirrors ProneHitboxConfig.Common's defaults (also ProneShape's fallbacks when the
    // Forge config has not been loaded).
    private static final double BODY_WIDTH = 0.65D;
    private static final double BODY_HEIGHT = 0.50D;
    private static final double BODY_LENGTH = 1.80D;
    private static final double FORWARD_OFFSET = 0.0D;
    private static final double BASE_HEIGHT = 0.0D;
    private static final double HEAD_WIDTH = 0.65D;
    private static final double HEAD_LENGTH = 0.60D;
    private static final double HEAD_HEIGHT = 0.30D;

    private static final double HALF_WIDTH = BODY_WIDTH / 2.0D;
    private static final double HALF_LENGTH = BODY_LENGTH / 2.0D;
    private static final double TOP = BASE_HEIGHT + BODY_HEIGHT;
    private static final double MID_Y = BASE_HEIGHT + BODY_HEIGHT / 2.0D;

    /** Feet position of the fake player used by the geometry tests. */
    private static final Vec3 FEET = new Vec3(12.5D, 64.0D, -7.25D);

    private static final double TOL = 1.0E-9D;

    /** Yaw 0 and all 45/90 degree steps, plus a negative and a near-360 value. */
    private static final float[] YAWS = {
            0.0F, 30.0F, 45.0F, 90.0F, 135.0F, 180.0F, 225.0F, 270.0F, 315.0F, -45.0F, 359.9F
    };

    private static int checks;
    private static final List<String> failures = new ArrayList<>();

    private HitboxSelfTest() {
    }

    public static void main(String[] args) {
        run("vertical drop hits the body at every yaw", HitboxSelfTest::testVerticalDrop);
        run("horizontal front/rear/side hits at every yaw", HitboxSelfTest::testHorizontalHits);
        run("body/enclosing sizes stay constant (no yaw ballooning)", HitboxSelfTest::testSizes);
        run("headshot zone is the front part of the body", HitboxSelfTest::testHeadshotZone);
        run("rays that miss return null (no phantom hits)", HitboxSelfTest::testMisses);
        run("grazing / inside-start / degenerate rays", HitboxSelfTest::testEdgeCases);
        run("ping rewind formula matches TaCZ Mth.ceil", HitboxSelfTest::testRewindFormula);
        run("candidate search inflation widening", HitboxSelfTest::testSearchWidening);
        run("shape anchor and local frame", HitboxSelfTest::testFrame);

        System.out.println();
        if (failures.isEmpty()) {
            System.out.println("ALL PASS (" + checks + " checks)");
            System.exit(0);
        }
        System.out.println("FAILED: " + failures.size() + " of " + checks + " checks");
        for (int i = 0; i < failures.size() && i < 100; i++) {
            System.out.println("  - " + failures.get(i));
        }
        System.exit(1);
    }

    // ------------------------------------------------------------------ tests

    private static void testVerticalDrop() {
        for (float yaw : YAWS) {
            ProneShape shape = shapeFor(yaw);
            Vec3 expected = shape.anchor().add(0.0D, TOP, 0.0D);
            Vec3 hit = shape.clip(
                    shape.anchor().add(0.0D, 4.0D, 0.0D),
                    shape.anchor().add(0.0D, -4.0D, 0.0D));
            checkVec("vertical hit yaw=" + yaw, hit, expected);
            // Straight down onto the middle of the back is a body shot, not a headshot.
            check("vertical not headshot yaw=" + yaw, hit != null && !shape.isHeadshot(hit));
        }
    }

    private static void testHorizontalHits() {
        for (float yaw : YAWS) {
            ProneShape shape = shapeFor(yaw);
            double y = MID_Y;

            // Front (head end) shot: front face, inside the headshot zone, size-independent.
            Vec3 expectedFront = shape.toWorld(new Vec3(0.0D, y, HALF_LENGTH));
            Vec3 hitFront = shape.clip(
                    shape.toWorld(new Vec3(0.0D, y, HALF_LENGTH + 4.0D)),
                    shape.toWorld(new Vec3(0.0D, y, -(HALF_LENGTH + 4.0D))));
            checkVec("front hit yaw=" + yaw, hitFront, expectedFront);

            // Rear (feet end) shot: rear face, never a headshot.
            Vec3 expectedRear = shape.toWorld(new Vec3(0.0D, y, -HALF_LENGTH));
            Vec3 hitRear = shape.clip(
                    shape.toWorld(new Vec3(0.0D, y, -(HALF_LENGTH + 4.0D))),
                    shape.toWorld(new Vec3(0.0D, y, HALF_LENGTH + 4.0D)));
            checkVec("rear hit yaw=" + yaw, hitRear, expectedRear);
            check("rear not headshot yaw=" + yaw, hitRear != null && !shape.isHeadshot(hitRear));

            // Side shots hit exactly +-halfWidth: the width never changes with yaw, which
            // is the whole point of the oriented box vs. a rotated AABB.
            Vec3 expectedRight = shape.toWorld(new Vec3(HALF_WIDTH, y, 0.0D));
            Vec3 hitRight = shape.clip(
                    shape.toWorld(new Vec3(HALF_WIDTH + 4.0D, y, 0.0D)),
                    shape.toWorld(new Vec3(-(HALF_WIDTH + 4.0D), y, 0.0D)));
            checkVec("right side hit yaw=" + yaw, hitRight, expectedRight);

            Vec3 expectedLeft = shape.toWorld(new Vec3(-HALF_WIDTH, y, 0.0D));
            Vec3 hitLeft = shape.clip(
                    shape.toWorld(new Vec3(-(HALF_WIDTH + 4.0D), y, 0.0D)),
                    shape.toWorld(new Vec3(HALF_WIDTH + 4.0D, y, 0.0D)));
            checkVec("left side hit yaw=" + yaw, hitLeft, expectedLeft);
        }
    }

    private static void testSizes() {
        double diagonal = Math.hypot(BODY_WIDTH, BODY_LENGTH);
        for (float yaw : YAWS) {
            ProneShape shape = shapeFor(yaw);

            AABB local = shape.localBox();
            checkClose("local width yaw=" + yaw, local.getXsize(), BODY_WIDTH);
            checkClose("local height yaw=" + yaw, local.getYsize(), BODY_HEIGHT);
            checkClose("local length yaw=" + yaw, local.getZsize(), BODY_LENGTH);

            AABB enclosing = shape.enclosingAabb();
            checkClose("enclosing height yaw=" + yaw, enclosing.getYsize(), BODY_HEIGHT);
            // The culling AABB of a rotated rectangle is largest at 45 degrees, but it can
            // never exceed the body's own diagonal. A broken "rotate the AABB" fix would
            // grow towards a bodyLength-sized cube instead.
            check("enclosing x within diagonal yaw=" + yaw, enclosing.getXsize() <= diagonal + TOL);
            check("enclosing z within diagonal yaw=" + yaw, enclosing.getZsize() <= diagonal + TOL);
        }

        // At 0/90 degrees the enclosing box exactly swaps width and length: rotation does
        // not inflate anything, it only rotates the footprint.
        ProneShape at0 = shapeFor(0.0F);
        checkClose("yaw=0 enclosing x", at0.enclosingAabb().getXsize(), BODY_WIDTH);
        checkClose("yaw=0 enclosing z", at0.enclosingAabb().getZsize(), BODY_LENGTH);

        ProneShape at90 = shapeFor(90.0F);
        checkClose("yaw=90 enclosing x", at90.enclosingAabb().getXsize(), BODY_LENGTH);
        checkClose("yaw=90 enclosing z", at90.enclosingAabb().getZsize(), BODY_WIDTH);

        // Worst case is 45 degrees: still bounded by the diagonal, not by a body cube.
        ProneShape at45 = shapeFor(45.0F);
        double worst45 = Math.max(at45.enclosingAabb().getXsize(), at45.enclosingAabb().getZsize());
        check("yaw=45 enclosing within diagonal", worst45 <= diagonal + TOL);
        check("yaw=45 enclosing is not a huge cube", worst45 < BODY_LENGTH * 1.1D);
    }

    private static void testHeadshotZone() {
        // Filled red head slab ON TOP of the body front, at the head (-Z) end.
        double headStart = -HALF_LENGTH;
        double headEnd = -HALF_LENGTH + HEAD_LENGTH;
        double headHalf = Math.min(HALF_WIDTH, HEAD_WIDTH / 2.0D);
        double headBottom = BASE_HEIGHT + BODY_HEIGHT;
        double headY = headBottom + HEAD_HEIGHT / 2.0D;
        for (float yaw : YAWS) {
            ProneShape shape = shapeFor(yaw);
            check("head centre is headshot yaw=" + yaw,
                    shape.isHeadshot(shape.toWorld(new Vec3(0.0D, headY, (headStart + headEnd) / 2.0D))));
            check("head start inside yaw=" + yaw,
                    shape.isHeadshot(shape.toWorld(new Vec3(0.0D, headY, headStart + 1.0E-6D))));
            check("head start outside yaw=" + yaw,
                    !shape.isHeadshot(shape.toWorld(new Vec3(0.0D, headY, headStart - 1.0E-6D))));
            check("head width inside yaw=" + yaw,
                    shape.isHeadshot(shape.toWorld(new Vec3(headHalf - 1.0E-6D, headY, (headStart + headEnd) / 2.0D))));
            check("head width outside yaw=" + yaw,
                    !shape.isHeadshot(shape.toWorld(new Vec3(headHalf + 1.0E-6D, headY, (headStart + headEnd) / 2.0D))));
            check("head height inside yaw=" + yaw,
                    shape.isHeadshot(shape.toWorld(new Vec3(0.0D, headBottom + HEAD_HEIGHT / 2.0D, (headStart + headEnd) / 2.0D))));
            check("head height outside yaw=" + yaw,
                    !shape.isHeadshot(shape.toWorld(new Vec3(0.0D, headBottom - 1.0E-3D, (headStart + headEnd) / 2.0D))));
            check("far end is not headshot yaw=" + yaw,
                    !shape.isHeadshot(shape.toWorld(new Vec3(0.0D, MID_Y, HALF_LENGTH - 1.0E-3D))));
            // A bullet can hit the head slab even where the body box does not exist (above the body).
            double headMidZ = (headStart + headEnd) / 2.0D;
            Vec3 fromAbove = shape.toWorld(new Vec3(0.0D, headBottom + HEAD_HEIGHT + 2.0D, headMidZ));
            Vec3 toBelow = shape.toWorld(new Vec3(0.0D, headBottom - 2.0D, headMidZ));
            Vec3 headHit = shape.clip(fromAbove, toBelow);
            check("head slab is hittable above body yaw=" + yaw,
                    headHit != null && shape.isHeadshot(headHit));
        }
    }

    private static void testMisses() {
        for (float yaw : YAWS) {
            ProneShape shape = shapeFor(yaw);
            double y = MID_Y;
            double zFar = HALF_LENGTH + 4.0D;

            // Parallel to the body, just outside its sides.
            checkMiss("lateral miss yaw=" + yaw, shape.clip(
                    shape.toWorld(new Vec3(HALF_WIDTH + 0.01D, y, zFar)),
                    shape.toWorld(new Vec3(HALF_WIDTH + 0.01D, y, -zFar))));
            // Above the body and above the head slab.
            double aboveAll = BASE_HEIGHT + BODY_HEIGHT + HEAD_HEIGHT + 0.01D;
            checkMiss("above miss yaw=" + yaw, shape.clip(
                    shape.toWorld(new Vec3(0.0D, aboveAll, zFar)),
                    shape.toWorld(new Vec3(0.0D, aboveAll, -zFar))));
            checkMiss("below miss yaw=" + yaw, shape.clip(
                    shape.toWorld(new Vec3(0.0D, BASE_HEIGHT - 0.01D, zFar)),
                    shape.toWorld(new Vec3(0.0D, BASE_HEIGHT - 0.01D, -zFar))));
            // Stops short of the front face.
            checkMiss("short ray yaw=" + yaw, shape.clip(
                    shape.toWorld(new Vec3(0.0D, y, zFar)),
                    shape.toWorld(new Vec3(0.0D, y, HALF_LENGTH + 1.0D))));
            // Entirely beside the body (bullet flies past it).
            checkMiss("fly-past miss yaw=" + yaw, shape.clip(
                    shape.toWorld(new Vec3(-(HALF_WIDTH + 1.0D), y, zFar)),
                    shape.toWorld(new Vec3(-(HALF_WIDTH + 1.0D), y, -zFar))));
            // Far away from the body.
            checkMiss("far miss yaw=" + yaw, shape.clip(
                    shape.toWorld(new Vec3(10.0D, y, 0.0D)),
                    shape.toWorld(new Vec3(9.0D, y, 0.0D))));
        }
    }

    private static void testEdgeCases() {
        ProneShape shape = shapeFor(37.5F);
        double y = MID_Y;
        double zFar = HALF_LENGTH + 4.0D;

        // Grazing shots: 1 mm inside the side still hits, 1 mm outside misses.
        Vec3 grazeInside = shape.clip(
                shape.toWorld(new Vec3(HALF_WIDTH - 1.0E-3D, y, zFar)),
                shape.toWorld(new Vec3(HALF_WIDTH - 1.0E-3D, y, -zFar)));
        check("grazing shot just inside hits", grazeInside != null);
        checkMiss("grazing shot just outside misses", shape.clip(
                shape.toWorld(new Vec3(HALF_WIDTH + 1.0E-3D, y, zFar)),
                shape.toWorld(new Vec3(HALF_WIDTH + 1.0E-3D, y, -zFar))));

        // A segment that starts inside the body clips at t=0 (the start point).
        Vec3 inside = shape.toWorld(new Vec3(0.1D, y, 0.1D));
        checkVec("segment starting inside returns start", shape.clip(
                inside,
                shape.toWorld(new Vec3(0.1D, y, 10.0D))), inside);

        // Diagonal shot through the body hits.
        check("diagonal shot hits", shape.clip(
                shape.toWorld(new Vec3(HALF_WIDTH + 2.0D, y, HALF_LENGTH + 2.0D)),
                shape.toWorld(new Vec3(-(HALF_WIDTH + 2.0D), y, -(HALF_LENGTH + 2.0D)))) != null);

        // Degenerate (zero length) segment outside the body: no hit.
        checkMiss("degenerate segment outside", shape.clip(shape.toWorld(new Vec3(5.0D, y, 5.0D)), shape.toWorld(new Vec3(5.0D, y, 5.0D))));

        // Left/right symmetry around the body axis.
        Vec3 right = shape.toWorld(new Vec3(HALF_WIDTH, y, 0.0D));
        Vec3 left = shape.toWorld(new Vec3(-HALF_WIDTH, y, 0.0D));
        checkClose("symmetric half width", right.distanceTo(shape.anchor()), left.distanceTo(shape.anchor()));
    }

    private static void testRewindFormula() {
        check("rewind ping<=0 clamps to 0", HitMath.rewindTicks(0) == 0 && HitMath.rewindTicks(-250) == 0);

        int[] spotPings = {1, 24, 25, 49, 50, 51, 100, 175, 250, 500, 1000, 2500};
        for (int ping : spotPings) {
            double expected = Mth.ceil(ping / 1000.0D * 20.0D + 0.5D);
            check("rewind ping=" + ping + "ms", HitMath.rewindTicks(ping) == (int) expected);
        }
        // Sweep the whole plausible ping range against the exact function TaCZ uses.
        for (int ping = 1; ping <= 2500; ping += 13) {
            double expected = Mth.ceil(ping / 1000.0D * 20.0D + 0.5D);
            check("rewind sweep ping=" + ping + "ms", HitMath.rewindTicks(ping) == (int) expected);
        }
        // Known values: 50ms -> ceil(1.5) = 2 ticks, 1000ms -> ceil(20.5) = 21 ticks.
        check("rewind 50ms = 2 ticks", HitMath.rewindTicks(50) == 2);
        check("rewind 1000ms = 21 ticks", HitMath.rewindTicks(1000) == 21);
    }

    private static void testSearchWidening() {
        check("widened inflate == 2", HitMath.WIDENED_SEARCH_INFLATE == 2.0D);
        check("inflate 1.0 widens to 2.0", HitMath.widenedSearchInflate(1.0D) == 2.0D);
        check("inflate 2.0 stays 2.0", HitMath.widenedSearchInflate(2.0D) == 2.0D);
        check("inflate 3.0 stays 3.0", HitMath.widenedSearchInflate(3.0D) == 3.0D);
        check("inflate 0.5 widens to 2.0", HitMath.widenedSearchInflate(0.5D) == 2.0D);
        check("NaN inflate is passed through", Double.isNaN(HitMath.widenedSearchInflate(Double.NaN)));
    }

    private static void testFrame() {
        for (float yaw : YAWS) {
            ProneShape shape = shapeFor(yaw);

            // The anchor is forwardOffset blocks in front of the feet, at the same height.
            checkClose("anchor height yaw=" + yaw, shape.anchor().y, FEET.y);
            checkClose("anchor forward offset magnitude yaw=" + yaw,
                    Math.hypot(shape.anchor().x - FEET.x, shape.anchor().z - FEET.z), Math.abs(FORWARD_OFFSET));
            checkClose("body yaw kept yaw=" + yaw, shape.yawDeg(), yaw);

            // Local frame is orthonormal: toLocal(toWorld(p)) round-trips.
            Vec3[] points = {
                    new Vec3(0.1D, 0.2D, 0.3D),
                    new Vec3(-0.3D, 0.5D, -0.7D),
                    new Vec3(HALF_WIDTH, TOP, HALF_LENGTH)
            };
            for (Vec3 point : points) {
                checkVec("frame round-trip yaw=" + yaw, shape.toLocal(shape.toWorld(point)), point);
            }
        }
    }

    // ---------------------------------------------------------------- helpers

    private static void run(String name, Runnable test) {
        int checksBefore = checks;
        int failuresBefore = failures.size();
        try {
            test.run();
        } catch (Throwable thrown) {
            failures.add(name + " threw " + thrown);
            thrown.printStackTrace(System.out);
        }
        boolean ok = failures.size() == failuresBefore;
        System.out.println((ok ? "PASS" : "FAIL") + "  " + name + "  (" + (checks - checksBefore) + " checks)");
    }

    private static ProneShape shapeFor(float yaw) {
        return ProneShape.fromSample(new ProneSample(FEET, yaw));
    }

    private static void check(String name, boolean condition) {
        checks++;
        if (!condition) {
            failures.add(name);
        }
    }

    private static void checkClose(String name, double actual, double expected) {
        checks++;
        if (Math.abs(actual - expected) > TOL) {
            failures.add(name + ": expected " + expected + " but got " + actual);
        }
    }

    private static void checkVec(String name, Vec3 actual, Vec3 expected) {
        checks++;
        if (actual == null) {
            failures.add(name + ": expected " + expected + " but got null");
            return;
        }
        double error = actual.distanceToSqr(expected);
        if (error > TOL * TOL) {
            failures.add(name + ": expected " + expected + " but got " + actual + " (error " + Math.sqrt(error) + ")");
        }
    }

    private static void checkMiss(String name, Vec3 hit) {
        checks++;
        if (hit != null) {
            failures.add(name + ": expected a miss but hit at " + hit);
        }
    }
}