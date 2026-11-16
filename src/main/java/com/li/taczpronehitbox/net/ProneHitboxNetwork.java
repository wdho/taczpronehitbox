package com.li.taczpronehitbox.net;

import com.li.taczpronehitbox.ProneHitboxMod;
import com.li.taczpronehitbox.lock.ProneLockPacket;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.level.ServerPlayer;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.entity.player.PlayerEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.ModList;
import net.minecraftforge.network.NetworkDirection;
import net.minecraftforge.network.NetworkRegistry;
import net.minecraftforge.network.PacketDistributor;
import net.minecraftforge.network.simple.SimpleChannel;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import javax.annotation.Nullable;

/**
 * Network bootstrap for the server-presence handshake.
 *
 * <p>One channel, version {@value #PROTOCOL_VERSION}, only one packet
 * ({@link ServerHelloPacket}, server to client). Registration is idempotent: it is called
 * once from the common mod constructor (needed on a dedicated server, which never loads the
 * client bootstrap) and again from the client bootstrap; the second call is a no-op. It must
 * happen during mod construction, because Forge locks the impl-channel registry when the
 * loading phase reaches COMPLETE (FREEZE_DATA).</p>
 *
 * <p>Both version predicates accept <em>every</em> value, including
 * {@link NetworkRegistry#ABSENT} and {@link NetworkRegistry#ACCEPTVANILLA}. This is
 * deliberate: a server that has this mod must stay joinable by vanilla clients and by
 * clients without the mod. The handshake then simply skips the hello for those clients (see
 * {@link #onPlayerLoggedIn(PlayerEvent.PlayerLoggedInEvent)}), and the client-side detection
 * in {@link ClientPresenceHooks} handles the opposite direction.</p>
 */
public final class ProneHitboxNetwork {

    /** Channel protocol version; bump only if the packet format changes incompatibly. */
    public static final String PROTOCOL_VERSION = "1";

    public static final ResourceLocation CHANNEL_ID =
            ResourceLocation.fromNamespaceAndPath(ProneHitboxMod.MOD_ID, "main");

    private static final Logger LOGGER = LoggerFactory.getLogger("taczpronehitbox");
    private static final String UNKNOWN_VERSION = "unknown";

    @Nullable
    private static SimpleChannel channel;
    private static boolean registered;

    private ProneHitboxNetwork() {
    }

    /**
     * Creates the channel and registers the server hello message exactly once per JVM.
     *
     * <p>Called from the common mod constructor (both sides) and from the client bootstrap;
     * safe to call multiple times.</p>
     */
    public static synchronized void register() {
        if (registered) {
            return;
        }
        registered = true;
        try {
            SimpleChannel created = NetworkRegistry.newSimpleChannel(
                    CHANNEL_ID,
                    () -> PROTOCOL_VERSION,
                    // clientAcceptedVersions: accept the server's protocol version, ABSENT (server
                    // without the mod) and ACCEPTVANILLA (plain vanilla server).
                    version -> true,
                    // serverAcceptedVersions: accept every client, including clients without the
                    // mod. Never make the channel required - that would kick vanilla clients.
                    version -> true);
            created.messageBuilder(ServerHelloPacket.class, ServerHelloPacket.ID, NetworkDirection.PLAY_TO_CLIENT)
                    .encoder(ServerHelloPacket::encode)
                    .decoder(ServerHelloPacket::decode)
                    .consumerMainThread(ServerHelloPacket::handle)
                    .add();
            created.messageBuilder(ProneLockPacket.class, ProneLockPacket.ID, NetworkDirection.PLAY_TO_SERVER)
                    .encoder(ProneLockPacket::encode)
                    .decoder(ProneLockPacket::decode)
                    .consumerMainThread(ProneLockPacket::handle)
                    .add();
            channel = created;
            MinecraftForge.EVENT_BUS.register(ProneHitboxNetwork.class);
            LOGGER.info("[taczpronehitbox] Registered network channel '{}' (protocol {}, S2C server hello only).",
                    CHANNEL_ID, PROTOCOL_VERSION);
        } catch (RuntimeException e) {
            // Never let a network setup problem crash mod loading: the mod still works in
            // singleplayer, it just cannot detect dedicated servers.
            LOGGER.error("[taczpronehitbox] Failed to register network channel '{}'; "
                    + "server-presence detection is disabled for this session.", CHANNEL_ID, e);
        }
    }

    /** Send a client-to-server lock packet (no-op on a server or when the channel is absent). */
    public static void sendToServer(Object message) {
        SimpleChannel active = channel;
        if (active == null) {
            return;
        }
        try {
            active.sendToServer(message);
        } catch (RuntimeException e) {
            LOGGER.warn("[taczpronehitbox] Failed to send network message; ignoring.", e);
        }
    }

    /** Whether the channel/message got registered (used by diagnostics only). */
    public static boolean isRegistered() {
        return channel != null;
    }

    /**
     * Server side: tell a logging-in player that this server runs the mod.
     *
     * <p>Only sent when Forge's handshake says the client actually has this channel. A
     * network packet on a channel the other side never registered is ignored by Forge, but
     * skipping it keeps vanilla/other-modded clients free of "unknown custom packet"
     * warnings. The client falls back to {@link ServerPresence#onServerMissing()} after the
     * grace period when no hello arrives.</p>
     */
    @SubscribeEvent
    public static void onPlayerLoggedIn(PlayerEvent.PlayerLoggedInEvent event) {
        if (!(event.getEntity() instanceof ServerPlayer player)) {
            return;
        }
        SimpleChannel activeChannel = channel;
        if (activeChannel == null) {
            LOGGER.warn("[taczpronehitbox] Network channel is not registered; cannot greet {}.",
                    player.getGameProfile().getName());
            return;
        }
        String version = modVersion();
        try {
            if (!isRemoteChannelPresent(activeChannel, player)) {
                LOGGER.info("[taczpronehitbox] {} has no client-side '{}' channel; skipping server hello "
                        + "(the client, if modded, will treat this server as unmodded).",
                        player.getGameProfile().getName(), CHANNEL_ID);
                return;
            }
            activeChannel.send(PacketDistributor.PLAYER.with(() -> player), new ServerHelloPacket(version));
            LOGGER.info("[taczpronehitbox] Sent server hello (mod version '{}') to {}.",
                    version, player.getGameProfile().getName());
        } catch (RuntimeException e) {
            LOGGER.warn("[taczpronehitbox] Failed to send the server hello to {}.",
                    player.getGameProfile().getName(), e);
        }
    }

    /**
     * Server side: whether the client that is logging in advertised our channel during the
     * Forge handshake.
     */
    private static boolean isRemoteChannelPresent(SimpleChannel activeChannel, ServerPlayer player) {
        return player.connection != null
                && player.connection.connection != null
                && activeChannel.isRemotePresent(player.connection.connection);
    }

    /** Our own mod version, for diagnostics; falls back to {@code "unknown"} outside a mod list. */
    private static String modVersion() {
        try {
            return ModList.get()
                    .getModContainerById(ProneHitboxMod.MOD_ID)
                    .map(container -> container.getModInfo().getVersion().toString())
                    .orElse(UNKNOWN_VERSION);
        } catch (RuntimeException e) {
            return UNKNOWN_VERSION;
        }
    }
}