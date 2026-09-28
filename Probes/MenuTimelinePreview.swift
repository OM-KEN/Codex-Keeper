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
            return MenuSummary.build(plan: plan, usage: quota, schedule: schedule, tasks: tasks, now: current)
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
        var running = stopped; running.headline = "正在继续"; running.action = ""; running.isTime = false; running.timeline = []
        running.eyebrow = ""
        var failed = stopped; failed.error = "连接失败，请检查 Codex 登录状态"
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
        print("Rendered 18 production-view scenarios to \(folder.path)")
    }
}
