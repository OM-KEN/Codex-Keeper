import Foundation
import SwiftUI
import AppKit

// Read-only visual fixtures: uses the production presenter and view; never starts AppState.
@main struct MenuTimelinePreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        func at(_ hour: Int, _ minute: Int = 0, days: Int = 0) -> Date {
            calendar.date(byAdding: .day, value: days, to: base)!.addingTimeInterval(Double(hour * 3600 + minute * 60))
        }
        let now = at(9, 40)
        let schedule = ScheduleEngine(anchorMinutes: 480)
        func usage(_ reset: Date, used: Double = 82, weekUsed: Double = 60, weekReset: Date? = nil, active: Bool? = nil, time: Date? = nil) -> UsageSnapshot {
            UsageSnapshot(fiveHour: QuotaWindow(usedPercent: used, windowMinutes: 300, resetsAt: reset),
                weekly: QuotaWindow(usedPercent: weekUsed, windowMinutes: 10080, resetsAt: weekReset ?? at(14, 50, days: 6)),
                capturedAt: time ?? now, sourceFile: "app-server", zeroUseWindowActive: active)
        }
        func task(_ title: String) -> BlockedSession {
            BlockedSession(id: title, project: title, cwd: "/preview", blockedAt: now, fiveHourResetAt: at(13, 5), weeklyResetAt: nil, fileURL: URL(fileURLWithPath: "/preview/unused"), title: title)
        }
        func summary(_ quota: UsageSnapshot, tasks: [BlockedSession] = [], time: Date? = nil) -> MenuSummary {
            let current = time ?? now
            let plan = DecisionEngine(schedule: schedule).plan(now: current, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: quota, blocked: tasks)
            var presentation = MenuPresentation()
            return presentation.build(plan: plan, usage: quota, schedule: schedule, tasks: tasks,
                availableTasks: tasks, choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan", now: current)
        }
        let current = task("Codex Keeper")
        let offPlan = summary(usage(at(13, 5)))
        let normal = summary(usage(at(13)))
        let stopped = summary(usage(at(13, 5), used: 100), tasks: [current])
        let weekly = usage(at(13, 5), used: 100, weekUsed: 100, weekReset: at(14, 50, days: 6))
        var stale = usage(at(13, 5)); stale.capturedAt = now.addingTimeInterval(-61)
        let completedUsage = usage(at(13, 5))
        let completedPlan = DecisionEngine(schedule: schedule).plan(now: now, enabled: true, autoResume: true, earlyRecoveryPolicy: "keepPlan", usage: completedUsage, blocked: [])
        let completed = MenuSummary.build(plan: completedPlan, usage: completedUsage, schedule: schedule, tasks: [], confirmations: [ExecutionConfirmation(kind: .resume, actionAt: at(8, 5), confirmedAt: at(9), windowStart: nil)], now: now)
        var executionPresentation = MenuPresentation()
        let resumeQuota = usage(at(13, 5), used: 100)
        let resumePlan = DecisionEngine(schedule: schedule).plan(now: now, enabled: true, autoResume: true,
            earlyRecoveryPolicy: "keepPlan", usage: resumeQuota, blocked: [current])
        let history = ExecutionConfirmation(kind: .keepAlive, actionAt: at(8, 5), confirmedAt: at(8, 6), windowStart: at(8, 5))
        let running = executionPresentation.build(plan: resumePlan, usage: resumeQuota, schedule: schedule,
            tasks: [current], availableTasks: [current], choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan",
            confirmations: [history], running: true, executionMode: .resume, now: now)
        var invalidated = resumeQuota; invalidated.capturedAt = .distantPast
        let filteredTime = now.addingTimeInterval(61)
        let filteredPlan = DecisionEngine(schedule: schedule).plan(now: filteredTime, enabled: true, autoResume: true,
            earlyRecoveryPolicy: "keepPlan", usage: invalidated, blocked: [])
        let runningAfterAttempt = executionPresentation.build(plan: filteredPlan, usage: invalidated, schedule: schedule,
            tasks: [], availableTasks: [], choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan",
            usageError: "无法连接 Codex 服务，请检查网络或代理后重新同步。", usageErrorIsTransient: true,
            running: true, executionMode: .resume, refreshing: true, now: filteredTime)
        let executingQuota = usage(at(14, 41), used: 9, time: now.addingTimeInterval(62))
        let executingPlan = DecisionEngine(schedule: schedule).plan(now: executingQuota.capturedAt, enabled: true, autoResume: true,
            earlyRecoveryPolicy: "keepPlan", usage: executingQuota, blocked: [])
        let runningUpdate = executionPresentation.build(plan: executingPlan, usage: executingQuota, schedule: schedule,
            tasks: [], availableTasks: [], choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan",
            running: true, executionMode: .resume, now: executingQuota.capturedAt)
        let runningRetry = executionPresentation.build(plan: filteredPlan, usage: nil, schedule: schedule,
            tasks: [], availableTasks: [], choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan",
            usageError: "无法连接 Codex 服务，请检查网络或代理后重新同步。", usageErrorIsTransient: true,
            running: true, executionMode: .resume, now: now.addingTimeInterval(124))
        let finishedQuota = usage(at(14, 41), used: 5, time: now.addingTimeInterval(125))
        let finishedPlan = DecisionEngine(schedule: schedule).plan(now: finishedQuota.capturedAt, enabled: true, autoResume: true,
            earlyRecoveryPolicy: "keepPlan", usage: finishedQuota, blocked: [])
        let finished = executionPresentation.build(plan: finishedPlan, usage: finishedQuota, schedule: schedule,
            tasks: [], availableTasks: [], choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan",
            confirmations: [ExecutionConfirmation(kind: .resume, actionAt: at(9, 41),
                confirmedAt: finishedQuota.capturedAt, windowStart: at(9, 41))], now: finishedQuota.capturedAt)
        var continuity = MenuPresentation()
        let stableQuota = usage(at(13))
        let stablePlan = DecisionEngine(schedule: schedule).plan(now: now, enabled: true, autoResume: true,
            earlyRecoveryPolicy: "keepPlan", usage: stableQuota, blocked: [])
        let stable = continuity.build(plan: stablePlan, usage: stableQuota, schedule: schedule, tasks: [],
            availableTasks: [], choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan",
            confirmations: [ExecutionConfirmation(kind: .keepAlive, actionAt: at(8), confirmedAt: at(8, 1), windowStart: at(8))], now: now)
        let syncing = continuity.build(plan: filteredPlan, usage: stableQuota, schedule: schedule, tasks: [],
            availableTasks: [], choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan", refreshing: true, now: filteredTime)
        let temporaryFailure = continuity.build(plan: filteredPlan, usage: nil, schedule: schedule, tasks: [],
            availableTasks: [], choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan",
            usageError: "无法连接 Codex 服务，请检查网络或代理后重新同步。", usageErrorIsTransient: true, now: filteredTime)
        continuity.requestRefreshFeedback()
        let queued = continuity.build(plan: filteredPlan, usage: nil, schedule: schedule, tasks: [],
            availableTasks: [], choices: ResumeChoices(), earlyRecoveryPolicy: "keepPlan", refreshing: true,
            refreshMessage: L10n.text("正在同步，完成后重新读取…"), now: filteredTime)
        var failed = stopped; failed.error = "无法连接 Codex 服务，请检查网络或代理后重新同步。"
        var unknown = usage(at(13, 5), used: 0); unknown.zeroUseWindowActive = nil
        let pages: [(String, [(String, MenuSummary)])] = [
            ("01-plans", [
                ("正常计划内", normal),
                ("计划外 · 当前实际情况", offPlan),
                ("撞额度墙 · 本任务自动继续", stopped),
                ("多个任务 · 默认全部继续", summary(usage(at(13, 5), used: 100), tasks: [task("完善某项目的长标题，用于检查省略和固定会话计数"), current, task("Copied")])),
                ("取消下一次自动继续后", summary(usage(at(13, 5), used: 100))),
                ("已手动继续 · 移出待续列表", offPlan)
            ]),
            ("02-boundaries", [
                ("每周也耗尽 · 等周额度恢复再继续", summary(weekly, tasks: [current])),
                ("每周耗尽 · 没有待续任务", summary(weekly)),
                ("凌晨保护 · 续跑顺延至 08:00", summary(usage(at(4, 5), used: 100, time: at(2)), tasks: [current], time: at(2))),
                ("睡醒已错过节点 · 不补保活", summary(usage(at(20), used: 0, active: false, time: at(15)), time: at(15))),
                ("夜间自然空档 · 等早晨 08:00", summary(usage(at(10), used: 0, active: false, time: at(5)), time: at(5))),
                ("仅偏离几秒 · 仍属同一轮", summary(usage(at(13).addingTimeInterval(8))))
            ]),
            ("03-status", [
                ("数据过期或尚未同步", summary(stale)),
                ("额度窗口状态仍在确认", summary(unknown)),
                ("Keeper 已完成计划外续跑", completed),
                ("已停用", MenuSummary(headline: "已停用")),
                ("正在执行", running),
                ("执行异常 · 才展示原因", failed)
            ]),
            ("04-continuity", [
                ("上次已确认保活的正常状态", stable),
                ("后台超过 60 秒仍在同步", syncing),
                ("临时失败 · 保留上次信息", temporaryFailure),
                ("执行已记录尝试 · 任务被过滤后", runningAfterAttempt),
                ("点击刷新 · 明确排队反馈", queued),
                ("执行结束 · 新状态立即替换", finished)
            ]),
            ("05-execution-updates", [
                ("执行开始 · 原额度已耗尽", runningAfterAttempt),
                ("执行中 · 收到新额度", runningUpdate),
                ("再次暂时失败 · 保留最新额度", runningRetry)
            ])
        ]
        let folder = URL(fileURLWithPath: ".build/timeline-preview")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (name, cases) in pages {
            let view = VStack(alignment: .leading, spacing: 18) {
                Text("Codex Keeper · 状态预览").font(.system(size: 23, weight: .semibold))
                Text("示例数据 · 实线表示当前额度周期，虚线表示等待，勾号仅表示 Keeper 确认完成").font(.system(size: 13)).foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(304), alignment: .top), count: 3), alignment: .leading, spacing: 20) {
                    ForEach(cases.indices, id: \.self) { index in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(cases[index].0).font(.system(size: 12, weight: .semibold)).padding(.leading, 6)
                            VStack(spacing: 0) {
                                MenuSummaryView(summary: cases[index].1)
                                if !cases[index].1.quotas.isEmpty {
                                    Divider()
                                    MenuQuotaView(quotas: cases[index].1.quotas)
                                }
                            }.background(Color.white).clipShape(RoundedRectangle(cornerRadius: 12))
                        }.frame(maxHeight: .infinity, alignment: .top)
                    }
                }
            }.padding(24).background(Color(white: 0.93)).environment(\.colorScheme, .light)
            // ImageRenderer cannot render AppKit-backed native progress controls.
            let host = NSHostingView(rootView: view)
            let size = host.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name + ".png"))
        }
        print("Rendered \(pages.reduce(0) { $0 + $1.1.count }) production-view scenarios to \(folder.path)")
    }
}
