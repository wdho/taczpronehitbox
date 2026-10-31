package com.li.taczpronehitbox.lock;

import com.li.taczpronehitbox.ProneHitboxMod;
import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.server.level.ServerPlayer;
import net.minecraftforge.network.NetworkEvent;

import java.util.function.Supplier;

/** Client -> server: toggle the "stay prone while climbing stairs/blocks" lock. */
public record ProneLockPacket(boolean locked) {

    public static final int ID = 1;

    public static void encode(ProneLockPacket message, FriendlyByteBuf buffer) {
        buffer.writeBoolean(message.locked());
    }

    public static ProneLockPacket decode(FriendlyByteBuf buffer) {
        return new ProneLockPacket(buffer.readBoolean());
    }

    public static void handle(ProneLockPacket message, Supplier<NetworkEvent.Context> contextSupplier) {
        NetworkEvent.Context context = contextSupplier.get();
        ServerPlayer sender = context.getSender();
        if (sender != null) {
            context.enqueueWork(() -> ProneLockServer.setLocked(sender, message.locked()));
        }
        context.setPacketHandled(true);
    }
}
