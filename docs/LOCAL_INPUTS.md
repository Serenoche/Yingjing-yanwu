# 2.1.0 本地构建输入

## 暂存原版存点运行时

将有权使用的 2.0.3 发行包完整解压到 `local-inputs/YingjingYanwu-2.0.3`。暂存器读取 `PackageManifest.json` 确认基础版本，从原版存点载荷读取专用预设。组装安装包时从同一发行包校验并复制共用加载器、素材及其配套文件。预设是演武构建输入，与玩家的普通存档分别管理。

准备四张菜单背景，存入 `local-inputs/ArenaMenuBackgrounds`，或通过 `--menu-backgrounds` 指定目录。

```text
local-inputs/
  YingjingYanwu-2.0.3/
    PackageManifest.json
    NativeEnemyRuntime/
      CheckpointPayload/
      Payload/
      PayloadHashes.json
  ArenaMenuBackgrounds/
    arena-background-character.png
    arena-background-target.png
    arena-background-scene.png
    arena-background-music.png
```

```powershell
python tools/build.py checkpoint-210 --base-release "local-inputs/YingjingYanwu-2.0.3" --output build/checkpoint-210
```

暂存器按运行时清单校验 Lua 与四张背景，生成 52 场的原版存点预设和运行时脚本。仅验证脚本与场地配置时，可改用 `--base-presets <StockArenaPresets.json>`，并按需提供背景目录。输出目录需要使用新路径。完整命令和编译步骤见 [2.1.0 构建说明](BUILD.md#210-运行时暂存)。

## 组装安装包

- 使用暂存的预设重新编译原生保存保护，将原生组件清单和安装器宿主一起传给 `tools/assemble_checkpoint_210.py`。
- 安装包还需要经审核的 UE4SS、本地图片及地图、专用预设和配套原生组件。沿用基础发行包中的文件前，应核对清单、适配范围和分发授权。两张菜单题字的本地文件为 `CheckpointMenuTitles/MenuTitleArena.png` 和 `CheckpointMenuTitles/MenuTitleModFeatures.png`。
- 浊梦结算音乐调用玩家本机的 Wwise 事件。背景、题字及其他外部素材的使用范围见 [发行素材约定](SOURCE_SCOPE.md#发行素材)。

`local-inputs/`、`build/` 和 `dist/` 均为被 Git 忽略的本地目录。游戏程序应留在游戏安装目录。普通存档、账号信息、诊断、预设、素材和构建产物均属本地数据。
