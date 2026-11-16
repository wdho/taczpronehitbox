package com.li.taczpronehitbox;

import net.minecraftforge.fml.ModList;
import net.minecraftforge.fml.event.lifecycle.FMLCommonSetupEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.lang.reflect.Method;

/**
 * Startup safety check: force-loads TaCZ's {@code EntityUtil} and verifies that our
 * mixin handlers were actually injected.
 *
 * <p>Mixin application happens when the target class is loaded, and on a dedicated
 * server {@code EntityUtil} is normally loaded lazily on the first shot. Loading it once
 * during common setup lets a broken/renamed mixin fail loudly in the log at startup
 * instead of silently doing nothing in combat. Loading the class has no side effects:
 * its static initialiser only builds a predicate.</p>
 */
public final class MixinAudit {

    private static final Logger LOGGER = LoggerFactory.getLogger("taczpronehitbox");

    private MixinAudit() {
    }

    public static void onCommonSetup(FMLCommonSetupEvent event) {
        event.enqueueWork(MixinAudit::audit);
    }

    private static void audit() {
        if (!ModList.get().isLoaded("tacz")) {
            LOGGER.warn("[taczpronehitbox] TaCZ is not loaded - prone hitbox takeover is inactive.");
            return;
        }
        try {
            Class<?> entityUtil = Class.forName("com.tacz.guns.util.EntityUtil", false,
                    MixinAudit.class.getClassLoader());
            boolean bodyHit = false;
            boolean widenSearch = false;
            for (Method method : entityUtil.getDeclaredMethods()) {
                String name = method.getName();
                if (name.contains("tph$bodyHit")) {
                    bodyHit = true;
                }
                if (name.contains("tph$widenSearch")) {
                    widenSearch = true;
                }
            }
            if (bodyHit && widenSearch) {
                LOGGER.info("[taczpronehitbox] TaCZ EntityUtil mixin applied (bodyHit={}, widenSearch={}).",
                        bodyHit, widenSearch);
            } else {
                LOGGER.error("[taczpronehitbox] TaCZ EntityUtil mixin NOT applied (bodyHit={}, widenSearch={}) - "
                        + "the prone body hitbox will not work.", bodyHit, widenSearch);
            }
        } catch (Throwable throwable) {
            LOGGER.error("[taczpronehitbox] Failed to verify TaCZ EntityUtil mixin application.", throwable);
        }
    }
}
