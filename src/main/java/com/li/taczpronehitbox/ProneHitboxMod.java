package com.li.taczpronehitbox;

import com.li.taczpronehitbox.config.ProneHitboxConfig;
import com.li.taczpronehitbox.net.ProneHitboxNetwork;
import com.li.taczpronehitbox.prone.ProneTicker;
import net.minecraftforge.api.distmarker.Dist;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.fml.ModLoadingContext;
import net.minecraftforge.fml.javafmlmod.FMLJavaModLoadingContext;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.fml.config.ModConfig;
import net.minecraftforge.fml.loading.FMLEnvironment;

/**
 * TaCZ Prone Hitbox.
 *
 * <p>Replaces the tiny vanilla SWIMMING hitbox of a crawling TaCZ player with a
 * body-shaped, yaw-aligned oriented hitbox, used by TaCZ's bullet hit detection,
 * and optionally renders that hitbox in the hitbox debug view.</p>
 */
@Mod(ProneHitboxMod.MOD_ID)
public final class ProneHitboxMod {

    public static final String MOD_ID = "taczpronehitbox";

    public ProneHitboxMod() {
        MinecraftForge.EVENT_BUS.register(ProneTicker.class);
        FMLJavaModLoadingContext.get().getModEventBus().addListener(MixinAudit::onCommonSetup);
        ProneHitboxNetwork.register();
        ModLoadingContext.get().registerConfig(ModConfig.Type.COMMON,
                ProneHitboxConfig.COMMON_SPEC, "taczpronehitbox-common.toml");
        if (FMLEnvironment.dist == Dist.CLIENT) {
            ModLoadingContext.get().registerConfig(ModConfig.Type.CLIENT,
                    ProneHitboxConfig.CLIENT_SPEC, "taczpronehitbox-client.toml");
            ProneHitboxClient.init();
        }
    }
}