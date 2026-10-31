package com.li.taczpronehitbox.lock;

import net.minecraft.world.entity.Pose;
import net.minecraft.world.entity.player.Player;

/** Small shared helpers for the prone lock. */
public final class ProneLockApplier {

    public static final float NORMAL_STEP_HEIGHT = 0.6F;
    public static final float PRONE_STEP_HEIGHT = 1.0F;

    private ProneLockApplier() {
    }

    /** True when the player is currently in a crawl/prone state (ours or TaCZ's). */
    public static boolean isProneNow(Player player) {
        if (player == null) {
            return false;
        }
        return player.getPose() == Pose.SWIMMING || player.getForcedPose() == Pose.SWIMMING;
    }

    /** Keep the player prone while the lock is active. */
    public static void hold(Player player) {
        if (player == null) {
            return;
        }
        player.setForcedPose(Pose.SWIMMING);
        setStepHeight(player, PRONE_STEP_HEIGHT);
    }

    /** Release the lock: restore vanilla step height and stop forcing the pose. */
    public static void release(Player player) {
        if (player == null) {
            return;
        }
        setStepHeight(player, NORMAL_STEP_HEIGHT);
        if (player.getForcedPose() == Pose.SWIMMING) {
            player.setForcedPose(null);
        }
    }

    private static void setStepHeight(Player player, float height) {
        player.setMaxUpStep(height);
    }
}