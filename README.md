# 影境演武 · Yingjing Yanwu

《影之刃零》的非官方演武 MOD。从游戏主菜单进入测试场、练习、挑战和 101 层浊梦。提供对决、连战、群战，以及轮回、难度、技能和配装设置。

An unofficial Phantom Blade Zero arena mod with testing, practice, boss challenges, and the 101-floor Dream Palace. The repository contains the mod source and interoperability configuration.

## 2.1.0 更新

- **52 处原版存点场地。** 场地按模式和目标开放。独立场地具备专用铃铛、雾门和首领回位规则。多场地连战按阶段切换，保留本轮战斗状态。
- **新版演武菜单。** 测试场、练习和挑战统一使用分级菜单，场地随模式和目标筛选。战斗音乐支持试听、暂停和继续。演武铃显示对应场地名，练习和挑战可从铃铛打开新版菜单更换目标。
- **角色档位与装备调整。** 原版存点流程可按「牢」及轮回档位配置角色属性、收集品和装备。场地铃铛支持免费强化武器和切换铸魂。
- **测试场木桩。** 支持显示最近伤害、累计伤害、命中次数和 DPS。按 **F8** 生成、**Delete** 清零、**F10** 清除当前木桩。
- **连战与首领机制。** 新增「七星鸳鸯阵」与「少主护卫：铁鬼与玉妖」，恢复原版编队、铁鬼与玉妖联动和舞狮过热。通用与 SOLO 场地补上防坠保护，浊梦重排回位与出生点。

[完整更新说明](docs/RELEASE_NOTES_2.1.0.md)

## 功能

- 主菜单原生入口、键鼠与手柄操作、游戏内铃铛菜单。
- 测试场支持多目标测试，可按强度、战斗定位和家族筛选 109 种杂兵。进场按 F8 生成，按 F6 切换回血和锁血。铃铛可重选目标和调整能力，ESC 菜单提供角色和系统页。
- 练习模式提供 AI、回血／锁血、无伤／无敌与资源开关，按 F4 可隐藏或重新显示右上角面板。挑战模式记录战斗结果。
- 一决高下（对决）、血战到底（连战）、一夫当关（群战）；连战保留玩家阶段间状态。
- 自订挑战支持最多 5 连战或 5 目标群战，列表独立保存。
- 可配置轮回、敌人难度与技能；提供目标异常状态条、演武配装记忆、历史战报和原生结算界面。
- 独立的演武槽位命名空间、安装交易校验，以及回到正常游戏时的保存状态恢复。

## 获取与构建

这是 **2.1.0 源码仓库**。完整 MOD 安装包需要额外准备游戏资源、演武预设和匹配的 UE4SS。源码、组件编译及载荷暂存从这里开始。 [源码范围](docs/SOURCE_SCOPE.md)

浊梦结算配乐调用玩家本机的《赤黑诀别》。新增素材优先调用游戏原版资源或使用自制素材，见 [发行素材约定](docs/SOURCE_SCOPE.md#发行素材)。

仅检查源码与配置需要 Python 3.10+，无第三方 Python 依赖：

```sh
python tools/build.py check
python tools/data/generate_runtime_data.py --check
python tools/data/test_generate_runtime_data.py
python -m unittest discover -s tests -v
```

构建原生组件和安装器需要 Windows x64、MSVC、Windows SDK 与 .NET Framework。2.1.0 的载荷暂存使用解压后的 2.0.3 发行包作为本地输入，并按 2.1.0 清单校验脚本。 [发行清单](RELEASE_PROFILE.json)

- [构建说明](docs/BUILD.md)
- [完整发行包所需的本地输入](docs/LOCAL_INPUTS.md)
- [公开源码的范围](docs/SOURCE_SCOPE.md)
- [配置生成器](tools/data/README.md)

安装器源码保留了完整交易校验。请先完成本地组装，不要把 `src/installer` 当作可直接安装的成品目录。

## 兼容范围与保存边界

自订压力适用于可加载压力模块的 Steam Windows x64 参考版 `CL-302256_JKS-17280`。参考游戏文件 SHA-256 如下。

```text
4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423
```

2.1.0 使用同一套 52 图原版存点运行时，支持 Steam 参考版、通过检查的旧 Steam `301524-17219` 和 Epic 参考构建。旧版安装可按现有记录覆盖升级并保留进度。平台安装、升级和卸载覆盖离线验证。 [2.1.0 构建说明](docs/BUILD.md#210-运行时暂存)

安装器优先复用已有可识别的 UE4SS，并保留其他 MOD 与加载器配置；没有前置时再安装随包提供的前置。不同前置布局或其他 MOD 的实际组合仍可能需要单独验证。

Custom pressure is available on the pinned Steam build with a compatible UE4SS. The installer reuses recognized loaders and preserves other mods and settings. Selected legacy Steam and Epic builds use version-specific admission checks.

安装器由玩家选择本机游戏与账号，将演武数据放入该账号对应的独立目录；普通存档的原有密文槽块需要保持不变。运行时只在演武会话启用专用保存保护，退出后恢复正常保存流程。代码包含账号与宿主身份校验，无法确认时拒绝继续。

报告问题时请提供游戏版本、UE4SS 来源、模式、目标、场地和复现步骤，或从安装器导出脱敏诊断。 [贡献说明](CONTRIBUTING.md)

## 源码结构

```text
config/              最小互操作配置、挑战组合与场景设置
src/runtime/         UE4SS Lua 运行时与原生 UI 逻辑
src/runtime/release_210/  2.1.0 原版存点运行时清单与代码
src/save_barrier/    C++ 保存事务保护、provider 校验及合成测试
src/save_tool/       C++ 容器认证与暂存工具
src/installer/       C# 宿主与 PowerShell 安装交易
tools/               组件构建、数据生成与本地发行包组装
tests/               公开源码边界检查
```

## 许可

原创代码及原创配置采用 [MIT 许可](LICENSE)。第三方 JSON 头文件保留其原许可证；游戏名称、资源标识及所引用的资源不因出现在源码中而获得 MIT 授权。详见 [第三方说明](THIRD_PARTY_NOTICES.md)。本项目与游戏开发商、发行商无隶属关系。

欢迎提交问题和改进，参见 [贡献说明](CONTRIBUTING.md)。
