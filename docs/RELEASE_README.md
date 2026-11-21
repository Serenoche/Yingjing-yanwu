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

1. 把 ZIP 完整解压到较短的目录（例如 `D:\演武`），先退出游戏并等云存档同步完成。
2. 双击根目录的 **影境演武安装器.exe**。
3. 选择游戏和自己的存档账号，点击「检查安装」，再按结果安装、更新或修复。多个游戏库或账号需要明确选择。
4. 完成后从 Steam 正常启动游戏，在主菜单进入「影境演武」。

首次使用前，需先正常进入游戏并创建至少一次存档。使用过内部验证入口时，应先退出游戏并从该内测目录还原，再安装正式版。

安装器会备份并覆盖可识别的旧版演武，重新生成所选账号的安装记录。检查通过后，已有兼容 UE4SS 的玩家可选择「仅覆盖演武 MOD」，保留其他 MOD 和加载器配置。没有前置时，安装器会安装随包提供的加载器。如果前置目录、MOD 配置或游戏版本不兼容，检查结果会说明如何处理。

安装会先备份当前存档，再添加演武专用槽位；普通游戏进度保留。演武的配装、自订列表和挑战记录单独保存，退出演武后恢复正常保存流程。

Fully extract the package, close the game, and run **影境演武安装器.exe**. Select your game and save account, then choose **检查安装** (Check installation). Follow the check result to install, update or repair. Start the game normally through Steam afterward. Create a normal save before your first installation. Restore any active internal test before updating.

The installer backs up and replaces recognized previous arena installations. With a compatible UE4SS installation, choose **仅覆盖演武 MOD** to reuse the loader, its settings, and the other installed MODs. The installer adds its bundled loader when none is installed. Ordinary progress is retained; arena preferences and records are stored separately.

## 卸载与本地数据 / Uninstall and local data

退出游戏并等待云同步完成。打开原安装器，选择安装时的游戏目录和账号，点击「卸载（保留进度）」。也可以打开 `IntegratedMenu/` 中的「卸载主菜单入口.cmd」。卸载按安装登记移出影境演武及其地图、加载器配套组件。共用的 UE4SS、加载器配置和其他 MOD 会保留。前置由演武独占时，卸载会移出随包安装的加载器，并按已核对的备份还原原有文件。正式存档、演武槽位、挑战记录、配装记忆、自订列表和备份都会保留。

安装或卸载中途报错时，安装器会自动撤销本次已登记的文件操作。强制关闭后，重新打开安装器并选中原游戏和账号，点击「恢复上次操作」，恢复完成后再检查。恢复会保留期间更新的存档。遇到外部改动冲突时，安装器会保留冲突文件和备份，其他可以安全撤销的操作仍会回退。遇到问题可点「导出诊断」，游戏 EXE 缺失时也可以导出。

本机演武数据位于：

```text
<游戏>/ProjectPBZ/Saved/PBZTestArena/<所选Steam账号>/
```

Close the game, let cloud sync finish, and select the original game directory and account in the installer. Click **卸载（保留进度）**. Uninstall removes the arena components recorded in the installation receipt. Saves, arena records, preferences, custom lists, backups, other MODs and a shared UE4SS installation are retained. If an operation was interrupted, reopen the installer and click **恢复上次操作** before retrying.

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
