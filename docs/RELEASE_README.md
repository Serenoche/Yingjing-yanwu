# 影境演武 · Yingjing Yanwu @VERSION@

《影之刃零》非官方演武 MOD。从游戏主菜单进入测试场、练习模式或首领挑战，保留正常游戏进度。

An unofficial Phantom Blade Zero arena MOD with testing, practice and boss challenges, accessible from the normal game menu.

## 1.1.0 更新 / What's new

- 新增自订挑战，支持最多 5 连战或 5 目标群战。
- 新增目标异常状态条，改善练习开关、首领信息与界面反馈。
- 改善配装记忆和新一轮挑战补满药瓶的体验；连战换阶段保留已消耗次数。
- 修复荆野骑乘与锁定、白赤练召蛇等战斗问题。
- 改善已有 UE4SS 的安装兼容，加入已测试旧版 Steam 游戏的针对性适配。

- Custom challenges with up to five consecutive fights or five simultaneous targets.
- Target status bars and improved practice controls, boss information and UI feedback.
- Better loadout memory and full equipped medicine charges at the start of a new attempt; charges carry over between gauntlet stages.
- Fixes for Jingye's mount and targeting, Bai Chilian's summons, and encounter stability.
- Better installation alongside existing UE4SS, with targeted support for the tested older Steam build.

## 安装和更新 / Install and update

1. 完整解压并保留整个目录，先退出游戏。
2. 双击根目录的 **影境演武安装器.exe**。
3. 选择游戏的 `platform/steam/PBZ.exe` 和自己的存档账号，点击「安装 / 更新」。多个游戏库或账号需要明确选择。
4. 完成后从 Steam 正常启动游戏，在主菜单进入「影境演武」。

首次使用前，需先正常进入游戏并创建至少一次存档。使用过内部验证入口时，应先退出游戏并从该内测目录还原，再安装正式版。

安装器优先复用已有可识别的 UE4SS，保留其他 MOD 和加载器配置；没有前置时再安装随包提供的前置。无需为了更新本 MOD 先卸载其他 MOD。无法匹配的安装布局或文件改动会提示处理。

安装会先备份当前存档，再添加演武专用槽位；普通游戏进度保留。演武的配装、自订列表和挑战记录单独保存，退出演武后恢复正常保存流程。

Fully extract the package, close the game, and run **影境演武安装器.exe**. Select your Steam `platform/steam/PBZ.exe` and save account, then choose **安装 / 更新**. Start the game normally through Steam afterward. Create a normal save before your first installation. Restore any active internal test before updating.

Recognized existing UE4SS installations are reused, preserving other MODs and loader settings. The installer adds its bundled loader when none is installed. Ordinary progress is retained; arena preferences and records are stored separately.

## 卸载与本地数据 / Uninstall and local data

退出游戏，打开同一个安装器，点击「卸载（保留进度）」。也可使用 `IntegratedMenu/` 中的安装、卸载 `.cmd` 入口。卸载保留存档、挑战记录、配装记忆、自订列表和备份，不删除其他 MOD；共用的 UE4SS 保留。

本机演武数据位于：

```text
<游戏>/ProjectPBZ/Saved/PBZTestArena/<所选Steam账号>/
```

Close the game and use **卸载（保留进度）** in the same installer. Saves, arena records, preferences, custom lists and backups are retained, along with other MODs and a shared UE4SS installation.

安装器运行不需要另外安装 Node、Python、虚幻引擎或 Oodle。UE4SS 可能需要对应的 Microsoft Visual C++ x64 运行库。游戏位于受保护目录时，安装或卸载可能请求管理员授权；正常启动游戏无需因此提升权限。

The installer does not require Node, Python, Unreal Engine or a separate Oodle installation. The selected UE4SS loader may require its corresponding Microsoft Visual C++ x64 runtime. Installation in protected folders may request administrator access.

## 兼容范围 / Compatibility

已验证 Steam Windows x64 参考版本 `CL-302256_JKS-17280`，以及旧版 `301524-17219` 与 ModCraft 来源 UE4SS 的玩家测试组合。

参考游戏文件 SHA-256：

```text
@GAME_SHA256@
```

参考指纹用于标识构建基准，不代表只凭版本号放行，也不代表所有旧版或 UE4SS 组合通用。EPIC／WeGame 仍未完成客户端验证。安装器支持 Windows Unicode 路径，但游戏内 Lua 对非 ASCII 游戏目录的兼容性仍需单独验证。

Tested coverage: Steam Windows x64 reference build `CL-302256_JKS-17280`, plus the player-tested `301524-17219` / ModCraft UE4SS combination. This does not guarantee compatibility with every older build or loader. Epic and WeGame remain unverified; non-ASCII game-directory behavior also needs separate validation.

## 许可和来源 / License and sources

原项目代码采用 MIT 许可，见 `LICENSE`。游戏图片、预设和第三方组件遵循各自权利及许可，不因随包使用而获得本项目的 MIT 授权。

- 第三方说明：`THIRD_PARTY_NOTICES.md`。
- nlohmann/json 许可：`IntegratedMenu/Tools/JSON-LICENSE.MIT`。
- UE4SS 许可：`NativeEnemyRuntime/Payload/ue4ss/LICENSE`。

Original project code is MIT-licensed. Game content and third-party components retain their own rights and licenses. `PackageManifest.json`, `SHA256SUMS.txt` and `BuildProvenance.json` record package integrity and provenance; they are not third-party digital signatures.

本包不附源码或组装者的普通账号存档、个人战报及配装资料。重新构建请查阅源码仓库中的 `docs/BUILD.md` 与 `docs/LOCAL_INPUTS.md`；第三方说明中的 `src/` 路径同样指源码仓库。
