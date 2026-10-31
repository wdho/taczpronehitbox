# TaCZ Prone Hitbox (Minecraft Forge 1.20.1)

Pawn / crawl hitbox fix for Minecraft Forge 1.20.1. It replaces the tiny 0.6-block vanilla
AABB used while a player is prone with an oriented body box that follows the body, adds a
front headshot zone, and takes over the vanilla hit tests that otherwise ignore the pose.

> 状态：最终版本 **v1.5.4**（公开）。模型/判定箱已按实机截图对齐，头箱位于身体箱内部前端，顶面与身体顶面齐平；详细位置以游戏内 F3+B 为准。

## Features

- **Oriented body box** while prone: width / height / length / forward offset are configurable.
- **Headshot zone** at the head end of the body; configurable width / length / height / vertical offset.
- **TaCZ bullets** (`EntityUtil.getHitResult`) use the same box + latency rewind.
- **Vanilla projectiles** (arrows, throwables, tridents, fishing bobber, ...) go through
  `ProjectileUtil.getEntityHitResult`, so they use the body box too.
- **Explosion visibility** sampling uses the body box corners instead of the vanilla AABB.
- **Client debug rendering**: F3+B shows the body box (white) and head zone (red).
- **Hold-to-crawl**: hold TaCZ's crawl key and the player stays prone (setPose + setForcedPose)
  with a 1.0 step height, so falling, jumping, shooting or stairs cannot cancel the crawl.
  Release the key to automatically stand up. The hold works like the old proven pose lock:
  it does not call TaCZ's cooldown-protected crawl(true/false), so the second press always
  stands up. TaCZ's own crawl-key handler and client crawl() state changes are suspended
  (this was the gun-only stuck issue), and raw GLFW key events are tracked as a fallback to
  KeyMapping.isDown(). No extra key is needed;
  /pronehitbox lock shows the state.
- **Custom prone model renderer** that places the model from the same shape data
  (disabled for non-prone players; vanilla rendering is untouched).

Physical collision still uses the normal vanilla AABB: Minecraft only supports one AABB per
entity. Only hit *tests* are replaced.

## Install

1. Install Minecraft Forge 1.20.1 (47.x).
2. Put the jar in `mods/`. The same jar works on client and server; on a dedicated server it
   is a normal server mod, on a client it also registers the client debug renderer/key.
3. Optional: TaCZ 1.1.8+ is needed for the TaCZ bullet path; the vanilla projectile / explosion
   paths and the prone hitbox still work without TaCZ.

Built jar: `dist/taczpronehitbox-1.20.1-1.5.4.jar`.

## Usage

- Prone with TaCZ's crawl key (or any mod that sets `Pose.SWIMMING`), then:
  - F3+B: show body / head boxes;
  - `/pronehitbox status`: crawl / shape status;
  - `/pronehitbox shape`: dump the current body box, world AABB and 8 corners to `latest.log`;
  - `/pronehitbox crawl` / `/pronehitbox stand`: force crawl / stand (diagnostics).
- Hold-to-crawl: hold the TaCZ crawl key (default C; if you rebound it, e.g. B, use that key) while
  prone. Step height becomes 1.0 and the prone pose is re-applied every tick, so movement,
  jumping, shooting and stairs keep you prone. Release the key to stand up automatically.

## Build

Windows, JDK 17, Gradle 8.8 / ForgeGradle 6.0:

```bat
build-offline.bat build
build-offline.bat selfTest
```

The self test is a pure-JVM geometry test (no Minecraft client needed) and should print
`ALL PASS`. `build-offline.bat` uses a project-local `GRADLE_USER_HOME` and an offline
Maven repository; on a clean machine use `gradlew.bat build` instead.

## Config

`config/taczpronehitbox-common.toml`:

```toml
[shape]
bodyWidth = 0.65
bodyHeight = 0.50
bodyLength = 1.80
forwardOffset = 0.0
baseHeight = 0.0
headWidth = 0.65
headLength = 0.60
headHeight = 0.30
headVerticalOffset = 0.0
```

- `headVerticalOffset = 0`: head slab sits on top of the body box at the head end.
- Negative values sink it into the body; positive values raise it.
- `shape.yawSource`: `HEAD` (default, model-facing yaw) or `BODY`.

`config/taczpronehitbox-client.toml`: debug style, colors, show headshot zone, hide vanilla
prone hitbox, show mode.

## Layout

- `src/main/java/.../shape/ProneShape.java` — oriented body box + head zone + clip.
- `src/main/java/.../prone/` — per-player position/yaw history (thread-safe).
- `src/main/java/.../hit/` — TaCZ bullet hit handler.
- `src/main/java/.../mixin/` — TaCZ bullet, vanilla projectile, explosion, model renderer,
  vanilla hitbox hiding.
- `src/main/java/.../lock/` — prone lock key + client/server state.
- `src/main/java/.../client/` — debug renderer, debug commands, model transform.
- `src/main/java/.../test/HitboxSelfTest.java` — geometry self test.

## Version

Current: **1.5.4** (Forge 1.20.1, TaCZ 1.1.8 hotfix2 tested). See `REPORT.md` for the full
development log. This repository is public; only the latest release is kept.

## License

No license file yet. Ask the repository owner before redistributing.

## AI 声明 / AI Notice

本项目的代码、文档与测试由 AI 辅助生成/修改（AI-assisted）。发布者已进行构建与实机验证；内容按“现状”提供，不保证适用性，使用前请自行评估。

This project was built with AI assistance (AI-assisted). Code, docs and tests may include AI-generated content. Provided "as is"; evaluate before use.

GitHub topics: `ai-assisted`.
