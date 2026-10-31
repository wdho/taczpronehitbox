package com.li.taczpronehitbox.prone;

import net.minecraft.world.phys.Vec3;

/**
 * One tick of a player's prone-relevant state, used for ping compensation.
 *
 * @param pos      player position (feet) at that tick
 * @param bodyYaw  body yaw in degrees at that tick (yBodyRot)
 */
public record ProneSample(Vec3 pos, float bodyYaw) {
}
