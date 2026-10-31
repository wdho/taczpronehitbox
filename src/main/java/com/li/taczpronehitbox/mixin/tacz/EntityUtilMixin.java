package com.li.taczpronehitbox.mixin.tacz;

import com.li.taczpronehitbox.hit.TaCZBulletHitHandler;
import com.tacz.guns.entity.EntityKineticBullet;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.projectile.Projectile;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;

/**
 * Takes over TaCZ bullet hit detection for prone players.
 *
 * <p>TaCZ (1.1.8) ships unobfuscated class/method names but is reobfuscated against
 * SRG Minecraft names, so every annotation here uses {@code remap = false} and refers
 * to TaCZ's own names plus SRG Minecraft members ({@code m_82400_}). No refmap is
 * needed; that is also why the Mixin annotation processor is deliberately not enabled
 * in this project.</p>
 *
 * <p>{@link #tph$bodyHit} intercepts {@code EntityUtil.getHitResult(...)} (called by
 * both {@code findEntityOnPath} and {@code findEntitiesOnPath}) and replaces the
 * vanilla AABB clip with the oriented body box whenever the target is a prone player.
 * {@link #tph$widenSearch} grows the candidate search radius so the longer body shape
 * is part of the candidate list at all.</p>
 *
 * <p>Scope: only TaCZ gun bullets are affected. Vanilla AABBs, physical collision and
 * every other damage source are untouched.</p>
 *
 * <p>The raised priority makes this HEAD injection run before other addons that also
 * inject at the head of {@code getHitResult} (observed in the wild: gd656peek's peek
 * hitbox). For prone targets the body shape must win; for every other entity
 * {@code TaCZBulletHitHandler.handle} returns {@code null} without cancelling, so the
 * next injector and TaCZ's own logic still run exactly as before.</p>
 */
@Mixin(targets = "com.tacz.guns.util.EntityUtil", remap = false, priority = 1500)
public abstract class EntityUtilMixin {

    /**
     * Head of {@code getHitResult}: use the prone body shape instead of the vanilla AABB.
     *
     * <p>When {@link TaCZBulletHitHandler#handle} returns an outcome we set the return
     * value unconditionally: a hit/headshot result, or {@code null} to suppress the
     * vanilla hit (a bullet that misses the drawn body must not damage the player).
     * When it returns {@code null} the vanilla TaCZ logic simply continues.</p>
     */
    @Inject(method = "getHitResult", at = @At("HEAD"), cancellable = true, remap = false)
    private static void tph$bodyHit(Projectile projectile, Entity entity, Vec3 start, Vec3 end,
                                    CallbackInfoReturnable<EntityKineticBullet.EntityResult> cir) {
        TaCZBulletHitHandler.Outcome outcome = TaCZBulletHitHandler.handle(projectile, entity, start, end);
        if (outcome != null) {
            cir.setReturnValue(outcome.result());
        }
    }

    /**
     * Widens the entity candidate search from {@code inflate(1.0)} to {@code inflate(2.0)}
     * (or leaves it untouched when the feature is disabled). Target is the SRG name of
     * {@code AABB#inflate(double)} as it appears in the runtime TaCZ jar.
     */
    @Redirect(method = {"findEntityOnPath", "findEntitiesOnPath"},
            at = @At(value = "INVOKE",
                    target = "Lnet/minecraft/world/phys/AABB;m_82400_(D)Lnet/minecraft/world/phys/AABB;",
                    remap = false),
            remap = false)
    private static AABB tph$widenSearch(AABB searchBox, double inflateAmount) {
        return TaCZBulletHitHandler.widenCandidateSearch(searchBox, inflateAmount);
    }
}
