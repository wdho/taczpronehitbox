package com.li.taczpronehitbox.net;

import com.li.taczpronehitbox.config.ProneHitboxConfig;
import net.minecraft.client.Minecraft;
import net.minecraft.network.chat.Component;
import net.minecraftforge.api.distmarker.Dist;
import net.minecraftforge.api.distmarker.OnlyIn;
import net.minecraftforge.client.event.ClientPlayerNetworkEvent;
import net.minecraftforge.common.ForgeConfigSpec;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Client-side presence tracking for the server-side mod.
 *
 * <p>Resets {@link ServerPresence} whenever a (dis)connect happens, keeps it "present" in
 * singleplayer (the integrated server always has the same jar), and after a short grace
 * period decides that a remote server without a server hello does not have the mod - then
 * warns the player once (configurable) so the (now meaningless) client-side hit prediction
 * is not mistaken for a real hitbox problem.</p>
 */
@OnlyIn(Dist.CLIENT)
public final class ClientPresenceHooks {

    /**
     * Ticks to wait after entering a remote world before declaring the server unmodded.
     * Five seconds is far more than enough for the Forge handshake plus the server hello.
     */
    public static final int HELLO_GRACE_TICKS = 100;

    private static final Logger LOGGER = LoggerFactory.getLogger("taczpronehitbox");

    private static final Component SERVER_MISSING_MESSAGE = Component.literal(
            "服务器未安装 TaCZ Prone Hitbox，趴下判定仍为原版小碰撞箱。");

    private static boolean registered;
    /** Ticks spent in a remote (non-integrated) world since login, only counted while unknown. */
    private static int ticksInRemoteWorld;
    private static boolean warned;

    private ClientPresenceHooks() {
    }

    /** Registers the client-side event listeners on the Forge game bus. */
    public static void init() {
        if (registered) {
            return;
        }
        registered = true;
        MinecraftForge.EVENT_BUS.register(ClientPresenceHooks.class);
        LOGGER.info("[taczpronehitbox] Client server-presence tracking enabled "
                + "(grace period {} ticks).", HELLO_GRACE_TICKS);
    }

    @SubscribeEvent
    public static void onLoggingIn(ClientPlayerNetworkEvent.LoggingIn event) {
        ServerPresence.reset();
        ticksInRemoteWorld = 0;
        warned = false;
    }

    @SubscribeEvent
    public static void onLoggingOut(ClientPlayerNetworkEvent.LoggingOut event) {
        ServerPresence.reset();
        ticksInRemoteWorld = 0;
        warned = false;
    }

    @SubscribeEvent
    public static void onClientTick(TickEvent.ClientTickEvent event) {
        if (event.phase != TickEvent.Phase.END) {
            return;
        }
        Minecraft mc = Minecraft.getInstance();
        if (mc == null || mc.level == null || mc.player == null || mc.getConnection() == null) {
            return;
        }
        if (mc.hasSingleplayerServer()) {
            // Integrated server: same jar on both sides, always modded.
            if (!ServerPresence.isKnown()) {
                ServerPresence.onLocalServer();
            }
            return;
        }
        if (ServerPresence.isKnown()) {
            return;
        }
        ticksInRemoteWorld++;
        if (ticksInRemoteWorld < HELLO_GRACE_TICKS) {
            return;
        }
        // The hello did not arrive in time: this remote server does not run the mod.
        ServerPresence.onServerMissing();
        if (!warned) {
            warned = true;
            if (boolValue(ProneHitboxConfig.CLIENT.warnWhenServerMissing, true)) {
                mc.player.displayClientMessage(SERVER_MISSING_MESSAGE, false);
            }
        }
    }

    private static boolean boolValue(ForgeConfigSpec.BooleanValue value, boolean fallback) {
        if (value == null) {
            return fallback;
        }
        try {
            return value.get();
        } catch (IllegalStateException notLoadedYet) {
            return fallback;
        }
    }
}
