package com.li.taczpronehitbox.mixin.vanilla;

import com.li.taczpronehitbox.config.ProneHitboxConfig;
import com.li.taczpronehitbox.prone.ProneHistory;
import com.li.taczpronehitbox.prone.ProneState;
import com.li.taczpronehitbox.shape.ProneShape;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.entity.projectile.ProjectileUtil;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.EntityHitResult;
import net.minecraft.world.phys.Vec3;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

import java.util.List;
import java.util.function.Predicate;

/**
 * Vanilla projectile hit takeover (arrows, tridents, throwables, ...).
 *
 * <p>Vanilla {@code ProjectileUtil.getEntityHitResult} clips the segment against each entity's
 * axis-aligned box. For a prone player that box is the tiny 0.6 SWIMMING cube, so arrows could
 * fly through the visible body. This mixin lets the vanilla result run, then compares it with
 * an oriented-body hit of every prone player near the segment and returns the nearest valid
 * one. Physical collision/entity AABB is not touched.</p>
 *
 * <p>Controlled by {@code general.applyToVanillaProjectiles} (default true).</p>
 */
@Mixin(value = ProjectileUtil.class, priority = 1500)
public abstract class ProjectileHitMixin {

    @Inject(method = "m_37287_(Lnet/minecraft/world/entity/Entity;Lnet/minecraft/world/phys/Vec3;Lnet/minecraft/world/phys/Vec3;Lnet/minecraft/world/phys/AABB;Ljava/util/function/Predicate;D)Lnet/minecraft/world/phys/EntityHitResult;",
            at = @At("RETURN"), require = 0, remap = false)
    private static void tph$replaceProneProjectileHit(Entity projectile, Vec3 start, Vec3 end, AABB searchBox,
                                                      Predicate<Entity> filter, double distance,
                                                      CallbackInfoReturnable<EntityHitResult> cir) {
        boolean enabled;
        try {
            enabled = ProneHitboxConfig.enabled() && ProneHitboxConfig.COMMON.applyToVanillaProjectiles.get();
        } catch (RuntimeException notLoadedYet) {
            enabled = false;
        }
        if (!enabled || projectile == null || projectile.level() == null) {
            return;
        }
        EntityHitResult vanilla = cir.getReturnValue();
        double bestDistance = Double.MAX_VALUE;
        Player bestPlayer = null;
        Vec3 bestPoint = null;
        try {
            List<Entity> candidates = projectile.level().getEntities(projectile, searchBox.inflate(2.0D), filter);
            for (Entity candidate : candidates) {
                if (!(candidate instanceof Player player) || player.isSpectator() || !ProneState.isProne(player)) {
                    continue;
                }
                if (projectile instanceof net.minecraft.world.entity.projectile.Projectile proj
                        && player == proj.getOwner()) {
                    continue;
                }
                Vec3 hit = ProneShape.fromSample(ProneHistory.latest(player)).clip(start, end);
                if (hit == null) {
                    continue;
                }
                double hitDistance = hit.distanceToSqr(start);
                if (hitDistance < bestDistance) {
                    bestDistance = hitDistance;
                    bestPlayer = player;
                    bestPoint = hit;
                }
            }
        } catch (RuntimeException failed) {
            // Never break projectile physics because of hitbox bookkeeping.
            return;
        }

        if (vanilla != null && vanilla.getEntity() instanceof Player vanillaPlayer && ProneState.isProne(vanillaPlayer)) {
            if (bestPlayer == vanillaPlayer) {
                cir.setReturnValue(new EntityHitResult(bestPlayer, bestPoint));
            } else if (bestPlayer != null && bestDistance < vanilla.getLocation().distanceToSqr(start)) {
                cir.setReturnValue(new EntityHitResult(bestPlayer, bestPoint));
            } else {
                // The vanilla hit used the tiny SWIMMING cube and our body test missed: no hit.
                cir.setReturnValue(null);
            }
            return;
        }
        if (bestPlayer != null) {
            double vanillaDistance = vanilla == null ? Double.MAX_VALUE
                    : vanilla.getLocation().distanceToSqr(start);
            if (bestDistance < vanillaDistance) {
                cir.setReturnValue(new EntityHitResult(bestPlayer, bestPoint));
            }
        }
    }
}