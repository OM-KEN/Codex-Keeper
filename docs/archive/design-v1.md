# Codex Keeper

> 历史原始方案，保留设计背景；当前实现、运行方式与限制以 [开发说明](../DEVELOPMENT.md) 为准。

## 1. 产品定位

Codex Keeper 是一个原生 macOS 菜单栏工具，只做两件事：

**第一，维持用户希望的 Codex 5 小时额度节奏。**

例如用户设置每天 `08:00` 开始，目标节奏自动成为：

```text
08:00
13:00
18:00
23:00
```

每个节点之间相隔 5 小时。

**第二，Codex 任务因为额度耗尽而停止时，在额度恢复后自动或按用户选择继续原任务。**

整个 App 不承担：

- Codex 聊天
- 项目管理
- Token Dashboard
- AI Agent 管理
- 自动批准权限
- API Key 管理

它本质上是一个：

> Codex 额度节奏调度器 + 任务续跑器。

---

# 2. 最重要的设计原则

整个系统只认两种信息：

### 用户计划

例如：

```text
每天开始：08:00
```

由此得到目标节点：

```text
08:00
13:00
18:00
23:00
```

这些时间不是强制命令。

它们只是：

> **重新进入用户目标节奏的机会点。**

### Codex 实际状态

真正决定是否执行的是：

- 当前有没有有效 5h window
- 当前 5h 是否已经耗尽
- Weekly 是否耗尽
- 有没有实际被 quota 阻塞的 Session
- reset 是否真的已经发生
- 当前 Session 是否仍然需要 Resume

因此：

> **用户时间表负责方向，Codex 实际额度负责决策。**

官方目前的规则也是：当前一个 5 小时窗口结束后，用户下一次在 Work/Codex 中发送消息时才开启新的窗口。

---

# 3. 正常运行逻辑

用户设置：

```text
每日开始时间
08:00
```

目标节奏自动计算：

```text
08 → 13 → 18 → 23
```

理想情况下：

```text
08:00  Ping
↓
08 → 13

13:00  Ping
↓
13 → 18

18:00  Ping
↓
18 → 23

23:00  Ping
↓
23 → 04

04 → 08
留作自然空档

第二天
08:00 重新锚定
```

用户不需要自己输入四个时间。

只设置：

> 每日开始时间。

---

# 4. 计划节点不是一个“瞬间”

不能简单设计成：

```text
13:00:00
检查一次
```

因为实际 Codex reset 可能变成：

```text
13:00:08
```

所以内部应该存在一个很小的：

**计划节点宽限区**

例如：

```text
目标：13:00

当前实际 reset：
13:00:08

→ 等到 13:00:18 左右
→ 再执行
```

如果 reset 只偏离几十秒，仍然认为属于：

> 13:00 这一轮。

而不是因为 13:00 时窗口还剩 8 秒，就直接把整轮跳过。

这个容差不需要用户设置。

UI 仍显示：

```text
13:00
```

---

# 5. 每个计划节点的核心决策

例如现在来到 18:00。

首先进行一次完整 Reconcile。

然后：

```text
当前已有有效 5h Window？
│
├─ 有
│   ↓
│  Skip
│
└─ 没有
    │
    ↓
    有待续的 quota-blocked Session？
    │
    ├─ 有
    │   ↓
    │  Resume
    │
    └─ 没有
        ↓
       Ping
```

所以：

> 有任务时，“继续”本身就是新窗口的第一条消息。

不需要：

```text
先 Ping
再 Resume
```

否则只是白白多消耗一次。

---

# 6. 保活 Ping

保活 Prompt 完全不开放给用户配置。

内部固定为极简内容，例如：

```text
ok
```

原因很简单：

它不是用户功能，只是系统机制。

保活请求应该满足：

- 使用当前账户真正可用的最低成本模型
- 最低 reasoning
- 空工作目录
- 不加载项目内容
- 尽量关闭无关 Hooks
- 不操作用户文件
- 有严格执行超时
- 失败不无限重试

CCLimitPing 后来从 `codex exec` 改成了真正的 Interactive TTY Codex，因为其项目验证发现 headless exec 并不能可靠锚定 ChatGPT 订阅对应的 5h window。

因此 Keeper V1 应优先采用：

```text
隐藏 PTY
↓
官方 Codex CLI
↓
发送极小请求
↓
确认 quota 状态发生变化
↓
退出
```

而不是控制 Codex App UI。

---

# 7. Ping 成功不能只看“Codex 返回 OK”

Ping 的目标不是得到：

```text
OK
```

而是：

> **确认新的 5h window 实际已经建立。**

所以：

```text
发送 Ping
↓
收到结果
↓
重新读取 Usage
↓
确认新的 5h window / resetAt
↓
才标记为 Success
```

如果：

```text
Codex 回了 OK
但 quota 状态没有发生预期变化
```

应视为：

```text
Ping 未确认
```

而不是成功。

---

# 8. Ping 会话不能污染用户历史

目标体验：

> 用户永远不会在正常 Codex 历史里看到每天四条“ok”。

但由于可靠 Ping 可能需要 Interactive Codex，而 Interactive 路径不一定支持真正的 ephemeral session，这一点不能靠假设。

因此单独设计：

**PingSessionIsolation**

优先验证：

```text
独立 CODEX_HOME
+
复用官方认证
+
独立 session store
```

让 Keeper Ping 产生的 session 只存在于 Keeper 自己目录中。

如果当前 Codex 架构无法安全做到这一点，则必须寻找官方支持的 session 清理/隔离方式。

不应直接粗暴删除用户：

```text
~/.codex/sessions
```

中的文件。

这是 V1 上线前的 P0 技术验证项。

---

# 9. 自动续跑

当 Session 因 quota exhaustion 停止：

```text
Copied
10:42
5h quota exhausted
```

Keeper 记录：

```text
BlockedSession

Session ID
Project
cwd
BlockedAt
ResetAt
BlockingLimits
WorkspaceState
```

然后进入：

```text
WaitingForQuota
```

额度恢复之后，不建立新会话。

而是：

```text
codex resume <原 session>
```

并发送：

```text
继续
```

Codex 当前不同 Surface 使用的 rollout 会写入 `~/.codex/sessions/`，其中 rate-limit snapshot 包含使用量和精确 reset epoch；现有 unsnooze 已经利用同一存储检测 Codex CLI、IDE 和桌面端会话，并通过 `codex resume <id>` 恢复原 session。

---

# 10. 自动续跑唯一允许用户自定义的 Prompt

设置：

```text
续跑内容

继续
```

默认：

```text
继续
```

用户可以改成：

```text
继续完成之前的任务
```

或者：

```text
继续，完成后检查之前的修改
```

保活 Prompt 不开放。

Resume Prompt 开放。

---

# 11. 多个 Blocked Session

如果：

```text
Copied      blocked
Lithe       blocked
Website     blocked
```

Keeper 不应该一次恢复三个。

默认：

> 最近一个因额度耗尽而停止的 Session。

菜单栏同时允许用户临时切换：

```text
下次将继续

● Copied
○ Lithe
○ Website
```

V1 每次恢复事件只自动启动 **一个 Session**。

即使恢复完第一个以后额度仍然很多，也不要偷偷启动第二个。

这是为了避免 Keeper 无意中同时制造多个 Agent 消耗额度。

---

# 12. Weekly Limit

Weekly 不是调度时钟。

它只是一个：

> **执行许可闸门。**

例如：

```text
Weekly reset：
周三 15:37
```

但用户目标计划：

```text
08 / 13 / 18 / 23
```

15:37 Weekly 自然重置：

```text
没有 blocked task
↓
什么都不做

18:00
继续正常计划
```

所以：

> Weekly reset 本身不触发 Ping。

---

# 13. 同时撞 5h + Weekly

例如：

```text
5h reset
16:10

Weekly reset
15:37
```

Session 因两个限制都无法继续。

15:37：

```text
Weekly 恢复
5h 仍然 exhausted
↓
继续等待
```

16:10：

```text
5h 恢复
Weekly available
↓
现在才具备 Resume 条件
```

最终判断不是：

> “某一个 reset 到了。”

而是：

> **当前账户是否重新满足执行这个任务所需的全部额度条件。**

---

# 14. 外部 Reset

统一把以下行为视为：

**External Reset / Unexpected Quota Change**

包括：

- Automatic Reset
- Global Reset
- Banked Reset
- Purchased Reset
- 其他未来 OpenAI Reset

不需要识别它究竟叫什么。

只需要观察：

```text
额度状态发生了非预期变化
```

官方明确说明 full banked reset 会同时刷新 5h 与 weekly，并改变 weekly reset 日期。

Automatic/global reset 则会根据活动实际指定的 eligible limits 执行，因此 Keeper 不能假设所有 reset 都完全相同。

---

# 15. 外部 Reset 没有任务时

例如：

```text
16:37
突然发生 Reset

目标节点：
18:00
```

没有 blocked task：

```text
16:37
什么都不做
```

不要立刻 Ping。

否则会制造：

```text
16:37 → 21:37
```

的非计划窗口。

等到 18:00：

如果：

```text
没有 active window
→ Ping
```

如果：

```text
已有 active window
→ Skip
```

系统自然寻找下一个重新入轨点。

---

# 16. 外部 Reset 有任务时

这是用户需要控制的地方。

设置项：

```text
额度提前恢复时

● 每次询问
○ 立即继续
○ 保持计划
```

这个设置只针对：

> **非计划时间突然恢复额度，同时存在待续任务。**

---

# 17. “立即继续”

例如：

```text
16:37
额度突然恢复

Copied 正在等待
```

选择：

```text
立即继续
```

则：

```text
16:37 Resume
↓
启动实际 window
16:37 → 21:37
```

18:00：

```text
发现 active window
→ Skip
```

23:00：

```text
已经没有 active window
→ 恢复正常节奏
```

---

# 18. “保持计划”

16:37：

```text
额度恢复
```

不执行。

继续等待：

```text
18:00
```

到达计划节点以后：

```text
有 blocked Session
↓
Resume
```

而不是 Ping。

---

# 19. “每次询问”

默认推荐这一项。

额度提前恢复：

```text
Codex 额度已恢复

Copied 有一个未完成任务
下一个计划时间：18:00

[立即继续]
[保持计划]
```

如果用户没有点击：

> 默认保持计划。

菜单栏动态显示：

```text
Copied 等待继续

额度已恢复 1小时07分
距计划时间还有 12分钟
```

这样用户晚看到通知时可以自己判断。

---

# 20. 日锚点保护

这是防止复杂任务永久打乱时间表的核心。

假设每日开始：

```text
08:00
```

那么：

```text
03:00 → 08:00
```

是天然的：

**日锚点保护区**

因为任何 03:00 之后启动的新 5h window 都可能跨过第二天 08:00。

判断不能写死凌晨 3 点。

应该动态计算：

```text
下一日锚点 - 5h
```

例如：

```text
每日 09:00
→ 04:00 开始保护

每日 07:30
→ 02:30 开始保护
```

---

# 21. 极端复杂任务连续消耗多个窗口

例如官方 reset 后：

```text
16:37 Resume
→ 很快撞墙

21:37 Resume
→ 很快撞墙

02:37 Resume
→ 很快撞墙

07:37 又恢复
```

如果 07:37 再继续：

```text
07:37 → 12:37
```

就跨过 08:00 日锚点。

此时应用“额度提前恢复”策略。

### 立即继续

允许：

```text
07:37 Resume
```

用户主动选择工作优先。

### 保持计划

等待：

```text
08:00 Resume
```

重新恢复：

```text
08 → 13 → 18 → 23
```

### 每次询问

通知：

```text
Codex 额度已恢复

Copied 可以继续
但现在继续会跨过明日 08:00 的计划时间

距计划时间还有 23 分钟

[立即继续]
[等到 08:00]
```

未响应：

> 默认等待日锚点。

---

# 22. 用户计划的真正含义

因此：

```text
08
13
18
23
```

不是：

> 这四个时间必须执行 Ping。

而是：

> 这四个时间是系统尝试重新入轨的目标节点。

这是整个 Keeper 最关键的抽象。

---

# 23. Reset 时间不能被完全信任

不能：

```text
看到 resetAt = 13:00
↓
13:00 直接 Resume
```

应该：

```text
13:00 到
↓
重新读取真实额度
↓
确认额度已经恢复
↓
Resume / Ping
```

如果：

```text
resetAt 已经过期
used 仍然显示 exhausted
```

进入：

```text
等待确认
```

而不是不停尝试请求。

官方也明确建议用户以当前 Usage 页面和 `/status` 的实际额度与 reset time 为准。

---

# 24. UsageObserver

因此额度监控必须独立于 SessionWatcher。

架构：

```text
UsageObserver ─────────┐
                       ↓
                 DecisionEngine
                       ↑
SessionWatcher ────────┘
```

SessionWatcher 告诉系统：

> 哪个任务发生了什么。

UsageObserver 告诉系统：

> 当前账户额度实际上发生了什么。

否则用户完全没打开 Codex 时发生官方 Reset，Session 文件不会变化，Keeper 就无法察觉。

---

# 25. Usage 数据源

这里必须封装：

```text
UsageProvider
```

不能让整个 App 依赖某个私有接口格式。

优先顺序：

1. Codex 官方本地状态能力 / app-server / CLI status
2. 当前 Codex 使用的只读 Usage 数据源
3. Session snapshot 作为辅助信息

P0 阶段必须验证：

> 如何在不产生额度消耗的情况下可靠读取实时 Usage。

不要把某个具体 JSON 字段散落在整个工程中。

---

# 26. 5h / Weekly 不按 Primary / Secondary 判断

Codex 规则可能改变。

CCLimitPing 已经因为 2026 年曾临时出现 weekly-only regime，而改成按窗口长度识别 quota window。

因此：

```text
约 5h
→ FiveHour

约 7d
→ Weekly
```

而不是：

```text
Primary = FiveHour
Secondary = Weekly
```

如果未来没有 FiveHour：

```text
当前无需保活
```

自动暂停 Keep Alive。

---

# 27. SessionWatcher

监听：

```text
~/.codex/sessions/
```

主要关注：

```text
sessionID
cwd
project
timestamp
rate_limits
resetAt
usedPercent
limit type
最近 activity
```

启动：

```text
扫描一次最近 Session
```

之后：

```text
只监听新增 / append / 变化
```

不持续反复扫描所有历史。

---

# 28. Blocked Session 判定

不能简单：

```text
usedPercent == 100
→ blocked
```

因为：

- 可能还有 credits
- 可能当前 turn 仍允许完成
- 可能只是 snapshot
- 可能是服务容量错误

必须判定：

> 这个 Session 是否真正因为 rate limit 停止并等待恢复。

Codex 的 rollout 会包含 rate-limit snapshot，现有工具已经利用这些数据进行精确 reset 检测。

具体 classifier 属于 P0/P1 核心测试项。

---

# 29. Credits 与付费额度保护

Keeper 默认：

> **只负责恢复套餐内正常额度，不主动购买任何 reset，不主动购买 credits。**

绝不：

- 自动购买 Instant Reset
- 自动兑换 Banked Reset
- 自动增加付费额度

如果未来 Codex 在 included allowance 耗尽后可以继续使用 paid credits：

V1 应尽量区分：

```text
套餐额度恢复
```

与：

```text
仅有付费 credit 可用
```

默认不要因为 Keeper 的自动 Resume 意外产生额外付费。

---

# 30. Resume 前必须 Reconcile

这是整个安全体系最重要的一层。

任何自动动作前：

```text
重新获取 Usage
↓
重新读取目标 Session
↓
检查用户是否已经手动 Resume
↓
检查 Session 是否仍存在
↓
检查 Workspace 是否变化
↓
检查额度是否真的可用
↓
检查是否处于日锚点保护
↓
最后才执行
```

原则：

> **不要根据几小时前记录的世界执行动作。**

必须根据：

> 此刻重新确认后的世界。

---

# 31. 用户已经自己继续了

例如：

```text
10:30
Keeper 记录 Copied blocked

13:00
额度恢复
```

但：

```text
12:59
用户自己打开 Codex
```

并发送：

```text
继续
```

Keeper 在真正 Resume 前发现：

```text
BlockedAt 之后已经出现新的有效 activity
```

则：

```text
取消 Pending Resume
```

不能再补一个：

```text
继续
```

否则可能制造并发任务。

---

# 32. 用户在暂停期间修改项目

记录 blocked 时：

```text
Git HEAD
Branch
Dirty state
```

Resume 前再次检查。

如果没有变化：

```text
继续
```

如果工作区变化：

不要直接禁止。

改成更安全的 Resume 内容：

```text
工作区在暂停期间发生了变化。
请先重新检查当前状态，再继续之前的任务。
```

这类 workspace guard 已经被其他自动 Resume 工具证明很有价值。

---

# 33. Session 已删除 / 归档 / 无法恢复

如果 Resume：

```text
失败
```

绝不能：

```text
偷偷创建新 Session
```

正确行为：

```text
Copied 无法自动继续

原会话可能已删除、归档或项目位置发生变化
```

停止自动操作。

让用户处理。

---

# 34. 项目目录被移动

例如：

```text
~/Projects/Copied
```

变成：

```text
~/Code/Copied
```

原 Session cwd 不存在。

Keeper：

```text
不要自动猜新路径
```

通知：

```text
项目位置发生变化
无法安全自动继续
```

后续版本可以提供：

> 重新绑定项目目录。

V1 不做自动猜测。

---

# 35. 模型 Capacity / 服务故障

必须区分：

```text
quota exhausted
```

与：

```text
model at capacity
server error
network error
authentication error
```

只有：

**真正 quota exhaustion**

才进入：

```text
WaitingForQuota
```

服务容量不足：

```text
不要改变 Session quota 状态
```

通知用户。

不要无限重试。

---

# 36. 网络中断

例如：

```text
12:50 offline
13:00 reset
13:20 online
```

恢复网络时：

```text
丢弃旧 Usage cache
↓
重新读取 Usage
↓
重新扫描相关 Session
↓
DecisionEngine Reconcile
```

不能继续相信：

```text
12:50 的 quota snapshot
```

---

# 37. Mac Sleep / Wake

Wake 行为与网络恢复一致：

```text
Wake
↓
废弃旧 Timer 判断
↓
刷新 Usage
↓
刷新 Session
↓
重新计算下一动作
```

不应该只是：

```text
Timer 继续走
```

---

# 38. 睡眠错过普通 Ping

例如：

```text
13:00 应保活
Mac 睡着

15:00 Wake
```

没有待续任务：

> 不补 13:00 Ping。

因为补 Ping 会制造：

```text
15 → 20
```

继续把节奏拖走。

等待：

```text
18:00
```

重新尝试入轨。

---

# 39. 睡眠错过 Resume

如果：

```text
13:00 quota 已恢复
Copied 等待继续

Mac 睡眠
15:00 Wake
```

这属于：

**非计划时间额度已经可用 + 有待续任务**

所以重新套用：

```text
额度提前恢复时
```

的用户策略。

立即继续：

```text
15:00 Resume
```

保持计划：

```text
18:00 Resume
```

每次询问：

通知用户。

---

# 40. 巨型 Session 上下文

长期复杂 Session Resume 本身可能消耗很多额度。

V1 不应自动阻止。

但内部可以记录：

```text
context size / token_count
```

未来如果超过明显阈值：

```text
Copied 上下文很大

继续此任务可能产生较高额度消耗
```

第二版再考虑 Context Guard。

V1 不增加设置项。

---

# 41. 自动 Resume 不自动批准权限

Keeper 只负责：

```text
Resume
+
发送继续
```

之后所有 Codex：

- Approval
- Sandbox
- 文件权限
- 网络权限

完全保持用户原配置。

绝不能：

```text
自动点击 Allow
自动输入 Yes
自动 --yolo
```

如果 Resume 后 Codex 等待用户授权：

```text
Copied 已恢复
正在等待你的确认
```

发送通知即可。

---

# 42. 状态机

核心状态建议统一为：

```text
Disabled

Preparing
首次等待日锚点

Monitoring
正常运行

Pinging
正在保活

Blocked
存在额度中断任务

WaitingForQuota
等待额度恢复

WaitingForPlan
额度已恢复，但用户选择保持计划

WaitingForUser
额度提前恢复，等待用户选择

AnchorProtected
等待日锚点

Resuming
正在继续 Session

WeeklyBlocked
Weekly 不可用

OffPhase
当前节奏发生偏移

Reconciling
重新确认真实世界状态

Error
不可自动处理
```

这些是内部状态。

UI 不需要全部暴露。

---

# 43. 决策优先级

最终 DecisionEngine 可以概括为：

```text
1. 系统是否 Enabled
2. 当前数据是否可信
3. 是否有真实 blocked task
4. 当前额度是否允许执行
5. 用户是否已经自己处理
6. 是否处于非计划提前恢复
7. 是否触发日锚点保护
8. 当前是否是计划节点
9. Resume / Ping / Skip / Wait
```

其中：

> Reconcile 永远先于自动动作。

---

# 44. 原生 macOS App

技术栈与 Copied 保持一致：

```text
Swift
SwiftUI
AppKit
```

应用形式：

```text
LSUIElement
```

表现为：

> 菜单栏常驻 App。

默认：

- 不显示 Dock
- 没有普通主窗口
- 点击菜单栏图标弹 Popover
- Settings 使用独立 SwiftUI Window

---

# 45. 菜单栏正常状态

例如：

```text
Codex Keeper                 ON

下一次
18:00 · 保活

今日
08:00 ✓   13:00 ✓   18:00 ●   23:00

自动续跑
开启 ·「继续」

设置…
退出
```

---

# 46. 等待 Resume

```text
Codex Keeper                 ON

Copied

额度已耗尽
13:00 自动继续

今日
08:00 ✓   13:00 ●   18:00   23:00
```

---

# 47. 提前恢复等待选择

```text
Copied

额度已恢复 18 分钟
距计划时间还有 1小时04分

[立即继续]
[保持计划]
```

---

# 48. 日锚点保护

```text
Copied

额度已恢复

现在继续会跨过明日 08:00
距计划时间还有 23 分钟

[立即继续]
[等到 08:00]
```

---

# 49. 设置页

普通用户只需要：

```text
Codex Keeper        ON

每日开始时间
08:00

自动续跑           ON

续跑内容
继续

额度提前恢复时
● 每次询问
○ 立即继续
○ 保持计划

登录时启动         ON

执行异常时通知     ON
```

基本就这些。

---

# 50. 高级选项不要进入普通设置

例如：

```text
Codex binary
Model
Reasoning
Usage provider
PTY timeout
Reset buffer
Alignment tolerance
CODEX_HOME
Session store
```

全部系统自动处理。

最多以后加一个：

```text
Diagnostics
```

页面。

---

# 51. 原生工程模块

建议结构：

```text
CodexKeeper
│
├── App
│   ├── AppDelegate
│   ├── AppState
│   └── MenuBarController
│
├── Core
│   ├── DecisionEngine
│   ├── ScheduleEngine
│   ├── WindowCoordinator
│   ├── ReconciliationEngine
│   └── RuntimeState
│
├── Codex
│   ├── CodexLocator
│   ├── UsageObserver
│   ├── UsageProvider
│   ├── QuotaClassifier
│   ├── SessionWatcher
│   ├── SessionParser
│   ├── BlockedSessionDetector
│   ├── PingEngine
│   ├── ResumeEngine
│   ├── PingModelSelector
│   └── PingSessionIsolation
│
├── Process
│   └── PTYRunner
│
├── Workspace
│   └── WorkspaceGuard
│
├── System
│   ├── SleepWakeMonitor
│   ├── NetworkMonitor
│   ├── LoginItemManager
│   ├── NotificationManager
│   └── Logger
│
└── UI
    ├── MenuPopover
    ├── Settings
    ├── SessionPicker
    └── Components
```

---

# 52. 模块职责

**UsageObserver**

回答：

> 账户现在有多少额度，什么时候 reset。

**SessionWatcher**

回答：

> 哪个 Codex Session 最近发生了什么。

**BlockedSessionDetector**

回答：

> 是否真的存在因 quota 停下来的任务。

**ScheduleEngine**

回答：

> 用户的目标节点和下一日锚点是什么。

**ReconciliationEngine**

回答：

> 我之前知道的状态现在还是真的吗。

**DecisionEngine**

回答：

> Ping、Resume、Wait、Ask 还是 Skip。

**PingEngine**

只负责：

> 可靠启动新的 5h window。

**ResumeEngine**

只负责：

> 恢复指定真实 Session。

---

# 53. 本地数据

不需要数据库。

UserDefaults 保存：

```text
Enabled
DailyAnchor
AutoResume
ResumeMessage
EarlyRecoveryPolicy
LaunchAtLogin
Notifications
```

Application Support 保存 Runtime：

```text
BlockedSessions
SelectedBlockedSession
LastKnownUsage
LastAction
ExpectedWindow
CurrentPhase
PendingDecision
WorkspaceSnapshot
```

---

# 54. App 重启

例如：

```text
10:30
Copied blocked

11:00
用户重启 Keeper
```

启动以后：

```text
重新读取 Runtime
+
重新扫描 Session
+
重新读取 Usage
```

然后：

```text
Reconcile
```

不能单纯相信 runtime.json。

---

# 55. 日志

只记录事件。

例如：

```text
08:00:10 plan-node
08:00:11 reconcile
08:00:13 ping-start
08:00:18 ping-confirmed
08:00:19 reset=13:00:12

10:43:02 session-blocked Copied
10:43:03 limit=5h

13:00:13 quota-confirmed
13:00:14 resume-start
13:00:19 resume-confirmed
```

最多保留：

```text
最近 200～500 条
```

或者按文件大小轮转。

不记录：

- Token
- auth.json
- 完整 Prompt
- 项目代码
- 用户文件内容

---

# 56. 安全设计

Keeper：

- 没有服务器
- 没有云同步
- 没有 Telemetry
- 不需要 Accessibility
- 不需要 Screen Recording
- 不控制 Codex App UI
- 不自动批准权限
- 不自动购买额度
- 不无限重试

真正执行请求的是：

> 官方 Codex CLI / Codex 内置 binary。

---

# 57. Login Item

使用：

```text
SMAppService
```

实现：

```text
登录时启动
```

不使用老式 Login Item 方案。

V1 不需要额外 LaunchDaemon。

用户退出 Keeper：

> 所有自动化停止。

以后再考虑独立 Helper。

---

# 58. macOS Sleep / Wake / Clock

需要监听：

- Sleep
- Wake
- 网络状态
- 系统时间变化
- 时区变化
- 日期变化

这些事件统一执行：

```text
Reconcile()
```

而不是分别写复杂处理。

---

# 59. P0 技术验证

正式画 UI 前，只验证最危险的几个事实。

### P0-1

Swift Hidden PTY 是否能可靠触发真实订阅 5h window。

### P0-2

如何无额度成本地读取实时 5h / Weekly Usage。

### P0-3

Interactive Ping 如何不污染正常 Codex Session History。

### P0-4

Swift 能否可靠恢复：

- Codex CLI Session
- ChatGPT/Codex Desktop Session

并继续同一个历史会话。

### P0-5

如何可靠识别：

```text
真正 quota blocked
```

而不是单纯 `usedPercent = 100`。

### P0-6

外部 Full Reset 后 Usage 数据具体如何变化。

只有这六项跑通以后，再进入正式工程。

---

# 60. P1 核心引擎

完成：

```text
UsageObserver
SessionWatcher
BlockedSessionDetector
ScheduleEngine
ReconciliationEngine
DecisionEngine
PingEngine
ResumeEngine
WorkspaceGuard
```

这一阶段 UI 只需要 Debug Window。

---

# 61. P2 原生 UI

加入：

- 菜单栏
- Popover
- Settings
- Session Picker
- macOS Notifications
- Login at Launch
- 状态提示

---

# 62. P3 稳定性测试

正式发布前至少覆盖：

```text
普通 08/13/18/23

5h 提前耗尽

Weekly 耗尽

5h + Weekly 同时耗尽

Weekly reset 漂移

Automatic Reset

Banked Reset

Full Reset

复杂任务连续多个 5h

日锚点保护

用户手动 Resume

多个 blocked Session

Workspace 修改

Branch 切换

项目目录移动

Session 删除 / Archive

Mac Sleep

Wake

断网

网络恢复

Codex 未登录

Codex CLI 不存在

ChatGPT bundled Codex

模型被移除

模型 capacity

5h limit 暂时不存在

Usage 数据过期

App 重启

跨天

修改系统时间

修改时区
```

---

# 63. V1 明确不做

不做：

- 多账号
- Claude / Gemini
- Usage Dashboard
- Token 图表
- 完整 Session 浏览器
- 自动 Compact
- 自动批准权限
- 自动购买 Reset
- 自动使用 Banked Reset
- 自动使用付费 Credits
- 多任务并行 Resume
- 首次安装的复杂相位预校准
- 自动修复损坏 Session
- 自动猜测移动后的项目目录

---

# 64. V2 可以考虑

以后如果实际使用需要，再增加：

- 首次安装自动相位校准
- Context Guard
- Burn-rate 预测
- Session Priority
- 重新绑定移动后的项目
- 使用历史
- Ping 实际资源消耗统计
- 多任务恢复队列
- 更丰富的外部 Reset 识别

但这些都不应该阻塞 V1。

---

# 65. 最终产品逻辑

整个 Keeper 最后其实可以浓缩成两条循环。

## 平时

```text
计划节点到达
↓
重新确认真实状态
↓
已经有可用窗口？
→ Skip

没有窗口
↓
有待续任务？
→ Resume

没有任务
↓
Ping
```

## 异常

```text
非计划时间额度恢复
↓
没有待续任务
→ 什么都不做

有待续任务
↓
应用“额度提前恢复时”策略
↓
同时检查日锚点保护
↓
Resume / Wait / Ask
```

再配上一条永远生效的安全原则：

> **每一次自动动作前，都重新确认一次现实。**

不要因为 Keeper 在 10:30 记录了某件事，就在 13:00 盲目相信它。

13:00 的 Keeper 应该重新问：

> 额度真的恢复了吗？<br>
> Session 真的还停着吗？<br>
> 用户真的还没继续吗？<br>
> 项目真的还是原来的状态吗？<br>
> 现在真的适合启动新的 5 小时窗口吗？

全部成立以后，才行动。

这会成为整个 Codex Keeper 稳定性的核心。
