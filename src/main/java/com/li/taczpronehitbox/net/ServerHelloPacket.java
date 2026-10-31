package com.li.taczpronehitbox.net;

import net.minecraft.network.FriendlyByteBuf;
import net.minecraftforge.network.NetworkEvent;

import java.util.function.Supplier;

/**
 * Server-to-client handshake packet ("server hello").
 *
 * <p>Sent by the server to every player whose client also has this mod, right after that
 * player logs in. It is the only thing that tells the client "the server really does run
 * TaCZ Prone Hitbox", i.e. that client-side hit prediction/debug rendering is authoritative
 * on this connection.</p>
 *
 * <p>The packet intentionally carries only the server mod version (for logging/diagnostics);
 * the protocol version itself is negotiated by Forge's channel handshake.</p>
 */
public record ServerHelloPacket(String modVersion) {

    private static final int MAX_VERSION_LENGTH = 64;

    public ServerHelloPacket {
        if (modVersion == null) {
            modVersion = "";
        }
    }

    /** Clientbound packet id on {@link ProneHitboxNetwork#CHANNEL_ID}. */
    public static final int ID = 0;

    public static void encode(ServerHelloPacket message, FriendlyByteBuf buffer) {
        buffer.writeUtf(message.modVersion(), MAX_VERSION_LENGTH);
    }

    public static ServerHelloPacket decode(FriendlyByteBuf buffer) {
        return new ServerHelloPacket(buffer.readUtf(MAX_VERSION_LENGTH));
    }

    /**
     * Runs on the client main thread (see {@code consumerMainThread} in
     * {@link ProneHitboxNetwork#register()}). The server never receives this packet, so the
     * client-only {@link ServerPresence} state is safe to touch here.
     */
    public static void handle(ServerHelloPacket message, Supplier<NetworkEvent.Context> contextSupplier) {
        NetworkEvent.Context context = contextSupplier.get();
        if (context.getDirection().getReceptionSide().isClient()) {
            ServerPresence.onServerHello(message.modVersion());
        }
    }
}
