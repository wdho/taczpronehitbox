package com.li.taczpronehitbox.config;

import net.minecraftforge.common.ForgeConfigSpec;
import org.apache.commons.lang3.tuple.Pair;

/**
 * Forge config. Values are deliberately generous so that the body shape can be tuned
 * in game while looking at the debug hitbox.
 */
public final class ProneHitboxConfig {

    public static final ForgeConfigSpec COMMON_SPEC;
    public static final Common COMMON;
    public static final ForgeConfigSpec CLIENT_SPEC;
    public static final Client CLIENT;

    static {
        Pair<Common, ForgeConfigSpec> commonPair = new ForgeConfigSpec.Builder().configure(Common::new);
        COMMON = commonPair.getLeft();
        COMMON_SPEC = commonPair.getRight();

        Pair<Client, ForgeConfigSpec> clientPair = new ForgeConfigSpec.Builder().configure(Client::new);
        CLIENT = clientPair.getLeft();
        CLIENT_SPEC = clientPair.getRight();
    }

    private ProneHitboxConfig() {
    }

    public enum YawSource {
        /** Use the player's body yaw (yBodyRot) - matches the prone body orientation. */
        BODY,
        /** Use the player's head yaw - hitbox follows the crosshair direction. */
        HEAD
    }

    public enum DebugStyle {
        /** White vanilla-style body box + red eye line (looks like the vanilla F3+B hitbox). */
        VANILLA,
        /** Custom coloured body box + headshot zone. */
        COLORED
    }

    public enum ShowMode {
        /** Draw only while Minecraft's hitbox debug view (F3 + B) is enabled. */
        VANILLA_DEBUG,
        ALWAYS,
        NEVER
    }

    public static final class Common {
        public final ForgeConfigSpec.BooleanValue enabled;
        public final ForgeConfigSpec.BooleanValue applyToTaczBullets;
        public final ForgeConfigSpec.BooleanValue latencyRewind;
        public final ForgeConfigSpec.BooleanValue applyToVanillaProjectiles;
        public final ForgeConfigSpec.BooleanValue applyToExplosions;

        public final ForgeConfigSpec.DoubleValue bodyWidth;
        public final ForgeConfigSpec.DoubleValue bodyHeight;
        public final ForgeConfigSpec.DoubleValue bodyLength;
        public final ForgeConfigSpec.DoubleValue forwardOffset;
        public final ForgeConfigSpec.EnumValue<YawSource> yawSource;
        public final ForgeConfigSpec.DoubleValue baseHeight;
        public final ForgeConfigSpec.DoubleValue headRadius;
        public final ForgeConfigSpec.DoubleValue headWidth;
        public final ForgeConfigSpec.DoubleValue headLength;
        public final ForgeConfigSpec.DoubleValue headHeight;
        public final ForgeConfigSpec.DoubleValue headVerticalOffset;
        public final ForgeConfigSpec.DoubleValue headFrontFraction;

        Common(ForgeConfigSpec.Builder b) {
            b.push("general");
            enabled = b.comment("Enable the body-shaped prone hitbox.")
                    .define("enabled", true);
            applyToTaczBullets = b.comment("Apply the body-shaped hitbox to TaCZ bullet hit detection.")
                    .define("applyToTaczBullets", true);
            latencyRewind = b.comment("Rewind target players by the shooter's ping like TaCZ does,",
                            "so the hitbox follows the body position the shooter actually saw.")
                    .define("latencyRewind", true);
            applyToVanillaProjectiles = b.comment("Also replace vanilla projectile hit tests (arrows, throwables, ...)",
                            "with the body-shaped OBB for prone players. Physical collision is NOT changed.")
                    .define("applyToVanillaProjectiles", true);
            applyToExplosions = b.comment("Use the prone body OBB when computing explosion visibility/damage falloff",
                            "(Explosion.getSeenPercent) instead of the tiny vanilla SWIMMING AABB.")
                    .define("applyToExplosions", true);
            b.pop();

            b.push("shape");
            yawSource = b.comment("Which yaw the prone body box follows.",
                            "HEAD = the player's look/head yaw (TaCZ's crawling model lies along the look direction),",
                            "BODY = the slower body yaw (yBodyRot).")
                    .defineEnum("yawSource", YawSource.HEAD);
            b.comment("Local body box of a prone player: width (X, left-right), height (Y),",
                            "length (Z, head-feet). forwardOffset shifts the box centre along the look direction;",
                            "0 = box centred on player.position() (the custom prone renderer puts the model exactly here).",
                            "Tune these while the debug hitbox is shown.")
                    .push("units");
            bodyWidth = b.defineInRange("bodyWidth", 0.65D, 0.2D, 1.6D);
            bodyHeight = b.defineInRange("bodyHeight", 0.50D, 0.2D, 1.2D);
            bodyLength = b.defineInRange("bodyLength", 1.80D, 0.4D, 2.4D);
            forwardOffset = b.defineInRange("forwardOffset", 0.0D, -1.6D, 1.6D);
            baseHeight = b.defineInRange("baseHeight", 0.0D, -0.3D, 0.6D);
            b.pop();
            headRadius = b.comment("Radius of the spherical headshot zone at the front tip.",
                            "The reference drawing uses a big circle for the head; this is that sphere.")
                    .defineInRange("headRadius", 0.40D, 0.10D, 1.00D);
            headWidth = b.comment("Deprecated box width (kept for old configs; sphere uses headRadius).")
                    .defineInRange("headWidth", 0.65D, 0.10D, 1.20D);
            headLength = b.comment("Length (front-to-back) of the headshot box at the front tip.")
                    .defineInRange("headLength", 0.60D, 0.10D, 1.20D);
            headHeight = b.comment("Height of the head box that sits ON TOP of the front of the body,",
                            "like the filled red slab in the reference drawing (with 头 pointing at it).")
                    .defineInRange("headHeight", 0.30D, 0.10D, 1.20D);
            headVerticalOffset = b.comment("Vertical offset of the head slab relative to the body top.",
                            "Default -0.15 sinks it halfway into the body so it does not float above the model.")
                    .defineInRange("headVerticalOffset", 0.0D, -0.30D, 0.30D);
            headFrontFraction = b.comment("Deprecated: kept only for old config compatibility.",
                            "The headshot zone is now defined by shape.headWidth / shape.headLength.")
                    .defineInRange("headFrontFraction", 0.30D, 0.05D, 0.6D);
            b.pop();
        }
    }

    public static final class Client {
        public final ForgeConfigSpec.EnumValue<DebugStyle> debugStyle;
        public final ForgeConfigSpec.EnumValue<ShowMode> showMode;
        public final ForgeConfigSpec.BooleanValue hideVanillaProneHitbox;
        public final ForgeConfigSpec.BooleanValue showHeadshotZone;
        public final ForgeConfigSpec.IntValue bodyColor;
        public final ForgeConfigSpec.IntValue headColor;

        public final ForgeConfigSpec.BooleanValue requireServerMod;
        public final ForgeConfigSpec.BooleanValue warnWhenServerMissing;

        Client(ForgeConfigSpec.Builder b) {
            b.push("debug");
            debugStyle = b.comment("How to draw the prone body hitbox.",
                            "VANILLA = white box + red eye line, like the vanilla F3+B player hitbox.",
                            "COLORED = green body box + red headshot zone.")
                    .defineEnum("debugStyle", DebugStyle.VANILLA);
            hideVanillaProneHitbox = b.comment("Hide Minecraft's own tiny SWIMMING hitbox cube for prone players,",
                            "so only the body-shaped box is shown in the F3+B view.")
                    .define("hideVanillaProneHitbox", true);
            showMode = b.comment("When to draw the prone body hitbox.",
                            "VANILLA_DEBUG = only while the F3+B hitbox debug view is on.")
                    .defineEnum("showMode", ShowMode.VANILLA_DEBUG);
            showHeadshotZone = b.comment("Draw the headshot zone in a different colour.")
                    .define("showHeadshotZone", true);
            bodyColor = b.comment("Body hitbox colour as 0xAARRGGBB.")
                    .defineInRange("bodyColor", 0xFF55FF55, Integer.MIN_VALUE, Integer.MAX_VALUE);
            headColor = b.comment("Headshot zone colour as 0xAARRGGBB.")
                    .defineInRange("headColor", 0xFFFF5555, Integer.MIN_VALUE, Integer.MAX_VALUE);
            b.pop();

            b.push("server");
            requireServerMod = b.comment("Only draw the prone body hitbox when the connected server also runs this mod.",
                            "On a server without this mod the client side cannot query the server's real hit detection,",
                            "so the debug box shows a prediction the server does not use - misleading.",
                            "Singleplayer (integrated server) always counts as \"server present\".",
                            "Set to false to always draw the box locally, exactly as before.")
                    .define("requireServerMod", true);
            warnWhenServerMissing = b.comment("Show a one-time chat warning when joining a remote server",
                            "that does not run this mod.")
                    .define("warnWhenServerMissing", true);
            b.pop();
        }
    }

    /** Which yaw the prone hitbox should follow. HEAD matches TaCZ's prone model orientation. */
    public static YawSource yawSource() {
        try {
            return COMMON.yawSource.get();
        } catch (RuntimeException notLoadedYet) {
            return YawSource.HEAD;
        }
    }

    public static boolean enabled() {
        try {
            return COMMON.enabled.get();
        } catch (IllegalStateException e) {
            return true;
        }
    }
}