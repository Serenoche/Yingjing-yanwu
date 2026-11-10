# 影境演武 · Yingjing Yanwu

《影之刃零》的非官方演武 MOD：从游戏主菜单进入测试场、练习模式与首领挑战。提供对决、连战、群战，以及轮回、难度、技能和配装设置。

An unofficial Phantom Blade Zero arena MOD with testing, practice and boss challenges. This repository contains original source code and curated interoperability configuration, not a complete playable distribution or game assets.

## 功能

- 主菜单原生入口、键鼠与手柄操作、游戏内铃铛菜单。
- 测试场支持多目标测试；练习模式提供 AI、回血／锁血、无伤／无敌与资源开关；挑战模式记录战斗结果。
- 一决高下（对决）、血战到底（连战）、一夫当关（群战）；连战保留玩家阶段间状态。
- 自订挑战支持最多 5 连战或 5 目标群战，列表独立保存。
- 故屋幻景·夜、湖畔两个演武场景。
- 可配置轮回、敌人难度与技能；提供目标异常状态条、演武配装记忆、历史战报和原生结算界面。
- 独立的演武槽位命名空间、安装交易校验，以及回到正常游戏时的保存状态恢复。

当前版本为 **1.1.0**，开放 88 项内置挑战（67 对决、15 连战、6 群战），另提供自订连战与群战。

## 1.1.0 更新

- 新增自订挑战与目标异常状态条，优化自订挑战结算。
- 改善练习开关、首领信息常显和多目标战斗中的面板稳定性。
- 改善配装记忆和新一轮挑战补满药瓶的体验，连战换阶段保留药瓶消耗。
- 修复荆野骑乘与锁定、白赤练召蛇布局等战斗问题。
- 改善既有 UE4SS 环境的安装兼容，加入已测试旧版 Steam 游戏的针对性支持。

Version 1.1.0 adds custom challenges and target status bars, improves practice controls, boss information and loadout/medicine handling, fixes Jingye and Bai Chilian encounters, and improves compatibility with existing UE4SS installations and the tested older Steam build.

简短中英更新说明见 [1.1.0 发布说明](docs/RELEASE_NOTES_1.1.0.md)。

## 发行范围与实验源码

1.1.0 不启用《影之氪零》实验入口，也不包含锁后镜头采样。开发工作树另有实验代码，发行包及其源码快照采用经确认的稳定首页，内容以所选稳定运行时清单为准。具体选择方式见 [本地组装说明](docs/LOCAL_INPUTS.md)。

EPIC／WeGame 适配仍待对应客户端验证；无尽试炼、已取消的模型替换和暂停的单文件夹方案不在本版范围内。偶发镜头抖动尚未稳定复现，本版未将它列为已修复项。

The 1.1.0 release uses the reviewed stable runtime. Experimental parody entry points and camera diagnostics are not enabled in it. Epic/WeGame support, endless trials, the cancelled model swap and the paused drop-in folder edition are not included.

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

当前验证范围为 Steam Windows x64：参考版本 `CL-302256_JKS-17280`，以及玩家确认可用的旧版 `301524-17219` 与 ModCraft 来源 UE4SS 组合。参考游戏文件 SHA-256 为：

```text
4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423
```

1.1.0 对这两套游戏接口分别适配，保留实际接口、密钥材料和存档容器校验。它不代表所有旧版、平台或 UE4SS 组合都能通用；单改版本号或哈希也不能证明兼容。

安装器优先复用已有可识别的 UE4SS，并保留其他 MOD 与加载器配置；没有前置时再安装随包提供的前置。不同前置布局或其他 MOD 的实际组合仍可能需要单独验证。

Tested coverage is Steam Windows x64: reference build `CL-302256_JKS-17280`, plus the player-tested `301524-17219` / ModCraft UE4SS combination. Existing recognized UE4SS installations are reused while other MODs and loader settings are preserved. This is not a guarantee for every game build or loader combination; Epic and WeGame remain unverified.

安装器由玩家选择本机游戏与账号，将演武数据放入该账号对应的独立目录；普通存档的原有密文槽块需要保持不变。运行时只在演武会话启用专用保存保护，退出后恢复正常保存流程。代码包含账号与宿主身份校验，无法确认时拒绝继续。

离线测试覆盖合成事务、provider 身份、错误宿主、配置生成与发行输入校验；它们不替代游戏内验证。正常启动、模式往返和普通保存已由玩家实测，仍不应将有限验证推广到所有环境。报告问题时请提供游戏版本、UE4SS 来源和复现步骤，移除账号、路径和个人记录。

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
