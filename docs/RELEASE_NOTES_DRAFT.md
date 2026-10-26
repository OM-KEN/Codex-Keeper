# v1.1.0 发布说明（重要更新）

比较基线为正式标签 v1.0.2。中文沿用 OM 确认的文案，英文逐条对应。

<!-- keeper-important-update: 1.1.0 -->

## Fixes

- Fixed the task splitting caused by recent Codex updates that left Keeper unable to tell which task was the real one...
- Keeper's lazy keepalive problem is fixed for good (or is it?). Anyway, even if quota checks keep failing to connect, Keeper will still make one scheduled keepalive attempt.
- Keeper no longer keeps checking quota on its own. Most of the time, it gets it straight from Codex! (Codex now shows quota progress bars in its left sidebar too, but Keeper's are clearer!)
- Made sure Keeper really stops when you turn it off.
- A few other little-known fixes, including a major cleanup of keepalive logic. Auto-resume, you're next! Nobody gets away.

## 修复

- 修了 Codex 最近更新导致的任务分裂问题导致的 Keeper 续跑分不清到底哪个是真实任务的问题……
- 保活偷懒的问题彻底解决了（吗？），总之，现在额度查询一直连不上，也会按计划尝试保活一次。
- 额度不再总是自己去查了，现在大部分时候直接拿 Codex 的额度！（Codex 自己也在界面左侧显示额度进度条了，但是没 Keeper 的清晰！）
- 确保了 Keeper 停用的时候是真的停了。
- 其他一些鲜为人知的小修复，比如大幅优化了保活的逻辑，接下来就是你续跑了！谁也逃不掉。
