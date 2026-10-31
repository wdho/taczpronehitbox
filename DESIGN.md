# TaCZ Prone Hitbox — 设计与协作说明（内部文档）

> 目标：给 **Forge 1.20.1 + TaCZ 1.1.8** 做一个模组，让玩家“趴下（crawl）”时，
> 枪弹命中判定使用**贴合趴下身体形状的、随身体朝向旋转的判定箱**；无论身体转到什么方向，
> 判定箱尺寸都不变（不会像参考视频那样侧身时膨胀成巨大方块），并用 F3+B 调试视图可见。

---

## 1. 项目位置 / 环境 / 构建

- 项目目录：`C:\Users\li\Desktop\deepseek玩游戏\taczpronehitbox-1.20.1-forge`
- 这是 Forge 1.20.1 工程，模板来自本机已构建成功的 `seamlesssprint-1.20.1-forge`。
- **本机没有外网**（DNS 被劫持到 198.18.x.x，web 访问不可用），必须离线构建：
  ```powershell
  cd "C:\Users\li\Desktop\deepseek玩游戏\taczpronehitbox-1.20.1-forge"
  .\gradlew.bat --offline --console=plain build
  ```
- Gradle 8.8、JDK17（`D:/zulu17`，已在 gradle.properties 配好）、ForgeGradle 6.0.54、
  Forge 47.4.0、mixin 0.8.5 均已在 `C:\Users\li\.gradle` 缓存里。**不要**执行联网任务。
- TaCZ 只作为 `compileOnly` 依赖：`libs/tacz-1.20.1-1.1.8-hotfix2.jar`（1.1.8-hotfix2）。
  运行时要求用户装 TaCZ；mods.toml 里已声明 mandatory 依赖。
- 产物：`build/libs/taczpronehitbox-1.20.1-1.0.0.jar`。

### 本机参考实例（只读！不要改动）
- 用户实际游戏目录：`D:\我的世界\先锋\.minecraft\versions\tacz`
  （**绝对不要写/删/改这个目录**，只允许读取）。
- 调研产物（已解出的 TaCZ 字节码/字段说明）：
  `C:\Users\li\Desktop\deepseek玩游戏\.tmp_research\`
  - `EntityUtil.txt`：TaCZ 子弹命中核心逻辑
  - `EntityKineticBullet.txt`：子弹实体（tick / 命中流程）
  - `LivingEntityCrawl.txt`、`LocalPlayerCrawl.txt`：TaCZ 趴下实现
  - `ShooterDataHolder.txt`、`HitboxHelper.txt`、`tacz.mixins.json`

---

## 2. 关键调研结论（已确认，来自 TaCZ 1.1.8-hotfix2 字节码）

> **版本边界：只支持 TaCZ 1.1.8+。** TaCZ 1.1.7 的 `EntityUtil.getHitResult` 签名是
> `(Entity shooter, Entity target, Vec3, Vec3)`（无 Projectile 参数），且搜索框实现不同，
> 本项目的 mixin 不适配 1.1.7。mods.toml 已把依赖钉到 `[1.1.8,)`。

### 2.1 趴下状态
- TaCZ 趴下 = `Player.setForcedPose(Pose.SWIMMING)`（服务端 `LivingEntityCrawl#setCrawlPose`，
  客户端 `LocalPlayerCrawl#setCrawlPose`）。
- 因此 `player.getPose() == Pose.SWIMMING && player.isVisuallyCrawling()` 就是“干地趴下”。
  `isVisuallyCrawling` 映射 `m_20143_`，水中游泳时为 false。
- `com.tacz.guns.entity.shooter.ShooterDataHolder#isCrawling` 是 public 字段，可作补充判断。
- 玩家趴下时身体朝向 = `player.yBodyRot`（注册表里是普通字段），头可单独转。

### 2.2 TaCZ 子弹命中链路（枪弹伤害的真正入口）
- 子弹实体：`com.tacz.guns.entity.EntityKineticBullet`（客户端+服务端都存在，tick 中做射线）。
- 每个 tick 调：
  - `com.tacz.guns.util.EntityUtil#findEntityOnPath(Projectile, Vec3 start, Vec3 end)`
    返回最近的 `EntityKineticBullet$EntityResult`
  - `EntityUtil#findEntitiesOnPath(Projectile, Vec3, Vec3)` 返回列表（穿透/多目标逻辑）
- 两者都对候选实体调用 **private/protected static**：
  `com.tacz.guns.util.EntityUtil#getHitResult(Projectile projectile, Entity entity, Vec3 start, Vec3 end)`
  → `EntityKineticBullet$EntityResult`
- 原版逻辑（伪代码）：
  ```
  AABB box = HitboxHelper.getFixedBoundingBox(entity, projectile.getOwner()); // 延迟补偿 AABB
  Vec3 hit = box.clip(start, end).orElse(null);
  if (hit == null) return null;
  Vec3 rel = hit - entity.position();
  // 头部命中：配了 HeadShotAABBConfigRead.getAABB(entityType) 时用该 AABB 判定；
  //          否则 rel.y 在 [eyeHeight-0.25, eyeHeight+0.25] 内算爆头
  return new EntityResult(entity, hit, headshot);
  ```
- 候选实体搜索：`level.getEntities(projectile, projectile.getBoundingBox()
  .expandTowards(projectile.getDeltaMovement()).inflate(1.0), e -> e != null && e.isPickable() && !e.isSpectator())`；
  跳过自己、以及 `entity.isPassengerOfSameVehicle(owner)`。
- **EntityResult 构造器是 public**：`new EntityKineticBullet.EntityResult(Entity entity, Vec3 hitPos, boolean headshot)`。
- `HitboxHelper.getFixedBoundingBox(Entity, Entity)` 是 public static；它会把 AABB 按射手 ping 回滚。
- 相关 SRG 名（注解里 remap=false 时要用）：
  - `AABB.inflate(D)Lnet/minecraft/world/phys/AABB;` → `m_82400_`
  - `Entity#isVisuallyCrawling()Z` → `m_20143_`
  - `Entity#getBoundingBox()` → `m_20191_`
  - `LevelRenderer.renderLineBox(PoseStack,VertexConsumer,AABB,FFFF)` → `m_109646_`
  - `LevelRenderer.renderLineBox(PoseStack,VertexConsumer,DDDDDDFFFFFFF)` → `m_109621_`
- TaCZ 的类/方法名是它自己的源码名，**没有混淆**；所以针对 TaCZ 的 mixin 全部用
  `remap = false` + 原始名字即可，**不需要 refmap / Mixin AP**（本项目故意不引 AP，避免离线构建坑）。
  TaCZ 方法描述符里的 MC 类名在运行时是官方类名（net.minecraft...），与编译期一致。

### 2.3 渲染调试视图
- 1.20.1 的 F3+B 判定箱由 `EntityRenderDispatcher#shouldRenderHitBoxes()` 控制；
  `LevelRenderer.renderLineBox(...)` 画线框。
- 我们的做法：Forge `RenderLevelStageEvent`（AFTER_ENTITIES）里自己画**旋转后的**身体箱，
  不依赖任何 mixin。原版小白框会继续显示（可接受；文档里说明）。颜色默认绿色，爆头区红色。

---

## 3. 已实现的基础设施（Lead 已写，可直接用）

包根：`com.li.taczpronehitbox`

| 类 | 说明 |
|---|---|
| `ProneHitboxMod` | 入口；注册 COMMON/CLIENT 配置、`ProneTicker`、客户端初始化 |
| `ProneHitboxClient` / `ClientRenderHooks` | 客户端引导（renderer 任务可修改这两个文件） |
| `config.ProneHitboxConfig` | 配置：COMMON（enabled/applyToTaczBullets/latencyRewind/身体尺寸…）、CLIENT（debug 显示模式/颜色） |
| `prone.ProneState#isProne(Player)` | 趴下判断（共享） |
| `prone.ProneSample` | record(Vec3 pos, float bodyYaw) |
| `prone.ProneHistory` | 每 tick 记录位置+身体朝向；`latest/peek(ticksAgo)/current`，用于 ping 回滚 |
| `prone.ProneTicker` | Forge 事件，喂 `ProneHistory`（已注册） |
| `shape.ProneShape` | **核心几何**：本地坐标盒（X左右/Y上/Z身体前方），`clip(from,to)` 返回世界命中点或 null，`contains` / `isHeadshot` / `enclosingAabb` / `localBox` / `localHeadBox` / `forPlayer` / `fromSample` |
| `taczpronehitbox.mixins.json` | 已声明 mixin `tacz.EntityUtilMixin`（待实现；**不再使用 plugin**，TaCZ 是硬依赖） |

身体盒是**有向盒**（沿身体 yaw 旋转），不是 AABB；所以任意角度尺寸恒定，天然没有“侧身膨胀”问题。
默认参数（config）：宽 0.68、高 0.55、长 1.45、前移 0.52、贴地 0.02、头部判定为最前方 30%。

---

## 4. 工作划分（严格按 write scope，不要动别人的文件）

### 任务 A —— hit-engine（负责 TaCZ 命中接管 + 单元自测）
写文件（仅这些）：
- `src/main/java/com/li/taczpronehitbox/mixin/tacz/EntityUtilMixin.java`
- `src/main/java/com/li/taczpronehitbox/hit/TaCZBulletHitHandler.java`（以及同包辅助类）
- `src/main/java/com/li/taczpronehitbox/test/HitboxSelfTest.java`（纯 main 自测）

要求：
1. `EntityUtilMixin`：
   ```java
   @Mixin(targets = "com.tacz.guns.util.EntityUtil", remap = false)
   public abstract class EntityUtilMixin {
       @Inject(method = "getHitResult", at = @At("HEAD"), cancellable = true, remap = false)
       private static void tph$bodyHit(Projectile projectile, Entity entity, Vec3 start, Vec3 end,
                                       CallbackInfoReturnable<EntityKineticBullet.EntityResult> cir) { ... }

       @Redirect(method = {"findEntityOnPath", "findEntitiesOnPath"},
                 at = @At(value = "INVOKE",
                          target = "Lnet/minecraft/world/phys/AABB;m_82400_(D)Lnet/minecraft/world/phys/AABB;"),
                 remap = false)
       private static AABB tph$widenSearch(AABB self, double amount) {
           return self.inflate(2.0D);
       }
   }
   ```
   - `getHitResult` hook：目标玩家是趴下玩家时 → 用 `ProneShape` 做射线检测，返回
     `EntityResult`（命中）或 **null（未命中，同时阻止原版 0.6 小方块命中）**；
     配置关闭/不适用时直接 return 让原版继续。
   - ping 回滚：射手是 `ServerPlayer` 且 `latencyRewind=true` 时，
     `int ticks = Mth.ceil(shooter.latency / 1000.0 * 20.0 + 0.5);`（与 TaCZ 一致），
     取 `ProneHistory.peek(player, ticks)`；否则用 `ProneHistory.latest(player)`。
   - 爆头：`shape.isHeadshot(hit)`。
   - `@Redirect` 扩大候选搜索半径（身体比 0.6 方块长，防止子弹擦身体边缘时实体不在候选列表里）。
2. 注意：**不要**改原版 AABB / 物理碰撞箱（我们只改命中判定）。
3. `HitboxSelfTest`：纯 `public static void main`，断言（打印 PASS/FAIL，失败 exit 1）：
   - yaw 取 0/30/45/90/135/180/225/270/315 时，从身体中心上方垂直向下/从正前方水平射入都能命中；
   - 任意 yaw 下 shape 的 `enclosingAabb` 尺寸一致（长宽不随角度膨胀）；
   - 头部区命中 = true，尾部命中 = false；
   - 擦边/完全偏离的射线 = null；
   - `ProneHistory` 回滚 `peek(n)` 返回第 n 个样本（用真实 Player 难构造 → 可以直接测试 `ProneShape` 与 `TestHistory` 逻辑，或给 ProneHistory 加可测的纯函数——不要改 Lead 的类，除非只加方法）。
   - 运行方式：Lead 会在 build.gradle 加 `selfTest` JavaExec 任务，命令
     `.\gradlew.bat --offline --console=plain selfTest`。
4. 完成后必须自己跑：`gradlew --offline build` + `selfTest` 均通过；把结果发给 Lead。

### 任务 B —— debug-render（负责 F3+B 身体判定箱可视化）
写文件（仅这些）：
- `src/main/java/com/li/taczpronehitbox/client/**`（新建，如 `ProneHitboxDebugRenderer.java`）
- `src/main/java/com/li/taczpronehitbox/ProneHitboxClient.java`、`ClientRenderHooks.java`（这两个是 Lead 留给你改的）
- `src/main/resources/assets/taczpronehitbox/**`（可选 lang）

要求：
1. 注册 Forge `RenderLevelStageEvent`（`Stage.AFTER_ENTITIES`），遍历 `mc.level.players()`：
   - `ProneState.isProne(player)` 才画；
   - `ProneShape shape = ProneShape.forPlayer(player);`
   - 用 `PoseStack` 平移到 `player.position() - camera.getPosition()`，再
     `mulPose(Axis.YP.rotationDegrees(-shape.yawDeg()))`，然后
     `LevelRenderer.renderLineBox(poseStack, consumer, shape.localBox(), r,g,b,a)`；
   - 若 config `showHeadshotZone` 为 true，再用红色画 `shape.localHeadBox()`；
   - `showMode`：VANILLA_DEBUG 时仅当 `mc.getEntityRenderDispatcher().shouldRenderHitBoxes()` 为 true
     才画；ALWAYS 总画；NEVER 不画。颜色取 `ProneHitboxConfig.CLIENT.bodyColor/headColor`（0xAARRGGBB）。
2. 用 `mc.renderBuffers().bufferSource()` + `RenderType.lines()`，画完 `endBatch()`；
   注意事件期间 poseStack 的语义（先 push/pop）。
3. 必须处理：`mc.level == null`、`mc.player == null`、只画处于趴下的玩家。
4. 自己跑 `gradlew --offline build` 通过；把结果发给 Lead。

### 任务 C —— verifier（构建验证 / 静态校验 / 专用服务器冒烟 / 用户 README）
写文件（仅这些）：
- `tools/verify_jar.ps1`、`tools/run_server_smoke.ps1`（或等价脚本）
- `README.md`、`REPORT.md`、`run-server/**`、`dist/**`

要求：
1. `gradlew --offline --console=plain build` 通过；检查产物 jar：
   - 含 `taczpronehitbox.mixins.json`、`META-INF/mods.toml`、`EntityUtilMixin.class`、`ProneHitboxMixinPlugin.class`；
   - MANIFEST 有 `MixinConfigs: taczpronehitbox.mixins.json`；
   - `javap` 校验 TaCZ jar 中存在 `com.tacz.guns.util.EntityUtil#getHitResult`、`findEntityOnPath`、
     `findEntitiesOnPath`，以及 `EntityKineticBullet$EntityResult` 的 public 构造器；
   - 校验 `EntityUtil.class` 常量池里存在 `m_82400_`（@Redirect 目标）。
2. 跑 `selfTest`（任务 A 提供）。
3. 专用服务器冒烟测试（可选但优先）：
   - 复制 TaCZ jar 到 `run-server/mods/`，写 `run-server/eula.txt` (eula=true)；
   - 后台跑 `gradlew --offline --console=plain runServer`，等日志出现：
     mod 加载成功、`Mixin apply` 无 ERROR、生成 `run-server/config/taczpronehitbox-common.toml`；
   - 结束后 kill 该进程。若离线缺 server 依赖等环境问题，记录清楚，不硬碰。
4. 写中文 `README.md`（用户向）：功能、安装（客户端+服务端）、配置项（表格）、
   F3+B 调试说明、调参建议、已知限制（物理碰撞箱仍是原版；其他伤害来源/v模组不在覆盖范围；
   需要 TaCZ 1.1.7+ / Forge 1.20.1）、卸载方法。
5. 写 `REPORT.md`：做了什么、验证结果、遗留风险。
6. **不要**修改 `src/main/java/**`、`build.gradle`、`gradle.properties`。

---

## 5. 验收标准（全部满足才算完成）
- 版本边界：仅 Forge 1.20.1 + TaCZ 1.1.8+（1.1.7 不适配）。
- 渲染：调试框必须以 shape.anchor() 为原点（不是 player.position()）。
- `gradlew --offline build` 全绿，产物 jar 生成。
- mixin 目标静态校验全部通过（含 SRG 目标 `m_82400_`）。
- `selfTest` 全绿；覆盖任意 yaw 下尺寸不膨胀。
- 专用服务器冒烟：mod 正常加载、mixin 应用无 ERROR（若环境限制无法跑，需说明原因并保留脚本）。
- README/REPORT 完整。

## 6. 协作纪律
- 只改自己任务列出的文件/目录；不要动 `.tmp_research`、用户 `.minecraft`、其他项目目录。
- 禁止联网、禁止删除/移动用户文件；删除只允许清自己项目的 `build/` 等产物。
- 各任务完成后 `send_message` 给 `lead`：一句话状态 + 改了哪些文件 + 验证命令与结果。
- 遇到阻塞尽早告知 Lead，不要空等。