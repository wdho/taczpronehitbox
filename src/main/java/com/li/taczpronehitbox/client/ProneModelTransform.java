package com.li.taczpronehitbox.client;

import com.li.taczpronehitbox.prone.ProneState;
import com.li.taczpronehitbox.shape.ProneShape;
import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.math.Axis;
import net.minecraft.client.player.AbstractClientPlayer;
import net.minecraft.world.phys.Vec3;

/**
 * Renders the prone player model with our own transform instead of vanilla's SWIMMING transform.
 *
 * <p>Vanilla (and TaCZ's forced {@code Pose.SWIMMING}) lays the model down with its own
 * translation/setupRotations stack. That stack is also modified by other mods (tacz-tweaks
 * visualTweak, peek models, ...), which made it impossible to line our oriented hitbox up with
 * the visible body. Here the render transform is derived from exactly the same
 * {@link ProneShape} used for hit detection and drawing:</p>
 *
 * <ul>
 *   <li>the model's feet are placed at {@code shape.anchor() - forward * halfLength};</li>
 *   <li>the model's local +Y (feet-to-head) is rotated onto the shape's forward axis;</li>
 *   <li>the model's local -Z (face) is rotated to point down (face-down prone).</li>
 * </ul>
 *
 * <p>Because both the model and the hitbox come from the same shape, they are aligned by
 * construction, independent of TaCZ/tacz-tweaks render translations.</p>
 */
public final class ProneModelTransform {

    /** Model thickness/2: lifts the lying body so it is not half-buried in the floor. */
    private static final double MODEL_LIFT = 0.25D;

    private ProneModelTransform() {
    }

    /**
     * Applies the custom prone model transform.
     *
     * @return true when the caller should cancel vanilla {@code setupRotations}
     */
    public static boolean apply(AbstractClientPlayer player, PoseStack poseStack, float partialTicks) {
        if (player == null || poseStack == null || !ProneState.isProne(player)) {
            return false;
        }
        ProneShape shape = ProneShape.forPlayer(player);
        if (shape == null) {
            return false;
        }
        // Interpolated render position: EntityRenderDispatcher already translated the pose stack
        // to this position, so all deltas below are relative to it.
        Vec3 pos = player.getPosition(partialTicks);
        float yaw = shape.yawDeg();
        double yawRad = Math.toRadians(yaw);
        Vec3 forward = new Vec3(-Math.sin(yawRad), 0.0D, Math.cos(yawRad));
        Vec3 anchor = pos.add(forward.scale(shape.forwardOffset()));
        Vec3 feet = anchor.subtract(forward.scale(shape.halfLength()));

        poseStack.translate(feet.x - pos.x, feet.y - pos.y + shape.baseHeight() + MODEL_LIFT, feet.z - pos.z);
        // Local +Y (head) -> shape forward, local -Z (face) -> down, local +Z (back) -> up.
        poseStack.mulPose(Axis.YP.rotationDegrees(180.0F - yaw));
        poseStack.mulPose(Axis.XP.rotationDegrees(-90.0F));
        return true;
    }
}