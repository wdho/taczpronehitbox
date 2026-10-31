package com.li.taczpronehitbox.lock;

import com.li.taczpronehitbox.net.ProneHitboxNetwork;
import com.mojang.blaze3d.platform.InputConstants;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.network.chat.Component;
import net.minecraftforge.api.distmarker.Dist;
import net.minecraftforge.api.distmarker.OnlyIn;
import net.minecraftforge.client.event.RegisterKeyMappingsEvent;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.javafmlmod.FMLJavaModLoadingContext;
import org.lwjgl.glfw.GLFW;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * Client toggle for the prone lock: while locked, a crawling player keeps the prone pose and
 * gets a 1-block step height so stairs/blocks can be climbed without standing up.
 */
@OnlyIn(Dist.CLIENT)
public final class ProneLockClient {

    private static final Logger LOGGER = LoggerFactory.getLogger("taczpronehitbox");
    private static final String CATEGORY = "key.categories.taczpronehitbox";
    private static final String KEY_NAME = "key.taczpronehitbox.prone_lock";

    private static KeyMapping lockKey;
    private static boolean locked;
    private static boolean active;
    private static boolean initialized;

    private ProneLockClient() {
    }

    public static void init() {
        if (initialized) {
            return;
        }
        initialized = true;
        FMLJavaModLoadingContext.get().getModEventBus().addListener(ProneLockClient::registerKeyMappings);
        MinecraftForge.EVENT_BUS.register(ProneLockClient.class);
    }

    @SubscribeEvent
    public static void registerKeyMappings(RegisterKeyMappingsEvent event) {
        lockKey = new KeyMapping(KEY_NAME, InputConstants.Type.KEYSYM, GLFW.GLFW_KEY_V, CATEGORY);
        event.register(lockKey);
        LOGGER.info("[taczpronehitbox] Registered prone lock key (default V).");
    }

    @SubscribeEvent
    public static void onClientTick(TickEvent.ClientTickEvent event) {
        if (event.phase != TickEvent.Phase.END) {
            return;
        }
        Minecraft mc = Minecraft.getInstance();
        LocalPlayer player = mc.player;
        if (lockKey != null && lockKey.consumeClick()) {
            toggle(player);
        }
        if (player == null) {
            return;
        }
        if (locked) {
            if (!active && ProneLockApplier.isProneNow(player)) {
                active = true;
            }
            if (active) {
                ProneLockApplier.hold(player);
            }
        }
    }

    private static void toggle(LocalPlayer player) {
        locked = !locked;
        if (locked) {
            active = player != null && ProneLockApplier.isProneNow(player);
        } else {
            active = false;
            if (player != null) {
                ProneLockApplier.release(player);
            }
        }
        if (player != null) {
            player.displayClientMessage(Component.literal(locked
                    ? "趴下锁定：开（爬楼梯/上下方块保持趴下）"
                    : "趴下锁定：关"), false);
        }
        ProneHitboxNetwork.sendToServer(new ProneLockPacket(locked));
    }
}