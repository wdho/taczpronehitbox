package com.li.taczpronehitbox.mixin.client;

import com.li.taczpronehitbox.client.ProneModelTransform;
import com.mojang.blaze3d.vertex.PoseStack;
import net.minecraft.client.player.AbstractClientPlayer;
import net.minecraft.client.renderer.entity.player.PlayerRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Replaces vanilla's prone (SWIMMING) model placement with our own transform.
 *
 * <p>Vanilla {@code PlayerRenderer.setupRotations} (SRG {@code m_7523_}) applies the
 * crawling translation/rotation, which other mods also modify. For prone players we cancel it
 * and let {@link ProneModelTransform} place the model inside the same oriented box used by
 * hit detection and the debug renderer. Non-prone players keep vanilla behaviour.</p>
 */
@Mixin(value = PlayerRenderer.class, priority = 1600)
public abstract class ProneModelMixin {

    @Inject(method = "m_7523_(Lnet/minecraft/client/player/AbstractClientPlayer;Lcom/mojang/blaze3d/vertex/PoseStack;FFF)V",
            at = @At("HEAD"), cancellable = true, require = 0, remap = false)
    private void tph$placeProneModel(AbstractClientPlayer player, PoseStack poseStack,
                                    float ageInTicks, float rotationYaw, float partialTicks, CallbackInfo ci) {
        if (ProneModelTransform.apply(player, poseStack, partialTicks)) {
            ci.cancel();
        }
    }
}
