package com.li.taczpronehitbox.client;

import com.li.taczpronehitbox.config.ProneHitboxConfig;
import com.li.taczpronehitbox.config.ProneHitboxConfig.DebugStyle;
import com.li.taczpronehitbox.config.ProneHitboxConfig.ShowMode;
import com.li.taczpronehitbox.net.ServerPresence;
import com.li.taczpronehitbox.prone.ProneState;
import com.li.taczpronehitbox.shape.ProneShape;
import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.blaze3d.vertex.VertexConsumer;
import com.mojang.math.Axis;
import net.minecraft.client.Camera;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.LevelRenderer;
import net.minecraft.client.renderer.MultiBufferSource;
import net.minecraft.client.renderer.RenderType;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;
import net.minecraftforge.api.distmarker.Dist;
import net.minecraftforge.api.distmarker.OnlyIn;
import net.minecraftforge.client.event.RenderLevelStageEvent;
import net.minecraftforge.common.ForgeConfigSpec;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.util.ArrayList;
import java.util.List;

/**
 * Client-side debug renderer for the prone body hitbox.
 *
 * <p>Listens to Forge's {@link RenderLevelStageEvent} on the game bus and, at
 * {@link RenderLevelStageEvent.Stage#AFTER_ENTITIES}, draws the oriented body box of every prone
 * player (plus the headshot sub-box). This is purely cosmetic: the actual bullet hit tests live in
 * the hit-engine task and share the same {@link ProneShape} geometry, so what is drawn here is
 * exactly what TaCZ bullets test against.</p>
 *
 * <p>The box is an oriented box in body space (X = left/right, Y = up, Z = head direction). To draw
 * it we move the pose to the box anchor in camera-relative world space, rotate by the body yaw and
 * emit the local box with {@link LevelRenderer#renderLineBox}. Because the box is never rotated as
 * an AABB, its size does not change with yaw.</p>
 */
@OnlyIn(Dist.CLIENT)
public final class ProneHitboxDebugRenderer {

    private static final int DEFAULT_BODY_COLOR = 0xFF55FF55;
    private static final int DEFAULT_HEAD_COLOR = 0xFFFF5555;
    private static final boolean DEFAULT_SHOW_HEADSHOT_ZONE = true;
    private static final ShowMode DEFAULT_SHOW_MODE = ShowMode.VANILLA_DEBUG;

    private static final Logger LOGGER = LoggerFactory.getLogger("taczpronehitbox");

    private static boolean registered;
    /** Whether the "suppressed because the server may not have the mod" info was logged. */
    private static boolean serverGatingLogged;

    private ProneHitboxDebugRenderer() {
    }

    /** Registers the render hook on the Forge game bus (not the mod bus). */
    public static void init() {
        if (registered) {
            return;
        }
        registered = true;
        MinecraftForge.EVENT_BUS.register(ProneHitboxDebugRenderer.class);
    }

    @SubscribeEvent
    public static void onRenderLevelStage(RenderLevelStageEvent event) {
        if (event.getStage() != RenderLevelStageEvent.Stage.AFTER_ENTITIES) {
            return;
        }
        Minecraft mc = Minecraft.getInstance();
        if (mc == null || mc.level == null || mc.player == null) {
            return;
        }
        Camera camera = event.getCamera();
        PoseStack poseStack = event.getPoseStack();
        if (camera == null || poseStack == null || !camera.isInitialized()) {
            return;
        }
        if (!shouldDraw(mc)) {
            return;
        }

        boolean firstPerson = mc.options != null && mc.options.getCameraType().isFirstPerson();
        List<Player> pronePlayers = new ArrayList<>();
        for (Player player : mc.level.players()) {
            if (player == null || !ProneState.isProne(player)) {
                continue;
            }
            // Vanilla does not draw the local player's own hitbox in first person. If we did,
            // the camera would sit inside the box and the lines would cover the whole screen.
            // Switch to third person (F5) to see the local player's body box as well.
            if (firstPerson && player == mc.player) {
                continue;
            }
            pronePlayers.add(player);
        }
        if (pronePlayers.isEmpty()) {
            return;
        }

        DebugStyle style = debugStyleValue(ProneHitboxConfig.CLIENT.debugStyle, DebugStyle.VANILLA);
        boolean drawHeadshotZone = boolValue(ProneHitboxConfig.CLIENT.showHeadshotZone, DEFAULT_SHOW_HEADSHOT_ZONE);
        int bodyColor = intValue(ProneHitboxConfig.CLIENT.bodyColor, DEFAULT_BODY_COLOR);
        int headColor = intValue(ProneHitboxConfig.CLIENT.headColor, DEFAULT_HEAD_COLOR);

        Vec3 cameraPos = camera.getPosition();
        MultiBufferSource.BufferSource buffers = mc.renderBuffers().bufferSource();
        VertexConsumer consumer = buffers.getBuffer(RenderType.lines());
        try {
            for (Player player : pronePlayers) {
                ProneShape shape = ProneShape.forPlayer(player);
                if (shape == null) {
                    continue;
                }
                // localBox()/localHeadBox() are relative to shape.anchor(), which already includes
                // forwardOffset, so translate to the anchor (NOT player.position()).
                Vec3 anchor = shape.anchor();
                poseStack.pushPose();
                try {
                    poseStack.translate(anchor.x - cameraPos.x, anchor.y - cameraPos.y, anchor.z - cameraPos.z);
                    // Local space is: +X = right, +Y = up, +Z = head direction. The shape yaw is the
                    // body yaw in degrees, made positive clockwise when seen from above (+Y), so the
                    // rotation around +Y is -yaw.
                    poseStack.mulPose(Axis.YP.rotationDegrees(-shape.yawDeg()));
                    if (style == DebugStyle.VANILLA) {
                        // Cyan marker at the entity origin (player.position()) so screenshots can
                        // show whether the rendered crawl model is offset from the real position.
                        Vec3 feetLocal = shape.toLocal(player.position());
                        AABB feetMarker = new AABB(feetLocal.x - 0.08D, feetLocal.y, feetLocal.z - 0.08D,
                                feetLocal.x + 0.08D, feetLocal.y + 0.16D, feetLocal.z + 0.08D);
                        drawBox(poseStack, consumer, feetMarker, 0xFF00FFFF);
                        // White vanilla-style body box.
                        drawBox(poseStack, consumer, shape.localBox(), 0xFFFFFFFF);
                        if (drawHeadshotZone) {
                            // Small head box at the front tip (where the head is).
                            drawBox(poseStack, consumer, shape.localHeadBox(), headColor);
                        } else {
                            // Pure vanilla look: red eye-height line instead of the headshot box.
                            double eyeY = shape.baseHeight() + shape.height() * 0.80D;
                            double headZ = shape.halfLength() * 0.72D;
                            AABB eyeLine = new AABB(-shape.halfWidth(), eyeY, headZ - 0.01D,
                                    shape.halfWidth(), eyeY, headZ + 0.01D);
                            drawBox(poseStack, consumer, eyeLine, 0xFFFF3333);
                        }
                    } else {
                        drawBox(poseStack, consumer, shape.localBox(), bodyColor);
                        if (drawHeadshotZone) {
                            drawBox(poseStack, consumer, shape.localHeadBox(), headColor);
                        }
                    }
                } finally {
                    poseStack.popPose();
                }
            }
        } finally {
            // The line layer has its own buffer; flush it now or the lines would show up one frame
            // late (or not at all). Only flush lines, so batches belonging to other stages survive.
            buffers.endBatch(RenderType.lines());
        }
    }

    /**
     * Whether our renderer replaces Minecraft's own prone hitbox in the F3+B view.
     * Used by the client mixin that cancels {@code EntityRenderDispatcher.renderHitbox}
     * for prone players (otherwise the tiny vanilla SWIMMING cube would be drawn too).
     */
    public static boolean shouldReplaceVanillaHitbox(Player player) {
        if (player == null || !ProneState.isProne(player)) {
            return false;
        }
        Minecraft mc = Minecraft.getInstance();
        if (mc == null || mc.level == null || mc.player == null) {
            return false;
        }
        if (!shouldDraw(mc)) {
            return false;
        }
        boolean firstPerson = mc.options != null && mc.options.getCameraType().isFirstPerson();
        if (firstPerson && player == mc.player) {
            // Vanilla does not render the local player in first person at all.
            return false;
        }
        return boolValue(ProneHitboxConfig.CLIENT.hideVanillaProneHitbox, true);
    }

    /** Config showMode: NEVER draws nothing, ALWAYS always draws, VANILLA_DEBUG follows F3+B. */
    private static boolean shouldDraw(Minecraft mc) {
        ShowMode mode = enumValue(ProneHitboxConfig.CLIENT.showMode, DEFAULT_SHOW_MODE);
        boolean showModeAllows = switch (mode) {
            case NEVER -> false;
            case ALWAYS -> true;
            case VANILLA_DEBUG -> mc.getEntityRenderDispatcher() != null
                    && mc.getEntityRenderDispatcher().shouldRenderHitBoxes();
        };
        return showModeAllows && serverAllowsDrawing(mc);
    }

    /**
     * Server-presence gating.
     *
     * <p>The debug box shows the shape the <em>client-side</em> TaCZ hit prediction uses. On a
     * remote server that does not run this mod the server keeps testing the tiny vanilla
     * SWIMMING box, so drawing our box there is actively misleading. Therefore, unless
     * {@code client.requireServerMod} is disabled, the box is only drawn when:</p>
     * <ul>
     *   <li>we are in singleplayer (the integrated server always has the same jar), or</li>
     *   <li>the server explicitly confirmed presence via the S2C server hello.</li>
     * </ul>
     *
     * <p>While presence is still unknown (first ~100 ticks after joining a remote world) the
     * box stays hidden too; the client-side prediction can never be authoritative then.</p>
     */
    private static boolean serverAllowsDrawing(Minecraft mc) {
        boolean requireServerMod = boolValue(ProneHitboxConfig.CLIENT.requireServerMod, true);
        if (!requireServerMod) {
            return true;
        }
        if (mc.hasSingleplayerServer()) {
            return true;
        }
        if (ServerPresence.isPresent()) {
            return true;
        }
        if (!serverGatingLogged) {
            serverGatingLogged = true;
            LOGGER.info("[taczpronehitbox] Prone debug hitbox hidden: the current server is not confirmed to run "
                    + "this mod (presence={}). Client-side hit prediction would not match the server; "
                    + "set client.requireServerMod=false to draw it anyway.", ServerPresence.describe());
        }
        return false;
    }

    private static void drawBox(PoseStack poseStack, VertexConsumer consumer, AABB box, int argb) {
        if (box == null) {
            return;
        }
        // 0xAARRGGBB -> float components.
        float alpha = ((argb >>> 24) & 0xFF) / 255.0F;
        float red = ((argb >>> 16) & 0xFF) / 255.0F;
        float green = ((argb >>> 8) & 0xFF) / 255.0F;
        float blue = (argb & 0xFF) / 255.0F;
        LevelRenderer.renderLineBox(poseStack, consumer, box, red, green, blue, alpha);
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

    private static int intValue(ForgeConfigSpec.IntValue value, int fallback) {
        if (value == null) {
            return fallback;
        }
        try {
            return value.get();
        } catch (IllegalStateException notLoadedYet) {
            return fallback;
        }
    }

    private static DebugStyle debugStyleValue(ForgeConfigSpec.EnumValue<DebugStyle> value, DebugStyle fallback) {
        if (value == null) {
            return fallback;
        }
        try {
            return value.get();
        } catch (IllegalStateException notLoadedYet) {
            return fallback;
        }
    }

    private static ShowMode enumValue(ForgeConfigSpec.EnumValue<ShowMode> value, ShowMode fallback) {
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