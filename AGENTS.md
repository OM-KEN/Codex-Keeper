# Codex Keeper

- 未经用户明确同意，不执行 Git push；提交、发布也不从普通修改请求中推定授权。
- 项目根目录就是本目录。
- 这是 Swift / SwiftUI / AppKit 原生 macOS 菜单栏工具，负责 Codex 保活和额度恢复后续跑。
- 当前行为与限制读 `docs/DEVELOPMENT.md`；原始方案归档于 `docs/archive/design-v1.md`。
- 构建：`./build.sh`；回归：`./run-tests.sh`；启动：`open .build/CodexKeeper.app`。
- 没有 xcodeproj；新增 Swift 源文件须更新 build.sh 的 SOURCES。
- App、Core、Codex、UI 分别放生命周期、业务、Codex 接入和界面；Tests 与 Probes 用于验证。
- 真实保活与续跑已接入；修改调度或通信时保留账户、额度、任务状态、重复发送和工作区检查。
- 修改额度读取时保留连接复用和用途隔离；专用查询的配置覆盖不能影响续跑，机制与流量验证边界见 `docs/DEVELOPMENT.md`。
- 确认执行结果必须检查真实日志；不能将 started、进程退出成功或普通 OK 回复当作保活成功。
- 运行数据位于 `~/Library/Application Support/CodexKeeper/`，不要清空尝试记录或挪动用户任务历史。
- 替换或重启应用前先检查是否有正在执行的 Keeper 操作，避免丢失确认记录。
- `.build/` 是本地构建与隔离验证输出；旧副本不是现役源码或指令。
- 精准修改；UI 保持主次清晰，不把后台边缘逻辑堆成用户选项。
