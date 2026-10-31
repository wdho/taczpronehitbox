package com.li.taczpronehitbox.client;

import com.li.taczpronehitbox.config.ProneHitboxConfig;
import com.li.taczpronehitbox.prone.ProneHistory;
import com.li.taczpronehitbox.prone.ProneSample;
import com.li.taczpronehitbox.prone.ProneState;
import com.li.taczpronehitbox.shape.ProneShape;
import com.mojang.brigadier.builder.LiteralArgumentBuilder;
import com.tacz.guns.api.TimelessAPI;
import com.tacz.guns.api.client.gameplay.IClientPlayerGunOperator;
import com.tacz.guns.api.entity.IGunOperator;
import com.tacz.guns.api.item.IGun;
import com.tacz.guns.client.input.CrawlKey;
import com.tacz.guns.config.sync.SyncConfig;
import com.tacz.guns.entity.shooter.ShooterDataHolder;
import com.tacz.guns.util.InputExtraCheck;
import net.minecraft.ChatFormatting;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.world.entity.Pose;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.Vec3;
import net.minecraftforge.api.distmarker.Dist;
import net.minecraftforge.api.distmarker.OnlyIn;
import net.minecraftforge.client.event.RegisterClientCommandsEvent;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.eventbus.api.SubscribeEvent;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.lang.reflect.Method;

/**
 * Client-side diagnosis commands for the "crawl key does nothing" class of problems.
 *
 * <ul>
 *   <li>{@code /pronehitbox status} - prints everything TaCZ itself checks before crawling:
 *       pose, TaCZ client crawl state, gun data can_crawl, synced EnableCrawl, the key
 *       binding, and whether Forge input events are even allowed right now.</li>
 *   <li>{@code /pronehitbox crawl} / {@code /pronehitbox stand} - calls TaCZ's
 *       {@code IClientPlayerGunOperator.crawl(...)} directly, bypassing the keyboard.
 *       If this works but pressing C does not, the problem is the key/input path, not
 *       TaCZ crawl logic.</li>
 * </ul>
 */
@OnlyIn(Dist.CLIENT)
public final class ProneHitboxDebugCommands {

    private ProneHitboxDebugCommands() {
    }

    public static void init() {
        MinecraftForge.EVENT_BUS.addListener(ProneHitboxDebugCommands::onRegisterCommands);
    }

    @SubscribeEvent
    public static void onRegisterCommands(RegisterClientCommandsEvent event) {
        LiteralArgumentBuilder<CommandSourceStack> root = Commands.literal("pronehitbox")
                .then(Commands.literal("status").executes(ctx -> status()))
                .then(Commands.literal("crawl").executes(ctx -> forceCrawl(true)))
                .then(Commands.literal("stand").executes(ctx -> forceCrawl(false)))
                .then(Commands.literal("shape").executes(ctx -> shape()));
        event.getDispatcher().register(root);
    }

    private static final Logger LOGGER = LoggerFactory.getLogger("taczpronehitbox");

    /** Prints the prone body box in world coordinates. Also written to latest.log for later analysis. */
    private static int shape() {
        LocalPlayer player = Minecraft.getInstance().player;
        if (player == null) {
            return 0;
        }
        Minecraft mc = Minecraft.getInstance();
        msgLog("=== prone hitbox shape / 判定箱位置 ===");
        msgLog("player.pos=" + fmt(player.position())
                + "  yRot=" + player.getYRot()
                + "  yBodyRot=" + player.yBodyRot
                + "  xRot=" + player.getXRot()
                + "  pose=" + player.getPose()
                + "  yawSource=" + ProneHitboxConfig.yawSource()
                + "  isProne=" + ProneState.isProne(player)
                + "  camera=" + (mc.options == null ? "?" : mc.options.getCameraType()));
        msgLog("player.bb=" + player.getBoundingBox());
        ProneSample sample = ProneHistory.current(player);
        msgLog("history.sample=" + (sample == null ? "null"
                : ("pos=" + fmt(sample.pos()) + " bodyYaw=" + sample.bodyYaw())));
        ProneShape shape = ProneShape.forPlayer(player);
        if (shape == null) {
            msgLog("shape=null");
            return 0;
        }
        msgLog("shape.anchor=" + fmt(shape.anchor())
                + "  yaw=" + shape.yawDeg()
                + "  halfWidth=" + shape.halfWidth()
                + "  height=" + shape.height()
                + "  halfLength=" + shape.halfLength()
                + "  baseHeight=" + shape.baseHeight());
        msgLog("shape.localBox=" + shape.localBox() + "  localHeadBox=" + shape.localHeadBox());
        // world-space corners of the oriented box (what is actually rendered/hit-tested)
        Vec3[] corners = new Vec3[8];
        int idx = 0;
        for (double x : new double[]{shape.localBox().minX, shape.localBox().maxX}) {
            for (double y : new double[]{shape.localBox().minY, shape.localBox().maxY}) {
                for (double z : new double[]{shape.localBox().minZ, shape.localBox().maxZ}) {
                    corners[idx++] = shape.toWorld(new Vec3(x, y, z));
                }
            }
        }
        double minX = Double.MAX_VALUE, minY = Double.MAX_VALUE, minZ = Double.MAX_VALUE;
        double maxX = -Double.MAX_VALUE, maxY = -Double.MAX_VALUE, maxZ = -Double.MAX_VALUE;
        for (Vec3 c : corners) {
            minX = Math.min(minX, c.x); maxX = Math.max(maxX, c.x);
            minY = Math.min(minY, c.y); maxY = Math.max(maxY, c.y);
            minZ = Math.min(minZ, c.z); maxZ = Math.max(maxZ, c.z);
        }
        msgLog("shape.worldAabb=(" + fmt(minX) + ", " + fmt(minY) + ", " + fmt(minZ)
                + ") -> (" + fmt(maxX) + ", " + fmt(maxY) + ", " + fmt(maxZ) + ")"
                + "  size=(" + fmt(maxX - minX) + ", " + fmt(maxY - minY) + ", " + fmt(maxZ - minZ) + ")");
        for (int i = 0; i < corners.length; i++) {
            msgLog("  corner[" + i + "]=" + fmt(corners[i]));
        }
        // Useful for judging the screenshot: feet->anchor vector and feet->head-centre vector.
        msgLog("feet->anchor=" + fmt(shape.anchor().subtract(player.position())));
        try {
            msgLog("config: width=" + ProneHitboxConfig.COMMON.bodyWidth.get()
                    + " height=" + ProneHitboxConfig.COMMON.bodyHeight.get()
                    + " length=" + ProneHitboxConfig.COMMON.bodyLength.get()
                    + " forwardOffset=" + ProneHitboxConfig.COMMON.forwardOffset.get()
                    + " baseHeight=" + ProneHitboxConfig.COMMON.baseHeight.get()
                    + " headWidth=" + ProneHitboxConfig.COMMON.headWidth.get()
                    + " headLength=" + ProneHitboxConfig.COMMON.headLength.get()
                    + " headHeight=" + ProneHitboxConfig.COMMON.headHeight.get()
                    + " headVerticalOffset=" + ProneHitboxConfig.COMMON.headVerticalOffset.get());
        } catch (RuntimeException ignored) {
            msgLog("config: not loaded yet");
        }
        msgLog("说明：青色小方块=player.position()（实体脚部原点）；白箱=判定箱；红线=头部端。截图时按 F5 背后视角 + F3+B。");
        return 1;
    }

    private static String fmt(double value) {
        return String.format(java.util.Locale.ROOT, "%.3f", value);
    }

    private static String fmt(Vec3 vec) {
        return "(" + fmt(vec.x) + ", " + fmt(vec.y) + ", " + fmt(vec.z) + ")";
    }

    private static int status() {
        LocalPlayer player = Minecraft.getInstance().player;
        if (player == null) {
            return 0;
        }
        Minecraft mc = Minecraft.getInstance();
        msg("=== TaCZ Prone Hitbox / crawl status ===");
        msg("pose=" + player.getPose()
                + "  forcedPose=" + forcedPose(player)
                + "  isVisuallyCrawling=" + player.isVisuallyCrawling()
                + "  isProne(mod)=" + ProneState.isProne(player));
        msg("onGround=" + player.onGround()
                + "  jumping=" + (player.input != null && player.input.jumping)
                + "  swimming=" + player.isSwimming()
                + "  fallFlying=" + player.isFallFlying()
                + "  spectator=" + player.isSpectator()
                + "  passenger=" + player.isPassenger());
        msg("vitals: food=" + player.getFoodData().getFoodLevel()
                + "  blindness=" + player.hasEffect(net.minecraft.world.effect.MobEffects.BLINDNESS)
                + "  usingItem=" + player.isUsingItem());
        // TaCZ's own input gate: overlay/screen must be null, mouse grabbed, game running.
        boolean inGame;
        try {
            inGame = InputExtraCheck.isInGame();
        } catch (Throwable t) {
            inGame = false;
        }
        msg("input: TaCZ isInGame=" + inGame
                + "  screen=" + (mc.screen == null ? "null" : mc.screen.getClass().getSimpleName())
                + "  mouseGrabbed=" + mc.mouseHandler.isMouseGrabbed());
        try {
            msg("tacz sync: EnableCrawl=" + SyncConfig.ENABLE_CRAWL.get());
        } catch (Throwable t) {
            msg("tacz sync: EnableCrawl=<unavailable: " + t.getClass().getSimpleName() + ">");
        }
        try {
            IClientPlayerGunOperator operator = IClientPlayerGunOperator.fromLocalPlayer(player);
            msg("tacz client: isCrawl=" + (operator != null && operator.isCrawl()));
            ShooterDataHolder data = IGunOperator.fromLivingEntity(player).getDataHolder();
            msg("tacz data: holder.isCrawling=" + (data != null && data.isCrawling)
                    + "  currentGunItem=" + (data != null && data.currentGunItem != null
                    ? data.currentGunItem.get().getItem() : "null"));
        } catch (Throwable t) {
            msg("tacz: operator unavailable (" + t.getClass().getSimpleName() + ")");
        }
        try {
            KeyMapping crawlKey = CrawlKey.CRAWL_KEY;
            msg("key: " + crawlKey.getTranslatedKeyMessage().getString()
                    + "  unbound=" + crawlKey.isUnbound()
                    + "  conflictContext=" + crawlKey.getKeyConflictContext()
                    + "  (bind in Options -> Controls: key.tacz.crawl)");
        } catch (Throwable t) {
            msg("key: TaCZ crawl key unavailable (" + t.getClass().getSimpleName() + ")");
        }
        ItemStack main = player.getMainHandItem();
        IGun gun = IGun.getIGunOrNull(main);
        if (gun == null) {
            msg("mainHand: " + main.getItem() + " (not a TaCZ gun -> TaCZ crawl key does nothing)");
        } else {
            ResourceLocation gunId = gun.getGunId(main);
            boolean canCrawl = gun.isCanCrawl(main);
            msg("mainHand: " + gunId + "  isCanCrawl=" + canCrawl
                    + "  clientGunIndexPresent=" + TimelessAPI.getClientGunIndex(gunId).isPresent()
                    + "  commonGunIndexPresent=" + TimelessAPI.getCommonGunIndex(gunId).isPresent());
            if (!canCrawl) {
                msg("=> 这把枪的枪械数据不允许趴下 (can_crawl=false)，与本模组无关。");
            }
        }
        msg("如果 C 没反应：先试 /pronehitbox crawl —— 能趴说明是按键/输入路径问题；不能趴把上面完整输出发我。");
        return 1;
    }

    private static int forceCrawl(boolean crawl) {
        LocalPlayer player = Minecraft.getInstance().player;
        if (player == null) {
            return 0;
        }
        try {
            IClientPlayerGunOperator operator = IClientPlayerGunOperator.fromLocalPlayer(player);
            if (operator == null) {
                msg("IClientPlayerGunOperator 不可用");
                return 0;
            }
            operator.crawl(crawl);
            msg("已直接调用 TaCZ crawl(" + crawl + ")。等 1~2 秒后运行 /pronehitbox status，看 pose 是否变成 SWIMMING。");
            msg("若这样能趴、按 C 不能趴 => 是按键/输入事件问题（键位、输入法焦点、或输入优化 mod 拦截），不是枪械数据问题。");
        } catch (Throwable t) {
            msg("调用 crawl(" + crawl + ") 失败: " + t);
        }
        return 1;
    }

    private static Pose forcedPose(LocalPlayer player) {
        try {
            Method method = player.getClass().getMethod("getForcedPose");
            Object value = method.invoke(player);
            return value instanceof Pose pose ? pose : null;
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static void msgLog(String text) {
        msg(text);
        LOGGER.info("[taczpronehitbox] " + text);
    }

    private static void msg(String text) {
        if (Minecraft.getInstance().player != null) {
            Minecraft.getInstance().player.displayClientMessage(Component.literal(text).withStyle(ChatFormatting.GRAY), false);
        }
    }
}