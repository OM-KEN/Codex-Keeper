# 验证工具

这些工具不参与应用构建，也不是回归测试。当前回归入口是根目录的 `run-tests.sh`；现役行为见 [开发说明](../docs/DEVELOPMENT.md)。Swift 原生界面预览使用隔离数据，其中 `MenuTimelinePreview.swift` 引用生产展示模型与视图，检查同步连续展示、执行期间时间线和额度更新。Python 探针保留早期研究用途。

Python 探针会启动 Codex，部分会实际发送消息或操作终端提示。使用前必须阅读脚本，并显式指定隔离测试目录和 Codex 可执行文件；不要对真实任务或数据目录直接试跑。Python PTY 探针另需 `pyte`。

`KEEPER_PROBE_CODEX` 指定 Codex 可执行文件；anchoring 探针另要求 `KEEPER_PROBE_HOME` 和 `KEEPER_PROBE_WORKDIR` 指定隔离目录，主目录仍遵循 `CODEX_HOME`。

`./Probes/check-cli-compatibility.sh --identity` 按生产 `CodexLocator` 的顺序及 Keeper 保存的备用路径定位 CLI，输出路径、版本和 SHA-256，供更新监测比较；首次运行或源码变化时编译探针，后续复用。

`./Probes/check-cli-compatibility.sh --check` 另用生产 provider 检查账户、连续真实额度读取及保活模型，并用生产配置生成函数在临时 home / work 中启动无提示词 TUI；第二次使用已有 Keeper 保活 home，以 `-c` 覆盖生产配置中的顶层设置，覆盖旧服务兼容路径而不替换现役配置。运行前确认 Keeper 没有正在保活或续跑；探针不输入终端内容、不发送模型请求，临时认证副本在退出时删除，CLI 仍可能写入自己的启动日志。输出只含指纹、检查状态和脱敏失败分类。通过仅表示这些接口与启动路径可用，真实保活及续跑仍需对应计划操作的完成与额度证据。
