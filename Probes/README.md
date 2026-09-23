# 历史验证工具

这些脚本保留早期研究用途，不参与应用构建，也不是回归测试。当前验证入口是根目录的 `run-tests.sh`；现役行为见 [开发说明](../docs/DEVELOPMENT.md)。

Python 探针会启动 Codex，部分会实际发送消息或操作终端提示。使用前必须阅读脚本，并显式指定隔离测试目录和 Codex 可执行文件；不要对真实任务或数据目录直接试跑。Python PTY 探针另需 `pyte`。

`KEEPER_PROBE_CODEX` 指定 Codex 可执行文件；anchoring 探针另要求 `KEEPER_PROBE_HOME` 和 `KEEPER_PROBE_WORKDIR` 指定隔离目录，主目录仍遵循 `CODEX_HOME`。
