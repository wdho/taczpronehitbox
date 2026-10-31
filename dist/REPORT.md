# REPORT — TaCZ Prone Hitbox v1.0.0（Forge 1.20.1 / TaCZ 1.1.8+）

## 1. 交付物
- 模组 jar：`build/libs/taczpronehitbox-1.20.1-1.0.0.jar`（同时复制到 `dist/`）
- 源码：`src/main/java/com/li/taczpronehitbox/**`
- 用户文档：`README.md`
- 工具：`tools/verify_jar.ps1`（静态校验）、`tools/run_server_smoke*.ps1`（冒烟脚本）
- 离线构建入口：`build-offline.bat`（GRADLE_USER_HOME 指向项目内 `.gradle-home`）

## 2. 实现原理
1. **判定形状**：趴下玩家在本地坐标（X 左右 / Y 上 / Z 身体前方）使用一个长方体
   （默认 0.68×0.55×1.45，中心沿身体朝向偏移 0.52），按 `yBodyRot` 旋转到世界。
   命中检测直接做"射线 vs 有向盒"，所以**任意 yaw 下尺寸恒定**——不存在"把 AABB 跟着转"
   导致的 45° 膨胀（参考视频里侧身判定箱巨大的根因）。
2. **TaCZ 接入**：mixin `tacz.EntityUtilMixin`（remap=false，无 refmap）：
   - `@Inject` 到 `EntityUtil.getHitResult(Projectile, Entity, Vec3, Vec3)` HEAD：
     目标是趴下玩家 → 用 `ProneShape` 做射线检测；命中返回 `EntityKineticBullet.EntityResult`，
     脱靶返回 null 抑制原版小方块命中；非趴下玩家不拦截。
   - `@Redirect` `findEntityOnPath` / `findEntitiesOnPath` 里的 `AABB.inflate(D)`（SRG `m_82400_`），
     把候选实体搜索半径从 1 加到 2，让长身体盒始终在候选列表里。
   - mixin priority=1500（与 gd656peek 等 HEAD 注入共存时，趴下目标确定性归本 mod）。
3. **延迟补偿**：每 tick 记录玩家（位置、身体 yaw）历史；服务端命中时射手是 ServerPlayer 时按
   `Mth.ceil(ping/1000*20 + 0.5)`（与 TaCZ 自带 HitboxHelper 完全相同）回滚目标姿态。
4. **调试渲染**：Forge `RenderLevelStageEvent.AFTER_ENTITIES`，以 `shape.anchor()` 为原点
   旋转画线框（绿=身体、红=爆头区）；VANILLA_DEBUG 模式跟随 F3+B。
5. **启动自检**：`MixinAudit` 在 common setup 强制加载 TaCZ `EntityUtil` 并反射检查注入方法，
   日志输出 "mixin applied / NOT applied"，避免静默失效。

## 3. 验证结果

| 项目 | 命令/环境 | 结果 |
| --- | --- | --- |
| 离线构建 | `cmd /c build-offline.bat build`（Gradle 8.8 + JDK17，无外网） | **BUILD SUCCESSFUL**，jar 38,878 B |
| 几何/逻辑自测 | `cmd /c build-offline.bat selfTest` | **ALL PASS (568 checks)**：11 个 yaw 命中、尺寸恒定不膨胀、爆头区边界、脱靶、擦边、退化射线、ping 回滚公式 1–2500ms 扫频与 `Mth.ceil` 逐点一致 |
| jar 静态校验 | `tools/verify_jar.ps1` | **PASS 30 / FAIL 0 / WARN 0 / SKIP 1**，exit 0：jar 结构、MANIFEST MixinConfigs、mixins json、TaCZ 目标类/方法/构造器、`m_82400_` 常量池、mixin 注解目标一致性全部通过 |
| 生产服务器冒烟 | Forge **1.20.1-47.4.0** 专用服务器（用户现成服务端 libraries）+ TaCZ **1.1.8-hotfix2** + 本 jar | **服务器正常启动（Done in 1.3s）**；日志：`[taczpronehitbox] TaCZ EntityUtil mixin applied (bodyHit=true, widenSearch=true).`；config 自动生成且键默认值正确；无 mixin/injection 报错 |
| 客户端实机对枪 | — | **未覆盖**（本机离线环境无法启动带渲染的客户端；需用户在自己的先锋实例里按 F5+F3+B 验证并调参） |

### 最终 jar 指纹
- 路径：\`build/libs/taczpronehitbox-1.20.1-1.0.0.jar\` / \`dist/taczpronehitbox-1.20.1-1.0.0.jar\`
- 大小：38,878 bytes
- SHA-256：\`1A56E7C8EC214890BCF48147F3222D5E87013A639C9BD487B6F9A2085D1E258A\`
- 构建时间：2026-10-30 21:15（离线 Gradle 8.8 + JDK 17）

### 冒烟环境说明
- 用 `D:\我的世界\梦旅\梦旅3.2服务器端` 的 `libraries`（159MB）复制到项目内 `run-prod-server/`，
  mods 只放 TaCZ + 本 mod，JDK17 启动 `win_args.txt`。
- Gradle dev 的 `runServer` **不可用**：FG6 dev runtime 使用 official 映射，而 TaCZ 生产 jar 是
  SRG reobf，TaCZ 自己的 mixin 会先失败；因此生产环境冒烟采用上述真实服务端方式。

## 4. 已知风险 / 后续
1. **仅覆盖 TaCZ 枪弹命中**；原版近战/弓箭/其他枪械模组仍是原版 0.6 判定。
2. **物理碰撞箱未改**（有意为之）：避免长条 AABB 在钻 1 格洞/贴墙时卡住玩家。
3. 需**客户端+服务端**同时安装；服务端必须有 TaCZ。
4. 只支持 **TaCZ 1.1.8+**；TaCZ 若更新 `EntityUtil` 内部签名，注入会在启动期报错
   （MixinAudit 会明确打印 NOT applied）。
5. 调试渲染不隐藏原版 0.6 小白框（可后续用客户端 mixin 屏蔽；v1 保持简单）。
6. 默认身体盒尺寸是按玩家模型估算的经验值，建议用户用 F5+F3+B 对照后微调 config。
7. 启动日志会有一条无害 WARN：\`@Mixin target com.tacz.guns.util.EntityUtil is public ... and should be specified in value\`。
   功能无影响（mixin 应用成功），后续可把注解改成 \`@Mixin(value = ...)\` 消除。
8. 冲突面：任何同样 \`@Inject\` HEAD \`EntityUtil.getHitResult\` 或 \`@Redirect\` \`AABB.inflate\` 的
   TaCZ 扩展会互相覆盖；同类"命中改造"模组建议二选一，启动日志可看 NOT applied 判断。
9. 测试用服务端副本（\`run-prod-server/\`、\`run-server/prod/\`）含 libraries + TaCZ 副本约几百 MB，
   属临时测试产物，确认无需复跑后可删除（均由脚本自动重建）。
10. \`tools/*.ps1\` 在本机 Windows PowerShell 5.1 执行策略下需用
    \`powershell -NoProfile -ExecutionPolicy Bypass -File tools/verify_jar.ps1\` 运行。
11. \`tools/run_server_smoke.ps1\` 是 **FG dev runServer 反例**：必然 FAIL（FG6 dev=official 映射，
    TaCZ 生产 jar=SRG，TaCZ 自己的 mixin 先炸），仅用于说明测试环境限制；正式冒烟看
    \`tools/run_server_smoke_prod.ps1\`。

## 5. 关键文件
- 实现：`mixin/tacz/EntityUtilMixin.java`、`hit/TaCZBulletHitHandler.java`、`hit/HitMath.java`、
  `shape/ProneShape.java`、`prone/ProneHistory.java`、`client/ProneHitboxDebugRenderer.java`、`MixinAudit.java`
- 自测：`test/HitboxSelfTest.java`
- 文档：`README.md`、`DESIGN.md`
---

# v1.1.0 追加验证（统一版：趴下命中箱 + 疾跑锁定 + 握手）

## 交付变化
- 版本 1.1.0，一个 jar 覆盖客户端/服务端/单人，不再需要分开构建。
- 新增 `sprint/SprintLockClient`、`sprint/SprintLockConfig`（疾跑锁定，R 键；旧 `seamlesssprint.properties` 首次启动自动迁移）。
- 新增 `net/ProneHitboxNetwork`、`ServerHelloPacket`、`ServerPresence`、`ClientPresenceHooks`：
  服务端装 mod 时登录发 S2C hello；客户端 100 tick 内收不到且是远程服 → 提示一次并默认隐藏身体调试框（`server.requireServerMod`）。
- 保留 `ProneHitboxMod` 构造里的 `ProneHitboxNetwork.register()`（dedicated server 唯一注册入口）。

## 验证矩阵（v1.1.0）
| 项目 | 结果 |
| --- | --- |
| 离线构建 | BUILD SUCCESSFUL，jar 55,754 B（含 net/sprint/lang） |
| 几何自测 | selfTest ALL PASS (568 checks) |
| jar 静态校验 | verify_jar.ps1 PASS 30 / FAIL 0 / WARN 0 / SKIP 1 |
| 生产专用服务器（Forge 47.4.0 + TaCZ 1.1.8-hotfix2） | 正常 Done；日志有 network channel 注册 + EntityUtil mixin applied；无本 mod 错误 |
| **真实客户端全量启动**（用户实例完整副本：106 mods、Forge 47.4.26、Java 21） | **PASS**：36.9s 到达标题界面；`TaCZ EntityUtil mixin applied (bodyHit=true, widenSearch=true)`；网络通道注册；疾跑配置迁移（enabled=false）+ 加载；无本 mod 相关 Mixin/注入/崩溃错误；两个已知 ERROR（ModernFix reload listener、addLayer wrong thread）在加 mod 前的旧日志中已存在 |
| 自动日志分析（tools/analyze_launch_log.ps1 跑本次真实日志） | PASS 9 / FAIL 0 / WARN 1（WARN 为网络通道检查无 INFO 时不阻断） |
| 安装脚本 / 回滚 | tools/launch_test.ps1 + install_to_instance.ps1：假实例 E2E、回滚、崩溃/超时路径均通过；用户实例在测试前后 mods 仍为 111 个文件、旧 seamlesssprint jar 仍在（未被本会话改动） |

## 本次测试方式（为什么不是直接装进用户实例）
本会话的文件沙箱只允许写工作目录，**无法直接写 `D:\\我的世界\\先锋\\.minecraft\\versions\\TACZ-先锋-0.7\\mods`**（提权审批在本环境不可用，多次尝试超时）。因此：
1. 把用户实例的 mods/config/natives/version jar 复制到项目内 `test-instance/TACZ-先锋-0.7`（不含存档、不含 924MB 枪包；TaCZ 会自动导出默认枪包）；
2. 在该副本里移除旧 seamlesssprint jar、装入 1.1.0 jar（与一键安装脚本完全相同的动作）；
3. 用 PCL 生成的 `LatestLaunch.bat` 修改 gameDir 后直接启动真实客户端并采集日志；
4. 用户真实实例全程只读、未被修改（已由 verifier 脚本核对：mods 111 文件、旧 jar 仍在、日志 mtime 未变）。

正式安装请运行 `dist/安装到先锋实例.bat`（双击，或在 PowerShell 里运行 `dist/install_to_instance.ps1`）：
它会备份旧 seamlesssprint jar/配置到项目 `install-backup/`，复制新 jar，并把旧疾跑 mod 移到备份目录（避免双 R 键）；支持 `-Rollback <备份目录>` 回滚。

## 未覆盖 / 风险
1. 真实客户端只验证到**标题界面**：未进世界做对枪、F3+B 目视、疾跑手感/按键、远程服缺 mod 警告、握手接收（需要双端联机）。
2. 网络 hello / 100 tick 超时 / 调试框 gating 的客户端侧逻辑已编译 + 静态核对，但未在真实联机中触发验证。
3. 疾跑锁定迁移后默认沿用旧设置（本机旧配置为关闭，迁移后仍关闭；按 R 打开）。
4. 旧 seamlesssprint jar 必须移除，否则双 R 键/双 tick，安装脚本会处理。
---

# v1.2.0 追加：拆分回两个独立模组 + 趴下失效排查

## 变更
- **拆分**：`taczpronehitbox` 不再包含疾跑代码（删除 sprint 包），版本 1.2.0；疾跑恢复为独立模组 `seamlesssprint` 1.0.1。
- 疾跑模组默认切换键从 R 改为 **I**（避免与 TaCZ 换弹 R 冲突），旧 options 里的自定义键位继续生效。
- 命中箱模组新增客户端诊断命令 `/pronehitbox status`：打印 pose / forcedPose / TaCZ 客户端 isCrawling / 主手枪 isCanCrawl / 离地/跳跃/游泳/饥饿等，用于定位"趴下没反应"。
- 安装脚本 v2：自动备份并移除合并版 1.1.0 与旧 seamlesssprint，安装两个新 jar；支持 `-Rollback`。

## 验证（v1.2.0 + sprint 1.0.1）
| 项目 | 结果 |
| --- | --- |
| 离线构建（两个工程） | BUILD SUCCESSFUL；hitbox 53,050 B / sprint 8,441 B |
| 几何自测 | ALL PASS (568 checks) |
| jar 静态校验 | PASS 30 / FAIL 0 / WARN 0 / SKIP 1 |
| 真实客户端全量实例副本（106 mods，Forge 47.4.26，Java 21） | 分离版启动 + quickPlay 进入单人世界成功；日志有 `TaCZ EntityUtil mixin applied (bodyHit=true, widenSearch=true)`、`Registered network channel 'taczpronehitbox:main'`、`SeamlessSprint loaded`；无本模组相关 Mixin/注入/崩溃错误 |
| 用户真实实例 | 本会话只读，未改动（其 mods 里仍是合并版 1.1.0 + 旧 seamlesssprint；需运行安装脚本替换） |

## 趴下失效排查结论
1. 代码审查：命中箱模组不写入 pose/forcedPose、不修改 TaCZ crawl data/按键；疾跑模组只调用 `setSprinting`。两者均无让趴下失效的代码路径。
2. 发现用户实例当时同时存在**合并版 1.1.0 + 旧 seamlesssprint 1.0.0**（未删除旧 jar）；合并版疾跑默认 R 与 TaCZ 换弹 R 冲突（用户 options 中 old sprint 已改 I，但合并版 key 仍为 R）。
3. TaCZ 1.1.8 的趴下前置条件（字节码确认）：主手 IGun、`isCanCrawl` 为 true、冷却结束、非旁观/骑乘/离地/跳跃/游泳、世界 `EnableCrawl=true`（用户三个存档均为 true）。任何一条不满足，按 C 都不会趴下，且不会报错。
4. 由于本机沙箱下无法可靠地把键鼠输入聚焦到游戏窗口，未能完成"自动化按 C 复现趴下"；因此提供 `/pronehitbox status` 让用户直接反馈状态值，可一眼定位是枪械数据不允许、键位问题还是其它模组。
5. 已修正的兼容问题：拆分模组、删除旧合并版、疾跑默认键改 I、安装脚本统一清理旧 jar。

---

# v1.2.1 热修复：ProneHistory 并发崩溃（2026-10-31 00:52 crash）

## 崩溃
crash-reports/crash-2026-10-31_00.52.43-server.txt：
java.util.NoSuchElementException at java.util.ArrayDeque.removeLast
  at com.li.taczpronehitbox.prone.ProneHistory.record(ProneHistory.java:37)
  at com.li.taczpronehitbox.prone.ProneTicker.onPlayerTick(ProneTicker.java:19)
（Ticking player，发生在整合服务器 tick 玩家时）

## 原因
ProneHistory 用 WeakHashMap + ArrayDeque 存每个玩家的位置/身体朝向历史，但没有做线程同步。
在带有 Harium / Bons and Furious / Async 等多线程优化的 106 mod 整合包里，玩家 tick 可能从不同线程进入
（或同 tick 内与其他线程交错），未同步的 map/deque 在 size 判断与 removeLast 之间被并发修改，
导致在空 deque 上 removeLast 抛 NoSuchElementException，直接崩服。

## 修复（1.2.1）
- ProneHistory 所有访问（record/peek/latest/current/forget）统一用静态 LOCK 同步；
- 上限裁剪改为防御式 pollLast（即使异常状态也不会抛）；
- ProneTicker 对 record 的 Throwable 做记录一次并吞掉，历史记录永远不会再弄崩 tick；
- version 1.2.1。

## 验证
- 离线构建 BUILD SUCCESSFUL（taczpronehitbox-1.20.1-1.2.1.jar）；
- selfTest ALL PASS (568 checks)；
- verify_jar PASS 30 / FAIL 0 / WARN 0 / SKIP 1。

---

# v1.2.3：判定箱改成"原版碰撞箱躺地上"的外观

用户反馈：趴下后我们的绿色身体箱+红色头箱"不是我想要那种"，想要"原版碰撞箱躺地上那种"。
实现：
- client 配置新增 debug.debugStyle（VANILLA / COLORED，默认 VANILLA）：VANILLA 时绘制白色 OBB + 红色眼睛线，外观接近原版 F3+B 玩家碰撞箱；
- client 配置新增 debug.hideVanillaProneHitbox（默认 true）：通过 client mixin 取消 EntityRenderDispatcher.renderHitbox（SRG m_114441_）对趴下玩家的原版 0.6 小方块，避免 F3+B 里出现"白小方块 + 身体箱"两套；
- 命中判定/几何完全不变，仍然使用俯趴身体 OBB（含爆头区），只是显示外观改成原版风格；
- version 1.2.3。

验证：
- 构建 BUILD SUCCESSFUL；
- selfTest ALL PASS (568 checks)；
- verify_jar PASS 31 / FAIL 0 / WARN 1 / SKIP 1；
- 真实 106 mod 客户端启动测试（copy 实例）：
  `Mixing client.VanillaHitboxHideMixin from taczpronehitbox.mixins.json into net.minecraft.client.renderer.entity.EntityRenderDispatcher`
  （@Inject::tph$hideVanillaProneHitbox 已注入，无 MixinApplyError / InvalidInjectionException / 崩溃）。

---

# v1.2.4：整身判定箱对齐

用户反馈 v1.2.3 白色箱位置不对、模型和碰撞箱没套在一起（截图里箱子只覆盖腿部，身体头部在箱外）。
- 原因：旧默认箱子长度 1.45、中心 0.52（相对脚），只覆盖"腿到胸口"；趴下模型长度约等于玩家身高 1.8。
- 修复：默认 bodyLength 1.45 -> 1.80，forwardOffset 0.52 -> 0.90（箱子从脚到头顶全覆盖）；bodyWidth 0.68 -> 0.65，
  bodyHeight 0.55 -> 0.50，baseHeight 0.02 -> 0.0。
- 旧配置兼容：如果 common 配置里仍是旧默认值（1.45/0.52 等），会自动按新整身尺寸生效，不需要手改。
- 自测期望值同步更新（568 checks ALL PASS）；version 1.2.4。

---

# v1.2.5：判定箱位置诊断

- `/pronehitbox shape`：打印 player.pos、yRot/yBodyRot、pose、history sample、shape.anchor、localBox/localHeadBox、
  旋转后世界 AABB 与 8 个角点、feet->anchor 向量、当前 common 配置值；同时写入 latest.log（方便直接读日志）。
- F3+B（VANILLA 样式）在实体脚部原点额外画一个青色小方块，方便截图判断"模型相对脚部原点"和"箱子相对模型"的偏移。
- version 1.2.5。

---

# v1.2.6：判定箱朝向修正（yRot vs yBodyRot）

用户 1.2.5 的 `/pronehitbox shape` 日志：
- player.pos=(-24.432, 1.000, -305.237)  yRot=545.4429  yBodyRot=495.44287（差 50°）  pose=SWIMMING
- shape.anchor=(-25.064,1.000,-305.878)  yaw=495.44287（旧实现用 yBodyRot）
- 截图里白箱在模型旁边而不是套住模型。

原因：TaCZ 趴下（强制 Pose.SWIMMING）的模型是沿玩家**头/视线 yRot** 躺的；`yBodyRot` 只在移动时跟随，站着转头会滞后最多 90°。
修复：
- ProneHistory 采样/fallback 改用可配置的 `shape.yawSource`，默认 **HEAD**（player.getYRot()），可切 BODY；
- 1.2.4 的整身尺寸 1.8 / 0.9 保留；
- version 1.2.6。

# v1.2.5 已记录（shape 诊断命令 + 脚部青色标记）

---

# v1.2.7：前后偏移修正（模型在实体原点后方）

1.2.6 截图：白箱与模型平行了，但箱子整体在模型**前方**（屏幕上方），青色脚部原点在箱子底部、模型在原点下方（后方）。
说明 TaCZ 趴下模型实际渲染在 player.position() 的**后方**（朝镜头一侧）。
- 默认 `forwardOffset` 从 +0.90 改为 **-0.90**：箱子中心在原点后方 0.9，箱子覆盖 原点 -> 原点后方1.8，红线（头端）在靠近原点一侧。
- 兼容旧配置：旧默认 0.52 的配置迁移到 -0.9；1.2.4-1.2.6 生成的 +0.9 配置也自动迁移到 -0.9。
- version 1.2.7；自测 568 全过、jar 校验 31 PASS。

---

# v1.2.8：自己接管趴下模型渲染

用户要求"直接自己造趴下这个功能的轮子"。不再追 TaCZ/tacz-tweaks 的渲染偏移，改成：
- client mixin `ProneModelMixin` 注入 `PlayerRenderer.m_7523_`（setupRotations）HEAD，趴下玩家 `ci.cancel()`；
- `ProneModelTransform` 用与命中判定/调试箱完全相同的 `ProneShape` 计算脚部位置：
  feet = anchor - forward * halfLength；
  模型局部 +Y（脚->头）旋转到 shape forward，局部 -Z（脸）朝下（面朝下趴）；
  `forwardOffset` 默认 0（箱子以 player.position() 为中心），模型与箱子同源，按构造对齐。
- 真实 106 mod 客户端启动验证：`Mixing client.ProneModelMixin ... into PlayerRenderer`，@Inject 注入成功，无错误。
- 版本 1.2.8。

---

# v1.2.9：在白色判定箱里标出 30% 爆头区

- VANILLA 样式（白色身体箱）下，若 `debug.showHeadshotZone=true`（默认），用 `headColor`（默认红）绘制
  `ProneShape.localHeadBox()`——正是命中判定里 `isHeadshot()` 使用的前 30% 子箱，所以看到的就是实际爆头范围。
- 设 `showHeadshotZone=false` 则退回纯原版外观：白箱 + 红色眼睛线。
- version 1.2.9；构建/自测/校验通过。

---

# v1.2.10：爆头区改为头箱

用户指出：趴下后头部在身体最前端（示意图：前端椭圆头 + 长身体），不是"整个前 30% 身体"。
- 新增 common 配置 `shape.headWidth`（默认 0.36）、`shape.headLength`（默认 0.35）；
- `ProneShape.isHeadshot()` 改为：命中点在身体前端、宽度不超过 headWidth、长度从 maxZ-headLength 到 maxZ 的头箱内；
- `localHeadBox()` 同步改成头箱，因此 F3+B 的红箱子 = 实际爆头范围；
- 修复 clip 命中前面时浮点误差导致正中头爆头被判成身体（去掉 local.z <= maxZ 的边界检查）；
- `headFrontFraction` 保留但标记废弃；自测 590 项 ALL PASS；version 1.2.10。

---

# v1.3.0：硬兼容第一步（原版弹射物）+ 头箱立体化

- 新增 `mixin/vanilla/ProjectileHitMixin`：@Inject `ProjectileUtil.m_37287_`（getEntityHitResult）RETURN，
  对趴下玩家用身体 OBB 重新裁剪，取更近的命中；原版小 AABB 命中若我们身体测试 miss 则判空。
  覆盖箭、投掷物、三叉戟等原版弹射物；配置 `general.applyToVanillaProjectiles=true`。
- 头箱新增 `shape.headHeight`（默认 0.40），垂直居中：红色头箱是头部大小的立方体段，不再是贯穿身体高度的一整块；
  isHeadshot 同时检查头箱的 y 范围。
- 物理碰撞/实体 AABB 保持原版（AABB 轴对齐、无法随身体旋转）。
- 自测 612 全过；jar 校验 33 PASS。

---

# v1.3.1：爆炸可见度接管

- `ExplosionVisibilityMixin`：@Inject `Explosion.m_46064_`（getSeenPercent）HEAD，趴下玩家用 `ProneShape` 的 8 个 OBB 角点
  从爆炸中心做 `Level.clip(ClipContext.Block.COLLIDER, Fluid.NONE)`，返回可见角点比例；原版小 AABB 不再决定爆炸伤害衰减。
- 客户端准星拾取（`GameRenderer.pick`）本来就走 `ProjectileUtil.m_37287_`，1.3.0 已覆盖；服务端近战只看"实体+距离"，不需要 AABB。
- 物理碰撞/实体 AABB 保持原版（AABB 轴对齐，不能旋转）。
- 自测 612 全过；jar 校验 34 PASS。

---

# v1.3.2：头箱按玩家头部尺寸调正

用户要求"只是想让趴下的头部判定正常一点"。
- 默认 headWidth/headLength/headHeight 从 0.36/0.35/0.40 改成 **0.50/0.50/0.50**（玩家头部模型就是 0.5 立方体），
  位于身体前端、垂直居中；isHeadshot 用这个立方体，红箱也画它。
- 旧 1.2.10-1.3.1 的默认头箱值（0.36/0.35/0.40）若未被用户改过，会自动迁移到 0.50 立方体。
- 不再扩大"硬兼容"范围；版本 1.3.2，自测 612 全过。

---

# v1.3.3：趴下锁定按键

- 客户端新增 KeyMapping `key.taczpronehitbox.prone_lock`（默认 V，分类 "TaCZ 俯趴命中箱"）；
- 按 V 切换锁定：锁定后如果玩家已是趴下状态，客户端每 tick 强制 `setForcedPose(SWIMMING)` 并把 step height 设为 1.0，
  可爬 1 格楼梯/方块而不站起来；再次按 V 解锁，step height 恢复 0.6；
- C2S `ProneLockPacket`（消息 id 1）同步锁定状态，服务端在玩家 tick END 持续维持趴姿（`ProneLockServer` + `ProneLockApplier`）；
- 新 key 的 lang（zh_cn/en_us）已加；version 1.3.3，自测 612 全过。


---

# v1.4.8 - v1.4.11：头部方向对齐 + 趴下锁定修复（最终）

- **1.4.8（GPT 修复）**：头箱方向改到 `+Z` 头端；头箱放进身体箱内部，顶面与身体顶面齐平；
  `headVerticalOffset` 不再被无条件覆盖；自测覆盖 `+Z` 头 / `-Z` 脚、边界、竖直、`clip` 命中。
- **1.4.9**：趴下锁定加入服务端/客户端诊断日志；玩家 tick 用 LOWEST 优先级，尽量最后维持姿态。
- **1.4.10**：锁定键改为原始 `InputEvent.Key` 监听（不再依赖 `KeyMapping.consumeClick()`），
  避免被其他模组的按键处理吞掉；新增 `/pronehitbox lock` 状态命令与 `lock on|off`。
- **1.4.11（最终修复）**：日志确认按键/网络都正常，但 `/pronehitbox lock` 显示
  `pose=STANDING, forced=SWIMMING, step=0.6`——之前只调了 `setForcedPose`，它不改变 `getPose()`，
  所以人仍站着。现在 `hold()` 同时执行 `setPose(SWIMMING)` + `setForcedPose(SWIMMING)` +
  `setMaxUpStep(1.0)`，真正保持趴姿并允许爬 1 格台阶；解锁恢复 `STANDING` / step 0.6。
- 最终自测：**ALL PASS（677 checks）**；构建成功；JAR 校验 PASS 34 / FAIL 0。
- 最终 jar：`dist/taczpronehitbox-1.20.1-1.4.11.jar`。
- 仓库最终状态：公开（public），只保留最新版 1.4.2+；1.4.12 为最终修复。


---

# v1.4.12：修复多人服务器环境下的弹射物 mixin 崩溃

- 崩溃报告：`crash-2026-10-31_12.01.11-client.txt`，堆栈为
  `org.spongepowered.asm.mixin.injection.callback.CancellationException: The call m_37287_ is not cancellable.`
- 原因：`ProjectileHitMixin` 在 `ProjectileUtil.getEntityHitResult` 的 `RETURN` 注入里调用了
  `cir.setReturnValue(...)`，但 `@Inject` 没有声明 `cancellable = true`；在服务器/其他模组
  （Connector/harium 等）同时混入时触发。
- 修复：给该 `@Inject` 补上 `cancellable = true`；构建/自测通过，版本 1.4.12。
