# 从源码构建

这里提供原创 Lua、C++、PowerShell 和 C# 源码，以及经审查的互操作配置和画像定位元数据。游戏的模型、纹理、音频、解包数据表正文、任何玩家存档及发行包预设不在此源码树中。源码中的 `/Game/...` 等字符串只是对用户本机游戏资源的引用。

## 需要什么

- Python 3.10 或更新版本，仅供构建工具使用。跨平台可运行源码预检查。
- Windows x64、MSVC C++ 工具集和 Windows SDK，用于编译原生组件。推荐使用 **x64 Native Tools Command Prompt**。
- Windows 自带 .NET Framework 的 `csc.exe`，用于编译安装器宿主；PowerShell 5.1 用于实际安装器脚本。
- 2.1.0 原版存点载荷暂存需要解压的 2.0.3 基础发行目录及本地菜单背景。参见 [本地构建输入](LOCAL_INPUTS.md)。

保存工具以 Steam Windows x64 `CL-302256_JKS-17280` 为构建参考。认证本地预设使用以下参考游戏文件的 SHA-256。

```text
4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423
```

原生保存保护按接口档案验证宿主。安装器检查实际游戏版本和接口，符合条件时进入 52 图原版存点流程。各平台实机兼容状态以相应的测试记录为准。

## 预检查

```powershell
python tools/build.py check
python tools/build.py check --external-inputs C:/LocalModInputs --require-release-inputs
```

第一条校验 2.1.0 运行时清单中的 Lua 哈希、核心源码及固定版本的第三方 JSON 头文件，并列出缺少的本地暂存输入。第二条要求指定目录具备这些输入。运行时暂存会进一步校验本地输入内容。 [本地输入目录布局](LOCAL_INPUTS.md)

## 原生保存保护组件

在配置好的 x64 MSVC 命令提示符中运行：

```powershell
python tools/build.py native --component barrier --tests
```

默认产物为 `build/barrier/PBZSaveBarrier.dll`。`--tests` 仅运行合成内存、事务和错误宿主测试，不启动、查找或附加游戏。错误宿主测试会在构建目录旁创建并移除自己的请求/状态文件。

也可以显式传工具链位置；参数指向工具集和 SDK，源码不依赖作者电脑路径：

```powershell
python tools/build.py native --component barrier --tests `
  --msvc-root "C:/BuildTools/VC/Tools/MSVC/<version>" `
  --windows-sdk-root "C:/Program Files (x86)/Windows Kits/10" `
  --sdk-version "<installed-sdk-version>"
```

`--cl` 可选择另一套已配置 `INCLUDE` / `LIB` 的 MSVC 编译器。默认输出目录可用 `--output` 改变。

## 不解压槽位载荷的保存工具

```powershell
python tools/build.py native --component save-tool `
  --presets C:/LocalModInputs/PrivatePresets.pbzs
```

`--presets` 必须是本地准备的 **18 个专用槽位** PBZS 包。构建工具只读取它、检查外层 framing 并计算 SHA-256，将哈希写入构建目录的 `generated/build_config.hpp`。它不会把预设包复制到源码或构建产物目录。运行时工具仍会验证该精确哈希、18 个固定私有槽名、游戏身份及密钥材料指纹，并原生认证所有密文块。

若构建确需支持旧八槽安装所有权迁移，可以额外传 `--legacy-presets <本地旧八槽包>`。未提供该参数的构建会拒绝旧八槽所有权收据，不会猜测旧包。两种模板均不包含在仓库。

这里没有保存密钥字面值。工具从用户提供的本机游戏可执行文件提取并校验材料，运行时派生密钥；实际文件身份写入核对结果，兼容性并非只看完整文件哈希。它不会输出密钥或解压原有槽位，普通槽及 `__Advanced__` 按原密文块保留。`__Advanced__` 字节一致是验证范围，不能据此宣称解析了其语义内容。

该工具只提供 `stage` / `verify`，并且输出必须是它所在 `IntegratedMenu/Tools` 相邻 `IntegratedMenu/Staging` 下的新文件。直接从普通构建目录运行会因布局校验而拒绝；这不是完整安装包，不能用它覆盖正式存档来绕过安装交易流程。

第三方 `nlohmann/json` 固定为 3.11.3，头文件与原 MIT 许可放在 `src/save_tool/vendor`。此项保留原作者及头文件内的其他版权声明，不应改成此项目作者。

## 安装器宿主

```powershell
python tools/build.py installer
python tools/build.py installer --csc "C:/Windows/Microsoft.NET/Framework64/v4.0.30319/csc.exe"
```

编译产生 `build/installer/影境演武安装器.exe` 并复制相邻 PS/CMD 源脚本，**不会启动 GUI，也不会执行安装**。使用发行包无需 Python、Node 或另行提供 Oodle；UE4SS 加载器及原游戏仍可能要求其对应 VC++ 运行库，本项目原生组件用静态 CRT。

安装包以 `NativeEnemyRuntime/Payload` 装配共用加载器，以 `NativeEnemyRuntime/CheckpointPayload` 装配原版存点运行时。安装器只在用户选择安装或卸载时写入游戏，并在游戏运行时拒绝修改。

## 配置与可复现范围

`config` 中的内容是 MOD 自定义组合、场景参数和最小互操作资源标识。生成器将它们转成运行时 Lua；生成文件应由相同输入产生，不要用空表占位隐藏缺失功能。

```powershell
python tools/data/generate_runtime_data.py
python tools/data/generate_runtime_data.py --check
python tools/data/test_generate_runtime_data.py
```

前一条只写 `src/runtime/Scripts` 内四个生成文件，包含测试场杂兵名单。`--check` 只比较。更多约束见 [数据生成器说明](../tools/data/README.md)。

## 2.1.0 运行时暂存

[发行配置](../RELEASE_PROFILE.json)指定 2.1.0 运行时清单。暂存按清单校验原版存点 Lua、预设和本地素材，并写入一个新目录。

在仓库根目录运行以下命令。`--base-release` 指向已解压的基础发行目录。

```powershell
python tools/build.py checkpoint-210 --base-release "local-inputs/YingjingYanwu-2.0.3" --output build/checkpoint-210
```

在 x64 MSVC 开发终端编译原生组件和安装器，再组装到新目录。

```powershell
python tools/build.py native --component checkpoint --checkpoint-presets build/checkpoint-210/Scripts/StockArenaPresets.json --tests
python tools/build.py installer
python tools/assemble_checkpoint_210.py --base "local-inputs/YingjingYanwu-2.0.3" `
  --stage build/checkpoint-210 --native build/checkpoint --installer build/installer --output dist/yingjing-yanwu-210
```

原生组件同时装配参考版和旧 Steam 301524 的存点解析接口。组装器核对组件与预设指纹，在 `CheckpointPayloadHashes.json` 记录 52 个可用槽、8 个保留槽和 52 图准入信息。旧 Steam 通过游戏指纹、地图索引及存点解析检查后可使用同一套 52 图玩法。Epic 参考构建还需通过基础接口和地图索引指纹检查。

`python tools/build.py native --component pressure` 和 `--component path-identity` 可单独编译自订压力模块和目录联接校验模块。完整组装所需输入见 [本地构建输入](LOCAL_INPUTS.md)。

### 演武菜单与原版存点场地

练习和挑战的角色、目标、场景和音乐复用同一套分级菜单。 [2.1.0 运行时清单](../src/runtime/release_210/Manifest.json)

原版存点流程的角色设置按档位保存到演武资料目录的 `PlayerCustomPreferences.tsv`。属性、收集品和装备上限随档位计算。技能增幅在收集品页，异常累积上限可直接拖动调整。

原版存点场地的铃铛提供「装备调整」，沿用原版武器强化界面。武器可免费强化，等级上限取当前角色设定和武器自身上限中较低的一项。按手柄 **X** 或键盘 **P** 进入铸魂页，选中具备铸魂的武器后，长按手柄 **A** 或**空格**切换。重载预设会恢复该档位的初始武器状态。

原版存点流程的测试场复用角色设置和场景筛选。标题入口的「目标」页提供杂兵强度、战斗定位和家族筛选，并可设置敌人轮回与难度。场内铃铛的「重选目标」使用同一份杂兵列表。

可在「目标」页或铃铛的「重选目标」中选择木桩，进场后按 **F8** 生成。木桩保持满血，左上角显示最近伤害、累计伤害、命中次数和 DPS。单按 **Delete** 清零，按 **F10** 清除当前选中的木桩。

测试场、练习和挑战的总览都在左侧列表最后一项提供「进入战斗」。测试场排在「场景」后，练习和挑战排在「音乐」后。

完整暂存从 `local-inputs/ArenaMenuBackgrounds` 读取四张经确认的原图，文件名为 `arena-background-music.png`、`arena-background-scene.png`、`arena-background-target.png` 和 `arena-background-character.png`。也可通过 `--menu-backgrounds` 指定目录。组装逐张校验 SHA-256，并复制到原版存点载荷的 `Scripts/UiAssets`。

2.1.0 的原版存点流程共有 52 个场地。正道大营分组收录万钧、三高塔、乌冷霜和玉璧。断魂山分组包含故屋幻景·夜、巨物盘踞处（力者和锯者）和大梦倾颓处（梦华圣母）。戏梦山庄新增灵堂（囚锋）和演武场（玉鼎）。梅谷湖这批验收的场地包括梅谷乐坊、独眼之岛、水行帮船坞、陆家村浅滩、白蛇屋、白影陨落之处、梅谷村东岛和庞镇杀气塔炉内。目标设置选择普通游龙时带入庞镇场地，选择发狂游龙时带入梅谷湖的水行帮船坞。场景菜单将庞镇杀气塔炉内归入庞镇地区。

溪谷新增场地的存点位置由 `config/XiguCheckpointSlots.json` 同时用于 Lua 和存点预设。修改此表后，运行 `python -m tools.data.xigu_checkpoints` 更新 Lua，再更新清单中的对应校验值。

锈刃凉亭右侧楼梯的常驻雾效由 `XiguRoadFog.lua` 独立检查并恢复。战斗入口雾门在备战时开放，进入战区交战后关闭。

血色森林的场地和存点由 `config/BloodForestScenes.json` 生成。两个巨树场地分别使用白赤练和玉琮的原版场景层。修改该表后，运行 `python -m tools.data.blood_forest_scenes`，再更新清单中 `BloodForestScenes.lua` 的校验值。

陆家村的场地、首领定位、回位范围和存点由 `config/LuJiaCunScenes.json` 生成。修改该表后，运行 `python -m tools.data.lujia_village_scenes`，再更新清单中 `LuJiaCunScenes.lua` 的校验值。

庞镇的场地、封路、首领回位范围和存点由 `config/PangzhenScenes.json` 生成。修改该表后，运行 `python -m tools.data.pangzhen_scenes`，再更新清单中 `PangzhenScenes.lua` 的校验值。

梅谷湖的场地和存点由 `config/MeiGuHuScenes.json` 生成。修改该表后，运行 `python -m tools.data.meiguhu_scenes`，再更新清单中 `MeiGuHuScenes.lua` 的校验值。

戏梦山庄的场地和存点由 `config/XiMengScenes.json` 生成。灵堂使用显式入场落点并在场地就绪后迁移原铃，演武场使用原版 012 铃存点。修改该表后，运行 `python -m tools.data.ximeng_scenes`，再更新清单中 `XiMengScenes.lua` 的校验值。

断魂山的巨物盘踞处和大梦倾颓处使用 `config/DuanhunScenes.json` 生成第 41、42 号存点。大梦倾颓处从断魂崖 004 铃入场，连战阶段切换使用场内标注的重生点。修改该表后，运行 `python -m tools.data.duanhun_scenes`，再更新清单中 `DuanhunScenes.lua` 的校验值。

正道大营使用 `config/ZhengDaoDaYingScenes.json` 生成第 43 至 46 号存点。三高塔的七星剑阵连战第二阶段包含大师兄的绝望剑意和剑阵版红衣女剑客。玉璧连战优先回到场内 5 号点。修改场地配置后，运行 `python -m tools.data.zhengdaodaying_scenes`，再更新清单中 `ZhengDaoDaYingScenes.lua` 的校验值。

枷笼山使用 `config/JialongshanScenes.json` 生成第 47 至 52 号存点，依次为铁杀营地、横刀平台、奎艳艳战区、玉面郎君庭院、宗祠内殿和幻境战场。宗祠内殿和幻境战场分别对应荒行子两个阶段。幻境从原版传入位置独立入场并沿用原版破铃。修改场地配置后，运行 `python -m tools.data.jialongshan_scenes`，再更新清单中 `JialongshanScenes.lua` 的校验值。
