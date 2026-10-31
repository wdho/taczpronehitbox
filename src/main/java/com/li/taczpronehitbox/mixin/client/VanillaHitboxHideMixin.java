package com.li.taczpronehitbox.mixin.client;

import com.li.taczpronehitbox.client.ProneHitboxDebugRenderer;
import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.blaze3d.vertex.VertexConsumer;
import net.minecraft.client.renderer.entity.EntityRenderDispatcher;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Hides Minecraft's own tiny SWIMMING hitbox cube for prone players in the F3+B view.
 *
 * <p>Vanilla renders {@code EntityRenderDispatcher.renderHitbox} (SRG: {@code m_114441_})
 * for every entity, which for a crawling player is the tiny 0.6x0.6 AABB. Our debug
 * renderer replaces that with the body-shaped box; without hiding the vanilla cube the
 * player sees two hitboxes at once (the green body box plus the small white cube).</p>
 *
 * <p>The injection only cancels when {@link ProneHitboxDebugRenderer#shouldReplaceVanillaHitbox}
 * says our box is actually drawn (F3+B / config / server-presence gating all pass). On a
 * dedicated server this class is never loaded (client mixin list). {@code require = 0}
 * keeps a mapping mismatch from crashing the client; in that case the vanilla cube simply
 * stays visible.</p>
 */
@Mixin(EntityRenderDispatcher.class)
public abstract class VanillaHitboxHideMixin {

    @Inject(method = "m_114441_", at = @At("HEAD"), cancellable = true, require = 0, remap = false)
    private static void tph$hideVanillaProneHitbox(PoseStack poseStack, VertexConsumer consumer,
                                                   Entity entity, float partialTick, CallbackInfo ci) {
        if (entity instanceof Player player && ProneHitboxDebugRenderer.shouldReplaceVanillaHitbox(player)) {
            ci.cancel();
        }
    }
}
