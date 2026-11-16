package com.li.taczpronehitbox.mixin.vanilla;

import com.li.taczpronehitbox.config.ProneHitboxConfig;
import com.li.taczpronehitbox.prone.ProneHistory;
import com.li.taczpronehitbox.prone.ProneState;
import com.li.taczpronehitbox.shape.ProneShape;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.level.ClipContext;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.HitResult;
import net.minecraft.world.phys.Vec3;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * Explosion visibility/damage falloff for prone players.
 *
 * <p>Vanilla {@code Explosion.getSeenPercent} (SRG {@code m_46064_}) samples the entity's
 * axis-aligned bounding box; for a crawling player that is only the tiny 0.6 SWIMMING cube,
 * so explosions treat most of the visible body as "not there". This mixin samples the eight
 * corners of our oriented body box instead, using the same block clip as vanilla.</p>
 *
 * <p>Controlled by {@code general.applyToExplosions} (default true). Physical collision is
 * not changed.</p>
 */
@Mixin(value = net.minecraft.world.level.Explosion.class, priority = 1500)
public abstract class ExplosionVisibilityMixin {

    @Inject(method = "m_46064_(Lnet/minecraft/world/phys/Vec3;Lnet/minecraft/world/entity/Entity;)F",
            at = @At("HEAD"), cancellable = true, require = 0, remap = false)
    private static void tph$proneSeenPercent(Vec3 explosionPos, Entity entity,
                                             CallbackInfoReturnable<Float> cir) {
        if (!(entity instanceof Player player) || player.level() == null || !ProneState.isProne(player)) {
            return;
        }
        boolean enabled;
        try {
            enabled = ProneHitboxConfig.enabled() && ProneHitboxConfig.COMMON.applyToExplosions.get();
        } catch (RuntimeException notLoadedYet) {
            enabled = false;
        }
        if (!enabled) {
            return;
        }
        ProneShape shape = ProneShape.fromSample(ProneHistory.latest(player));
        AABB local = shape.localBox();
        int total = 0;
        int seen = 0;
        for (double x : new double[]{local.minX, local.maxX}) {
            for (double y : new double[]{local.minY, local.maxY}) {
                for (double z : new double[]{local.minZ, local.maxZ}) {
                    Vec3 point = shape.toWorld(new Vec3(x, y, z));
                    ClipContext clip = new ClipContext(explosionPos, point,
                            ClipContext.Block.COLLIDER, ClipContext.Fluid.NONE, entity);
                    if (player.level().clip(clip).getType() == HitResult.Type.MISS) {
                        seen++;
                    }
                    total++;
                }
            }
        }
        if (total > 0) {
            cir.setReturnValue(seen / (float) total);
        }
    }
}
