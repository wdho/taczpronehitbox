package com.li.taczpronehitbox.prone;

import net.minecraft.world.entity.Pose;
import net.minecraft.world.entity.player.Player;

/**
 * Shared "is this player in a dry prone/crawl pose" check.
 *
 * <p>TaCZ's crawl implementation calls {@code player.setForcedPose(Pose.SWIMMING)},
 * so {@link Player#isVisuallyCrawling()} is the most stable signal and also works
 * for remote players on the client. It is false while actually swimming in water.</p>
 */
public final class ProneState {

    private ProneState() {
    }

    public static boolean isProne(Player player) {
        if (player == null || player.isSpectator() || player.isDeadOrDying()) {
            return false;
        }
        if (player.isPassenger()) {
            return false;
        }
        if (player.getPose() != Pose.SWIMMING) {
            return false;
        }
        return player.isVisuallyCrawling();
    }
}
