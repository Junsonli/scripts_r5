# R5R 关卡标记与编辑工具

本工具用于 **R5R-v2.6.52 本地选点**：在已有地图中摆放少量物件、删除自己摆放的物件、记录 A/B/C/D 热点中心及边界点，以及 A/B/C 三队初始出生点，并保存、读取和导出坐标。它不是修改原始 BSP 地形的完整关卡编辑器。

适配器是独立 Mod `RfdEditorSupport`，默认关闭；只有专用编辑启动流程才启用。编辑会话使用专用配置，避免已有玩法与编辑操作互相干扰。不要整包覆盖游戏的 `platform/scripts`，也不要混用旧仓库根目录的安装步骤。

## 准备与安装

1. 先安装 R5R，核对 `LIVE/build.txt` 必须是 `R5R-v2.6.52`。版本不同就先停止，不强制绕过哈希或覆盖基础文件。
2. 保留本工具完整目录结构；启动器可独立运行，不依赖其他项目的脚本。
3. 关闭已有 R5R 客户端和独立服务器。工具不会强制结束正在运行的游戏。
4. 推荐双击 `Open-RdfLevelEditor.cmd`：自动定位唯一的 R5R-v2.6.52 安装、安装适配器、启动默认测试地图，并在退出游戏后恢复按键。请保持启动器窗口打开。找不到或发现多个安装时，用下面的显式路径方案。
5. 在包含本 README 的目录打开 PowerShell，将下面路径替换为本机真实的 `LIVE` 目录：

```powershell
$game = '替换为你的 R5R LIVE 目录'
$install = & '.\Install-RdfLevelEditor.ps1' -GameRoot $game
$install
```

安装器部署 `mods/RfdEditorSupport` 中的 7 个文件，另将同一份启动配置安装到 `platform/cfg/rdf_level_editor.cfg`，共 8 个文件；每个覆盖目标先备份、记录 SHA256。这个版本的原生 `exec` 需要该位置，单独放在 Mod 的 cfg 目录不能可靠加载。安装器检查并保护原有基础脚本、scripts.rson、ModList 和已有玩法；不安装旧版全量脚本。保留安装结果中的 `Manifest`（`install.json`），以后卸载要用。

## 打开地图

默认 PHASE RUNNER 地图示例：

```powershell
$session = & '.\Start-RdfLevelEditor.ps1' -GameRoot $game -Map 'mp_rr_arena_phase_runner'
$session
```

PHASE RUNNER 也是启动脚本默认地图。其他地图使用实际已安装的内部地图名，例如王者峡谷 `mp_rr_canyonlands_64k_x_64k`；不把一张地图的坐标拿去另一张使用。

希望使用自动恢复入口并指定地图时，可运行 `& '.\Open-RdfLevelEditor.ps1' -GameRoot $game -Map 'mp_rr_arena_phase_runner'`；它负责安装、启动和退出后的按键恢复。上面的手动安装/启动方式需要按本文后面的步骤手动恢复按键。

启动器先备份当前用户的 `Apex_fnf` 和 `Apex` 配置中的 `settings.cfg`，再仅为本次会话加载编辑按键。**保留返回的 `BackupManifest`**（`manifest.json`），它与安装清单是两种不同记录。

进入地图后关闭欢迎提示，等待人物生成。适配器会自动把编辑工具放到战术技能位，按 **Q**（实际绑定的战术技能键）装备。也可以使用 Esc/Tab 的 Dev Menu → Editor → Start Editing 给工具，再按战术技能键装备；这条原生菜单路径是否在本次安装中目视通过，见下方验证记录。

编辑工具装备后应出现放置预览与操作提示。如果没有，先保留日志，不反复替换游戏脚本。日志应有 `[RFD_EDITOR] SERVER_INIT`、`CLIENT_INIT`、`WEAPON_INIT`、`TOOL_GIVEN`。

## 摆放和删除

| 按键 | 功能 |
|---|---|
| Q / 战术技能键 | 装备编辑工具 |
| 鼠标左键 | 放置当前预览物件；删除模式下删除瞄准的编辑物件 |
| B | 在 Place / Delete 两种模式间切换 |
| E / R | 下一个 / 上一个模型（使用 `+use` / `+reload` 绑定） |
| Z | 下一模型分类；当前只有一个标记分类 |
| 1 / 2 | 提高 / 降低放置高度 |
| 3 | 增加 yaw，步长 15° |
| 4 | 切换网格吸附大小 |
| 5 / 6 | 调整 pitch / roll |
| 检视武器键 | 重置放置偏移、旋转；实际对应 `weapon_inspect` |
| F | 切换 noclip 飞行，便于查看高处、屋顶或边界 |
| F5 | 保存当前编辑场景 |
| F9 | 执行最近一次保存的场景回放，验证通过后才替换当前编辑场景 |

删除功能只处理编辑器自己登记的物件，不用于删除原地图建筑、地形或其他玩法实体。红框/预览模型不是已保存物件；只有点击放置或建立热点标记后，才进入场景登记表。

当前目录只有死亡之箱和训练假人两个已预缓存模型，场景上限为 200 个登记物件；热点中心和边界标记也计入数量。这一版先保证选点、摆放和保存链路，不代表完整地图资产库已经适配。

本适配器的键位与旧 SalEditor README 不完全相同，请以本表及 `cfg/rdf_level_editor.cfg` 为准。暂不提供旧版 Toys 模式、旧轮盘和完整模型浏览库，避免把未接通的旧功能当作已可用。

## 标记 A/B/C/D 热点

移动到希望的热点中心，按快捷键：

| 按键 | 标记 |
|---|---|
| F6 | A 中心 |
| F7 | B 中心 |
| F8 | C 中心 |
| F11 | D 中心 |

每组只有一个中心；再次标记同组中心会替换旧中心。标记使用可见的死亡之箱模型、文字标签和非实体碰撞，并记录人物当前位置上方约 2 个游戏单位的位置。建立标记后自动保存一次。普通左键摆放的死亡之箱不自动等于热点中心，必须使用上述标记操作。

需要记录区域边界时，在各个边界点处按 F10 打开游戏控制台，输入：

```text
rfd_mark A vertex
```

将 `A` 换成 B/C/D 可记录其他热点的边界。边界点保存为 `A_vertex_序号` 一类标签，按创建顺序保留。建议沿同一方向绕边界标记，保留高差信息；工具不擅自推断圆形半径、凸包、占领高度或最终判定形状，具体区域规则由使用方决定。

为三队分别选择**初始地面出生点**时，走到对应位置，确认已经退出 noclip 并站在可站立的地面，再输入：

```text
rfd_mark A spawn
rfd_mark B spawn
rfd_mark C spawn
```

每次到对应队伍的位置输入一条，分别保存为 `A_spawn`、`B_spawn`、`C_spawn`。同一队重复标记会替换旧出生点并自动保存，不会删除该字母的热点中心或边界。出生点标记同样记录人物位置上方约 2 个游戏单位；三队出生点独立于四个热点，字母用于标识队伍，不要求与同名字母热点中心重合。`rfd_mark D spawn` 会被拒绝，因为没有 D 队。出生点的真实角色安全检测和开局布置仍需玩法运行层验收。

其他维护指令：

```text
rfd_ed_check
rfd_ed_save
rfd_ed_load
rfd_ed_clear
```

`rfd_ed_clear` 会清理当前场景中的编辑器物件；先保存并确认再执行。控制台指令在已启用编辑配置的本地地图中使用，不是普通联机服的通用管理员接口。

## 保存、读取及交付给 AI

以游戏的 `LIVE` 目录为基准，保存位置分成两类：

| 相对目录 | 内容与用途 |
|---|---|
| `platform/rfd_editor_saves/<地图名>.rfd` | 当前地图的最新完整数据快照，交给 AI 分析坐标用 |
| `platform/rfd_editor_saves/<地图名>_<时间>_<序号>.rfd` | 带时间戳的快照副本，便于回到较早版本 |
| `platform/cfg/rfd_editor_saves/<地图名>.cfg` | 当前地图对应的游戏内回放 |
| `platform/cfg/rfd_editor_saves/latest.cfg` | 最近保存的回放，F9 默认读取此文件 |

按 **F5** 后确认日志出现 `SAVE_WRITTEN`。退出前保存，并额外复制一份 `.rfd` 到自己的项目资料目录。不要只截一张地图截图：`.rfd` 包含地图名、模型、三维坐标、角度、标签和结尾计数，便于准确交接。

按 **F9** 或执行 `rfd_ed_load` 读取 `latest.cfg`。该引擎没有本适配器可用的任意文本读取接口，因此 `.rfd` 是数据快照，`.cfg` 是由工具生成的受限导入指令；不能把 `.rfd` 改扩展名后直接 exec。回放先校验地图、数量、模型目录和数值，完整校验通过才替换当前登记物件。读取失败时查看 `LOAD_REJECT` / `IMPORT_INVALID`，不要手动执行来源不明的 cfg。

`latest.cfg` 可能来自另一张地图；跨地图默认会拒绝导入。要读取某张地图自己的最新回放，可在该地图控制台执行：

```text
exec rfd_editor_saves/mp_rr_canyonlands_64k_x_64k.cfg
```

目前不是在游戏里浏览任意历史快照的完整存档系统。保留好对应的 `.rfd` 和 `.cfg`，避免只保留其中一种；历史 `.rfd` 的单独回放转换需要后续工具支持。

### 导出热点 JSON

安装 Python 3.9 或以上版本后，在本工具目录执行。只有导出步骤需要 Python，游戏内编辑不依赖 Python：

```powershell
python '.\Export-RdfHotspots.py' "$game\platform\rfd_editor_saves\mp_rr_canyonlands_64k_x_64k.rfd" '.\hotspots.json' --expected-map mp_rr_canyonlands_64k_x_64k --require-centers
```

未标完四个中心时，可省略 `--require-centers` 导出中间成果；缺失中心记录为 `null`，`complete_centers` 为 false。默认不覆盖已有 JSON，重新导出时换一个文件名，或在确认后追加 `--force`。

JSON 的 `hotspots.A` 至 `hotspots.D` 包含 `center` 坐标、按记录顺序保存的 `vertices` 坐标数组与对应 `vertex_tags`；`props` 保留全部原始模型、`origin`、`angles` 和标签。坐标单位为游戏世界单位，不自动转换成米，不自动生成占领规则。导出器不会执行存档内容，也不修改游戏文件。

顶层 `spawns` 额外保存三组出生点：`{"A":[x,y,z],"B":[x,y,z],"C":[x,y,z]}`，未标记时对应值为 `null`；已标记分组的 `hotspots.A/B/C` 同时附带 `spawn` 字段。旧版没有出生点的 `.rfd` 仍可导出，`--require-centers` 只要求四个热点中心。交给 AI 或其他关卡工具时，先检查所需出生点是否齐全，不要把缺失的 `null` 当成有效出生位置。

导出器会拒绝缺失 END、计数不符、字段错误、跨图、非有限或异常巨大数值、重复中心/重复出生点/重复边界标签、D 队出生点和非法模型路径。模型路径只做格式校验，不把当前两个预缓存模型硬编码为永久导出限制；游戏内导入仍以适配器自己的模型目录为准。

## 恢复按键和卸载

完成编辑后，先退出游戏与 DS，再恢复本次启动前的按键：

```powershell
& '.\Restore-RdfEditorSettings.ps1' -Manifest $session.BackupManifest
```

如果已经关掉 PowerShell，使用当次输出中保留的 `manifest.json` 路径替代变量。恢复工具还会核对本次进程、配置和备份，防止把其他会话的键位误覆盖。

需要移除这次安装的适配器时：

```powershell
& '.\Restore-RdfLevelEditor.ps1' -Manifest $install.Manifest
```

这里使用安装时的 `install.json`，不是按键备份的 `manifest.json`。多次安装按新到旧恢复；安装后被人工修改的文件会触发保护，先保存差异再处理。保留自己的存档，卸载工具不应被当作清理创作文件的方式。回到普通玩法时使用平时的启动入口，适配器默认不启用。

## 验证状态

本工具使用 beta 编辑能力。文件已安装、脚本已编译、可以摆放、保存成功、重启后读取成功是不同层次，不能相互替代。

以下记录区分人工操作、原生引擎自动验证和代码检查，不代表全部按键均已人工验收：

| 验收项 | 状态 |
|---|---|
| 本机安装和启动 | 已部署并成功运行；安装器按清单备份与 SHA256 核对 |
| 完整卸载/恢复流程 | 代码及备份保护已实现；仍待单独进行恢复实机验收 |
| SERVER/CLIENT 编译、工具发放与 Q 装备 | 已通过；Q 装备已有人工反馈 |
| 鼠标左键摆放 | 已人工通过 |
| B 删除、3 旋转及其他编辑按键 | 尚未逐项人工确认 |
| 热点中心标记和保存 | 已人工通过；完整四点和边界仍需实际标注 |
| A/B/C 出生点标记和替换 | 新命令已随脚本编译通过，导出器有对应测试；尚未人工走点验证 |
| F9 对应的原生 exec 读取链路与重启后读取 | 新游戏进程读取既有 2 物件，再清空内存并读取一次：两次引擎验证通过，模型/坐标/角度/标签及顺序一致；本轮自动调用相同 exec，未代替手动按 F9 的按键验收 |
| 热点/出生点 JSON 格式与拒绝损坏数据 | 11 项标准库测试通过；不是游戏内可用性验收 |
| 实际游戏快照导出 | 已通过早期真实快照导出；新出生点快照仍待人工标注后验收 |

需要在新游戏进程重复验证已保存场景时，关闭已有游戏，在手动启动命令后追加 `-VerifyLoad`：

```powershell
$session = & '.\Start-RdfLevelEditor.ps1' -GameRoot $game -Map 'mp_rr_arena_phase_runner' -VerifyLoad
```

前提是当前地图已有可读取、且至少包含一个物件的 `platform/cfg/rfd_editor_saves/latest.cfg`。验证会在内存中载入该场景、记录模型/位置/角度/标签序列，清空内存后再次载入并比较；不会调用保存或标记，也不会改写磁盘存档。日志中应出现 `[RFD_EDITOR_TEST] PASS first_native_replay` 和 `PASS clear_then_native_replay_same_sequence`。正常启动默认不启用这项测试。

导出器测试可在本目录运行：

```powershell
python -m unittest discover -s tests -p 'test_*.py' -v
```

`tests/fixtures/sample_scene.rfd` 是人工构造的格式夹具，不是实际用户热点或地图玩法验证结果。

## 来源与许可说明

参考项目：[SalEditor](https://github.com/mostlyfireproof/scripts_r5/tree/SalEditor)、[R5Edit](https://github.com/mostlyfireproof/R5Edit)。审查基线：

- SalEditor 固定提交 `8ec63e2ed4932f0cc65ea6e9ea46338014258e00`（2022-11-20）；源码归档 SHA256 为 `7AB9F10A051E849E752C894E972C714D06BEE855B834F58C92C74C43AF9B4297`。
- R5Edit 固定提交 `2518debace9162e404a90c359be44e4dfbe9ce12`（2023-01-02）；其 [`LICENSE.txt`](https://github.com/mostlyfireproof/R5Edit/blob/2518debace9162e404a90c359be44e4dfbe9ce12/LICENSE.txt) 首行明确为 **GNU GENERAL PUBLIC LICENSE, Version 3, 29 June 2007**。
- 本适配器和本目录导出器为本次适配独立实现，不需要执行、安装或整库覆盖上述旧脚本。安装/发布清单不包含审查用的上游 vendor 源码、游戏资产、账户数据、运行日志或本机备份。
- SalEditor 审查归档根目录没有独立 LICENSE 文件；保留来源与作者说明，不把缺少许可文件解读为可任意重许可。若将来直接引入旧项目代码，应另行核对其许可，不能把旧代码标为本适配器原创。
