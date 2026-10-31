# 两个独立模组：TaCZ Prone Hitbox + Seamless Sprint

按你的要求，**不再合并成一个 jar**，拆成两个互相独立、可以分别安装/更新/删除的模组：

| 文件 | 模组 | 端 | 作用 |
| --- | --- | --- | --- |
| `taczpronehitbox-1.20.1-1.3.6.jar` | TaCZ Prone Hitbox | 客户端 + 服务端（同一个 jar） | 趴下时用贴合身体的有向判定箱代替原版 0.6 小方块；F3+B 调试框；服务端权威命中；检测服务端是否安装 |
| `seamlesssprint-1.20.1-1.0.1.jar` | Seamless Sprint | 纯客户端 | 按住 W 从第一个 tick 就疾跑；默认 **I** 键切换（改过键则沿用） |

**为什么要拆开**：两个功能没有任何代码依赖，合并后反而带来按键冲突（合并版疾跑默认 R × TaCZ 换弹 R）和"同一个 modId 新旧版本同时存在"的问题。拆开后：
- 命中箱模组**完全不碰疾跑/趴下姿态/按键**；
- 疾跑模组**完全不碰命中判定**；
- 各用各的配置，可单独删。

## 安装（重要）

如果之前装过**合并版 1.1.0**：**必须删除** `mods/taczpronehitbox-1.20.1-1.1.0.jar`，并删除旧 `mods/seamlesssprint-1.20.1-1.0.0.jar`（用下面的脚本会自动处理）。

推荐：双击 `安装到先锋实例.bat`（同目录），脚本会：
1. 备份旧 jar/配置到项目 `install-backup/<时间戳>/`；
2. 移走旧的合并版 taczpronehitbox 和旧 seamlesssprint；
3. 安装 `taczpronehitbox-1.20.1-1.3.6.jar` + `seamlesssprint-1.20.1-1.0.1.jar`；
4. 打印回滚命令（`install_to_instance.ps1 -Rollback <备份目录>`）。

手动安装：把上面两个 jar 放进 `mods`，确保没有旧版本同名/同 modId 的 jar，重启游戏。
服务端只装 `taczpronehitbox` 即可（疾跑是纯客户端模组，服务端装了也不加载）。

## 趴下（crawl）没反应？先看这里

写这个模组时**没有修改任何趴下姿态、按键或枪械数据**；TaCZ 的趴下只在这些条件同时满足时才生效（来自 TaCZ 1.1.8 字节码）：
1. 主手拿着 TaCZ 枪（`IGun`）；
2. 这把枪的枪械数据 `isCanCrawl` 为 **true**（不是所有枪都允许趴下；枪包作者可配置）；
3. 不在冷却、不是旁观/骑乘、**站在地面**、没有跳跃/游泳；
4. 服务端世界配置 `EnableCrawl=true`（你的三个存档里都是 true）。

装好新版后进游戏，手持那把枪执行命令：

```
/pronehitbox status
```

会打印：当前 pose、forcedPose、TaCZ 客户端 isCrawling、主手枪的 gunId / `isCanCrawl`、是否离地/跳跃/游泳/饥饿等。
- 如果 `isCanCrawl=false` → 是枪械数据不允许趴下，与本模组无关，换一把允许的枪或改枪包数据；
- 如果 `isCanCrawl=true` 但按趴下键后 `isCrawling` 不变 → 键位被占用/没按到（检查按键绑定 `key.tacz.crawl`；你当前绑定的是 **B**）；
- 如果 `isCrawling=true` 但人物看起来没趴 → 是动画/其他模组渲染问题，把日志发我。

另外提醒：你的实例上次是**合并版 1.1.0 + 旧 seamlesssprint 同时存在**，两者都注册了疾跑按键（R，同时 TaCZ 换弹也是 R），会产生"按 R 又换弹又开关疾跑"的混乱；这次拆分 + 安装脚本会清掉。

## 命中箱模组行为（客户端/服务端/单人统一）

| 场景 | 行为 |
| --- | --- |
| 单人 | 命中判定 + F3+B 调试框全部生效 |
| 客户端进服、服务端没装 | 客户端照常；进世界约 5 秒提示一次"服务器未安装…"，并默认不画误导性身体框（可配置） |
| 服务端装了、客户端没装 | 服务端命中判定对所有玩家生效；该客户端无调试框 |
| 双端都装 | 完整功能 |

调试：**F5 第三人称 + F3+B**：默认显示**原版风格**的白色身体箱 + 红色眼睛线（v1.3.6 起），
原版趴下那个 0.6 小白方块会被隐藏，F3+B 里只看到一个躺在地上的身体形判定箱；
想看旧的彩色样式（绿色身体 + 红色爆头区），把 client 配置 `debug.debugStyle` 改成 `COLORED`。

配置：
- `config/taczpronehitbox-common.toml`：开关 / 身体盒尺寸（bodyWidth/bodyHeight/bodyLength/forwardOffset/baseHeight）/ 爆头区比例 / ping 回滚
- `config/taczpronehitbox-client.toml`：调试显示样式（VANILLA/COLORED）、是否隐藏原版趴下小方块、颜色、需要服务端安装/缺失提示
- `config/seamlesssprint.properties`：疾跑开关（沿用你之前的 false，按 I 打开）

## 更新记录
- **v1.3.6（2026-10-31）**：修复模型和判定箱一直对不上的根因：原版 `LivingEntityRenderer` 在 `setupRotations` **之后**
  还会执行 `scale(-1,-1,1); translate(0,-1.501,0)`，我们之前把趴下摆位直接加在 setupRotations 里，等于加在了错误的坐标空间。
  现在用 `R = (S*T)*G*(S*T)^-1` 把摆位"夹"在中间，最终变换是 `S*T*G`，模型和判定箱同一坐标系。
- **v1.3.5（2026-10-31）**：红头箱恢复为占满身体高度的前端箱；
- **v1.3.6（2026-10-31）**：按用户给的参考截图，红头箱恢复为**占满身体高度的前端箱**（headHeight=0.50，宽/长 0.50），
  即白箱包身体、红箱是前端一整块；1.3.4 的"0.35 顶部小盒"已回退。
- **v1.3.4（2026-10-31）**：头箱尝试前端顶部小盒（已回退）；
- **v1.3.6（2026-10-31）**：头箱按"前端顶部独立小盒"调整：默认 0.50×0.50×**0.35**，与身体箱**顶部对齐**（不是垂直居中）；
  新增 `shape.headVerticalOffset`（正值把红头箱往上挪，可让它像图2 一样凸出在身体上方）。
- **v1.3.3（2026-10-31）**：趴下锁定按键 V；
- **v1.3.6（2026-10-31）**：新增**趴下锁定按键**（默认 **V**，可在控制里改）：趴下后按 V 锁定，
  爬楼梯/上下方块保持趴下（锁定期间把玩家 step height 提到 1.0，解锁恢复 0.6）；客户端把状态同步给服务端，
  服务端 tick 持续维持趴姿。聊天栏会提示"趴下锁定：开/关"。
- **v1.3.2（2026-10-31）**：头箱改成玩家头部 0.50 立方体；
- **v1.3.6（2026-10-31）**：只把头部判定调"正常"：头箱改成玩家头部实际的 **0.50×0.50×0.50** 立方体（前端），
  旧默认 0.36/0.35/0.40 未改动配置会自动迁移；红箱就是该头箱。不再扩大硬兼容范围。
- **v1.3.1（2026-10-31）**：爆炸可见度接管；
- **v1.3.6（2026-10-31）**：爆炸接管：`Explosion.getSeenPercent` 对趴下玩家改用身体 OBB 的 8 个角点做方块遮挡采样
  （配置 `general.applyToExplosions=true`）；原版弹射物/客户端准星拾取已由 `ProjectileUtil` mixin 覆盖；物理 AABB 保持原版。
- **v1.3.0（2026-10-31）**：原版弹射物接管 + 头箱 headHeight；
- **v1.3.6（2026-10-31）**：硬兼容第一步：新增原版弹射物接管（箭/投掷物/三叉戟等走 `ProjectileUtil.getEntityHitResult`），
  趴下玩家一律用身体 OBB 判定；配置 `general.applyToVanillaProjectiles`（默认 true）。头箱增加 `headHeight`（默认 0.40）并垂直居中，
  F3+B 红箱变成头部的立方体而不是整段身体高度。物理碰撞仍保持原版 AABB（AABB 无法旋转）。
- **v1.2.10（2026-10-31）**：爆头区改成前端头箱（headWidth/headLength）；
- **v1.3.6（2026-10-31）**：爆头区从"身体前 30%"改成**前端的头部小箱**：`shape.headWidth=0.36`、`shape.headLength=0.35`，
  只有命中这个头箱才算爆头（红箱子也画这个头箱）；`headFrontFraction` 标记为废弃仅兼容旧配置。
- **v1.2.9（2026-10-31）**：VANILLA 白色判定箱里把前 30% 划为红色爆头区；
- **v1.3.6（2026-10-31）**：VANILLA 白色判定箱里把**前 30% 爆头区**画成红色子箱（和实际爆头判定同一个 box，
  `headColor` 可调）；把 `debug.showHeadshotZone` 设 false 可恢复纯原版"白箱+红线"外观。
- **v1.2.8（2026-10-31）**：不再依赖 TaCZ/tacz-tweaks 的趴下模型摆放，**自己接管趴下模型渲染**；
- **v1.3.6（2026-10-31）**：不再依赖 TaCZ/tacz-tweaks 的趴下模型摆放，**自己接管趴下模型渲染**：客户端 mixin 取消原版
  `PlayerRenderer.setupRotations`，用与命中判定完全相同的 `ProneShape` 摆放模型（脚在 anchor-halfLength、头朝身体前方、面朝下），
  模型和判定箱**同源、按构造对齐**；判定箱居中 `forwardOffset=0`。新增客户端 mixin `ProneModelMixin`（已真实客户端验证注入成功）。
- **v1.2.7（2026-10-31）**：前后偏移修正；
- **v1.3.6（2026-10-31）**：修正判定箱相对实体原点的**前后偏移**：TaCZ 趴下模型实际渲染在实体原点**后方**（朝镜头一侧），
  所以箱子中心从 +0.90 改为 **-0.90**，箱子从实体原点向后方覆盖整条身体，红线（头端）落在靠近原点的头侧。
- **v1.2.6（2026-10-31）**：修复判定箱和趴下模型**朝向不一致**（yRot vs yBodyRot 差 50°），默认 `shape.yawSource=HEAD`。
- **v1.3.6（2026-10-31）**：修复判定箱和趴下模型**朝向不一致**：从 `/pronehitbox shape` 日志看到
  `yRot=545.44` 而 `yBodyRot=495.44`（差 50°），TaCZ 趴下模型是沿**头/视线 yRot** 躺的，而箱子之前用 yBodyRot。
  现在默认 `shape.yawSource = HEAD`（可改回 BODY），箱子与模型同向。
- **v1.2.5（2026-10-31）**：新增 `/pronehitbox shape`：打印脚部坐标、朝向、anchor、本地箱、旋转后世界包围盒与 8 个角点，
- **v1.3.6（2026-10-31）**：新增 `/pronehitbox shape`：打印脚部坐标、朝向、anchor、本地箱、旋转后世界包围盒与 8 个角点，
  并把同样的内容写入 latest.log；F3+B 时在脚部原点画一个**青色小方块**，便于截图判断模型/判定箱相对位置。
- **v1.2.4（2026-10-31）**：判定箱尺寸改成**整身覆盖**：长度 1.45 → 1.80，中心前移 0.52 → 0.90（旧配置默认值会自动迁移）。
- **v1.3.6（2026-10-31）**：判定箱尺寸改成**整身覆盖**：长度 1.45 → 1.80，中心前移 0.52 → 0.90（旧配置默认值会自动迁移；
  你想要更紧的箱可在 common 配置里改 bodyLength/forwardOffset）。同时保留 v1.2.3 的原版白色箱外观 + 红色眼睛线。
- **v1.2.3（2026-10-31）**：判定箱改成"原版外观"：白色箱体 + 红色眼睛线，并隐藏原版趴下（SWIMMING）那个 0.6 小方块，
- **v1.3.6（2026-10-31）**：判定箱改成"原版外观"：白色箱体 + 红色眼睛线，并隐藏原版趴下（SWIMMING）那个 0.6 小方块，
  F3+B 时只看到一个躺在地上的身体形判定箱。可在 client 配置里用 `debug.debugStyle` 切换回 COLORED 彩色箱，
  `hideVanillaProneHitbox` 控制是否隐藏原版小方块。命中判定逻辑不变。
- **v1.2.2（2026-10-31）**：新增趴下诊断：`/pronehitbox crawl` / `/pronehitbox stand`（绕过按键直接调用 TaCZ crawl），
  `/pronehitbox status` 增加 isInGame / screen / mouseGrabbed / EnableCrawl / 客户端 isCrawl / 按键绑定等字段。
- **v1.2.1（2026-10-31）**：修复 1.2.0 的并发崩溃（ProneHistory 在多线程 tick 的整合包里
  `ArrayDeque.removeLast` 抛 NoSuchElementException，崩服）。现已全部同步化 + 防御式裁剪 + tick 异常兜底。

## 已验证

- 构建：两个工程离线 `BUILD SUCCESSFUL`；
- 几何自测：568 checks ALL PASS；
- jar 静态校验：31 PASS / 0 FAIL / 1 WARN；
- **真实客户端全量实例副本**（你的 106 mod 包、Forge 47.4.26、Java 21）：分离版 `1.3.6 + 1.0.1` 启动并进入单人世界（quickPlay）成功，日志确认：
  - `[taczpronehitbox] TaCZ EntityUtil mixin applied (bodyHit=true, widenSearch=true)`
  - `Registered network channel 'taczpronehitbox:main'`
  - `SeamlessSprint loaded`（独立模组单独加载）
  - 无本模组相关的 Mixin/注入/崩溃错误。

## 已知限制

- 命中箱模组只接管 TaCZ 枪弹；物理碰撞箱保持原版（不改，避免钻洞卡墙）。
- 疾跑模组默认键是 **I**（避开 TaCZ 换弹 R）；你之前已经改成 I，所以无需再改。
- 未做真人进世界对枪/趴下实机操作验证（只验证到世界加载 + 日志无错误）；请用上面的 `/pronehitbox status` 反馈趴下问题。
- 合并版 1.1.0 与分离版**不能共存**（同 modId），安装脚本会移除旧版并备份。
## 附：开“无限制帧率”会导致整屏不刷新？

这是本整合包/环境层面的问题，与本模组无关：Minecraft 把最大帧率设为 **260（无限制）** 时会**跳过限帧器**，
若同时关闭垂直同步，在 854×480 小窗口可跑到 1000+ FPS，Windows DWM/GPU 显示队列被饿死 → 整个桌面停止刷新，
关掉游戏进程才恢复。**修复：保留垂直同步开启，并把最大帧率改成 120/144/165（不要选 260/无限制）**。
`dist/修复帧率卡死.bat` 可以一键改好并备份 options.txt；详细分析见 `docs/限帧卡死原因.md`。