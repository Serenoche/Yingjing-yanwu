# 影境演武 · Yingjing Yanwu

《影之刃零》的非官方演武 MOD：从游戏主菜单进入测试场、练习模式与首领挑战。提供对决、连战、群战，以及轮回、难度、技能和配装设置。

An unofficial Phantom Blade Zero arena MOD. This repository contains original source code and curated interoperability configuration, not a complete playable distribution or game assets.

## 功能

- 主菜单原生入口、键鼠与手柄操作、游戏内铃铛菜单。
- 测试场支持多目标测试；练习模式提供 AI、回血、无敌与资源开关；挑战模式记录战斗结果。
- 一决高下（对决）、血战到底（连战）、一夫当关（群战）；连战保留玩家阶段间状态。
- 故屋幻景·夜、湖畔两个演武场景。
- 可配置轮回、敌人难度与技能；演武专用配装记忆、历史战报和原生结算界面。
- 独立的演武槽位命名空间、安装交易校验，以及回到正常游戏时的保存状态恢复。

当前版本为 **1.0.3（安装修订 1）**，开放 88 项挑战（67 对决、15 连战、6 群战）。舞狮尊主相关战斗已恢复。

1.0.3 包含已实机验证的连战接续修复；练习模式的回血开关同时启用原生锁血，练习结束采用居中三行选项，挑战结算增加透视盖印、回弹与扩散动效。

安装修订 `1.0.3-installfix1` 仅调整安装器：兼容卸载 UE4SS 后遗留的空目录，保留其备份；非空的未知安装仍会保留并给出明确提示。运行时与 1.0.3 相同，安装与进入演武已由玩家确认。

## 获取与构建

这是**源码仓库**。仓库不包含游戏图片、模型、音频、玩家存档、演武预设包、游戏程序或 UE4SS 二进制。直接下载源码不能当作 MOD 安装包使用。

仅检查源码与配置需要 Python 3.10+，无第三方 Python 依赖：

```sh
python tools/build.py check
python tools/data/generate_runtime_data.py --check
python tools/data/test_generate_runtime_data.py
python -m unittest discover -s tests -v
```

构建原生组件和安装器需要 Windows x64、MSVC、Windows SDK 与 .NET Framework。完整发行包还需要自行准备有权使用的本地媒体、匹配的 UE4SS 发布包，以及专用演武预设。

- [构建说明](docs/BUILD.md)
- [完整发行包所需的本地输入](docs/LOCAL_INPUTS.md)
- [公开源码的范围](docs/SOURCE_SCOPE.md)
- [配置生成器](tools/data/README.md)

安装器源码保留了完整交易校验。请先完成本地组装，不要把 `src/installer` 当作可直接安装的成品目录。

## 兼容范围与保存边界

当前支持 Steam Windows x64 的特定游戏版本，SHA-256 为：

```text
4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423
```

原生地址和保存格式依赖此版本。更新游戏后需要重新验证，单改版本哈希不能获得兼容性。

安装器由玩家选择本机游戏与账号，将演武数据放入该账号对应的独立目录；普通存档的原有密文槽块需要保持不变。运行时只在演武会话启用专用保存保护，退出后恢复正常保存流程。代码包含账号与宿主身份校验，无法确认时拒绝继续。

离线测试覆盖合成事务、provider 身份、错误宿主、配置生成与发行输入校验；它们不替代游戏内验证。正常启动、模式往返和普通保存曾由玩家实测，其他游戏版本、平台及完整路径字符兼容性尚未验证。报告问题时请提供游戏版本和复现步骤，移除账号、路径和个人记录。

## 源码结构

```text
config/              最小互操作配置、挑战组合与场景设置
src/runtime/         UE4SS Lua 运行时与原生 UI 逻辑
src/save_barrier/    C++ 保存事务保护、provider 校验及合成测试
src/save_tool/       C++ 容器认证与暂存工具
src/installer/       C# 宿主与 PowerShell 安装交易
tools/               组件构建、数据生成与本地发行包组装
tests/               公开源码边界检查
```

## 许可

原创代码及原创配置采用 [MIT 许可](LICENSE)。第三方 JSON 头文件保留其原许可证；游戏名称、资源标识及所引用的资源不因出现在源码中而获得 MIT 授权。详见 [第三方说明](THIRD_PARTY_NOTICES.md)。本项目与游戏开发商、发行商无隶属关系。

欢迎提交问题和改进，参见 [贡献说明](CONTRIBUTING.md)。
