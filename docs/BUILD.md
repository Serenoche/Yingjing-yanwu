# 从源码构建

这里提供原创 Lua、C++、PowerShell 和 C# 源码，以及经审查的互操作配置和画像定位元数据。游戏的模型、纹理、音频、解包数据表正文、任何玩家存档及发行包预设不在此源码树中。源码中的 `/Game/...` 等字符串只是对用户本机游戏资源的引用。

## 需要什么

- Python 3.10 或更新版本，仅供构建工具使用。跨平台可运行源码预检查。
- Windows x64、MSVC C++ 工具集和 Windows SDK，用于两个原生组件。推荐使用 **x64 Native Tools Command Prompt**。
- Windows 自带 .NET Framework 的 `csc.exe`，用于编译安装器宿主；PowerShell 5.1 用于实际安装器脚本。
- 可运行的 MOD 另外需要受支持的原版游戏、独立取得的匹配 UE4SS 发布包、合法取得的本地图片，以及本地生成的专用预设包。下文的编译操作不会提供或生成这些游戏资源。

1.1.0 的验证范围是 Steam Windows x64 参考版本 `CL-302256_JKS-17280`，以及玩家确认的旧版 `301524-17219`／ModCraft UE4SS 组合。组装发行包仍使用以下参考游戏文件来认证本地预设：

```text
4415933ce33476f14c837abb61a1b60af8b78cd81783896501913a7aac69e423
```

原生保存保护包含参考版与该旧版的针对性接口配置；运行时核实实际接口，保存工具继续核实密钥材料与容器认证。参考指纹不再等同于唯一可运行版本，也不能通过随意修改哈希来宣称其他版本兼容。EPIC／WeGame 仍待客户端验证。

Tested coverage is the reference Steam build and the reported older Steam/ModCraft combination above. Separate native profiles retain interface checks; this is not universal game-build or UE4SS compatibility. The reference executable remains a local packaging input.

## 预检查

```powershell
python tools/build.py check
python tools/build.py check --external-inputs C:/LocalModInputs --require-release-inputs
```

第一条检查核心源码及已固定版本的第三方 JSON 头文件，并列出缺少的本地发行输入；它不表示已经能生成完整发行包。第二条在缺少任何发行输入时返回非零退出码。当前检查只核实存在性，不能替代资源许可、配置 schema 和实际文件哈希的发行审核。

本地输入目录约定：

```text
LocalModInputs/
  UIAssets/Manifest.json
  UIAssets/<本地 PNG 或 JPG>
  PrivatePresets.pbzs
  UE4SS-release.zip
```

`NativeUiAssetsData.lua` 只有文件名、原生纹理路径、尺寸和 UV 元数据，不包含图片。保留它不能替代其引用的本地图片。

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

宿主本身不包含全部发行资源。安装交易脚本要求相邻 `IntegratedMenu/Tools`、`PrivatePresets.pbzs` 和同级 `NativeEnemyRuntime/Payload` 及精确 `PayloadHashes.json`；未完成审核的本地组装不能当作可安装发行版。它只在用户明确选择安装或卸载后写入游戏，并在运行游戏时拒绝修改。不要从源码目录直接调用 `Install-PbzIntegratedMenu.ps1` 当作构建步骤。

## 配置与可复现范围

`config` 中的内容是 MOD 自定义组合、场景参数和最小互操作资源标识。生成器将它们转成运行时 Lua；生成文件应由相同输入产生，不要用空表占位隐藏缺失功能。

```powershell
python tools/data/generate_runtime_data.py
python tools/data/generate_runtime_data.py --check
python tools/data/test_generate_runtime_data.py
```

前一条只写 `src/runtime/Scripts` 内三个指定生成文件；`--check` 只比较，不写文件。更多约束见 [数据生成器说明](../tools/data/README.md)。

## 1.1.0 稳定运行时选择

完整组装使用 `tools/assemble_release.py --runtime-dir <稳定运行时目录>`。该目录必须含 `Scripts/` 中完整的 63 项 Lua 白名单，以及空白的 `enabled.txt`；原生 DLL 取自所选构建目录，不能沿用旧 DLL 代替本次双版本接口构建。

`--runtime-dir` 默认是 `src/runtime`。开发工作树保留实验代码，1.1.0 发行及其源码快照选择经确认的三模式 `TitleHome.lua`，不启用《影之氪零》入口。`KryptonDemo.lua` 仍在文件白名单中，但稳定首页不引用它。内部镜头采样不属于该稳定快照；偶发镜头抖动未被列为已修复项。

`--data-dir` 只用于核对三个生成表，**不会覆盖运行时模块**；其内容也必须与所选 `runtime-dir/Scripts` 中的生成表一致。不要把它当作稳定 UI 或修复脚本的覆盖目录。组装后，逐文件核对 `BuildProvenance.json` 的运行时指纹，尤其是稳定首页与本次构建的保存保护 DLL。

Use `--runtime-dir` to select one complete reviewed runtime, including `Scripts/` and `enabled.txt`. `--data-dir` validates generated tables only and never replaces runtime modules. The stable 1.1.0 profile excludes experimental entry points and camera diagnostics while retaining the confirmed target-registration repair.

完整命令及本地输入布局见 [LOCAL_INPUTS.md](LOCAL_INPUTS.md)。无尽试炼、取消的模型替换和暂停的单文件夹方案不在本版构建范围内。

仅编译原生组件及安装器无需游戏资源。完整 UI、预设生成和完整发行包组装需要上面的本地输入，因此这里不承诺干净克隆后能独立生成完整 MOD 发行包。游戏资源不因被代码引用而适用本项目的 MIT 授权。

源码构建及合成测试通过，也不能替代用户对正常启动、Steam 账号匹配、进入/退出演武、普通保存恢复的实际验证。
