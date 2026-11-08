# 参与改进

问题报告请写清游戏版本、MOD 版本、模式、目标、场景、操作顺序和实际结果。
请勿上传个人存档、完整日志、账号标识、安装收据或游戏解包资源；必要的日志片段请先脱敏。

提交代码前运行 README 中的源码与配置检查。C++ 保存保护的修改还需运行
`python tools/build.py native --component barrier --tests`。游戏内行为无法由这些
离线测试证明，请说明哪些行为经过实测、哪些尚待验证。

挑战组合的定义入口在 `tools/data/create_encounter_catalog.py`；修改后更新 JSON
并重新生成 Lua。不要只改生成文件或用空表替代缺失数据。

保留第三方许可声明。不要提交 `local-inputs`、`build`、`dist`、游戏资源、
保存预设或任何真实账号数据。原创贡献按本项目 MIT 许可提交。
