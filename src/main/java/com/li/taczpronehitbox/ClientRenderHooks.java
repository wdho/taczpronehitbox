package com.li.taczpronehitbox;

import com.li.taczpronehitbox.client.ProneHitboxDebugRenderer;
import net.minecraftforge.api.distmarker.Dist;
import net.minecraftforge.api.distmarker.OnlyIn;

/**
 * Client-side Forge event hooks.
 *
 * <p>All registration must happen on the Forge game bus ({@code MinecraftForge.EVENT_BUS}), not the
 * mod bus: render events are global client events, while the mod bus is used for loading-phase events.</p>
 */
@OnlyIn(Dist.CLIENT)
final class ClientRenderHooks {

    private ClientRenderHooks() {
    }

    static void init() {
        ProneHitboxDebugRenderer.init();
    }
}