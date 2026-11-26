import SwiftUI
import UserNotifications
#if os(watchOS)
import WatchKit
#endif

@MainActor
enum MonitorActions {
    static let category = "mood-estimate-v6"
    static func install() {
        let actions = [
            UNNotificationAction(identifier: "correct", title: "判断正确"),
            UNNotificationAction(identifier: "change", title: "修改心情", options: .foreground),
            UNNotificationAction(identifier: "wrong", title: "判断不正确"),
            UNNotificationAction(identifier: "unsure", title: "暂无法确认")
        ]
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: category + "-unknown", actions: Array(actions.dropFirst()), intentIdentifiers: []),
            UNNotificationCategory(identifier: category, actions: actions, intentIdentifiers: [])
        ])
    }

    static func respond(_ response: UNNotificationResponse) async {
        let probe = Probe.shared
        guard let entry = await probe.entryForInteraction(response.notification.request.identifier),
              let estimate = entry.analysis else { return }
        switch response.actionIdentifier {
        case "correct":
            if let mood = Mood(rawValue: String(estimate.label.dropFirst(2))) { probe.feedback(mood.rawValue, for: entry) }
            else { probe.selectEstimate(entry) }
        case "wrong": probe.feedback("判断不正确", for: entry)
        case "unsure": probe.feedback("暂无法确认", for: entry)
        default: probe.selectEstimate(entry)
        }
    }
}

extension Probe {
    func notifyEstimate(_ entry: Entry) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let defaults = UserDefaults.standard
        let last = entries.first { $0.id == defaults.string(forKey: "monitor-last-notice") }
        let reason = MoodEstimate.notificationReason(entry, previous: last, now: .now)
        if let reason {
            defaults.set(reason, forKey: "monitor-reason")
            return
        }
        guard noticesEnabled, [.authorized, .provisional].contains(settings.authorizationStatus) else {
            defaults.set("提醒开关或系统通知权限未开启", forKey: "monitor-reason")
            return
        }
        guard let estimate = entry.analysis, last?.id != entry.id else { return }
        let content = UNMutableNotificationContent()
        content.categoryIdentifier = MonitorActions.category + (estimate.label == "线索不足" ? "-unknown" : "")
        content.title = estimate.label == "线索不足" ? "身体状态有变化" : estimate.label
        content.body = estimate.confidence + " · " + (estimate.reason ?? "")
        content.sound = .default
        defaults.set(entry.id, forKey: "monitor-last-notice")
        do {
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: entry.id, content: content, trigger: nil))
            add(Entry(kind: "主动提醒", detail: "系统已接受通知请求", eventID: entry.id), sync: false)
            defaults.set("已提交通知", forKey: "monitor-reason")
            #if os(watchOS)
            if isActive { WKInterfaceDevice.current().play(.click); selectEstimate(entry) }
            #endif
        } catch {
            if defaults.string(forKey: "monitor-last-notice") == entry.id { defaults.set(last?.id, forKey: "monitor-last-notice") }
            defaults.set("系统通知请求失败", forKey: "monitor-reason")
        }
    }
}

struct EstimateFeedback: View {
    @ObservedObject var probe: Probe
    let event: Entry
    var body: some View {
        if let estimate = event.analysis {
            if let mood = Mood(rawValue: String(estimate.label.dropFirst(2))) {
                Button("判断正确") { probe.feedback(mood.rawValue, for: event) }
            }
            Button("判断不正确") { probe.feedback("判断不正确", for: event) }
            Button("暂无法确认") { probe.feedback("暂无法确认", for: event) }
        }
    }
}

struct MonitorStatus: View {
    @ObservedObject var probe: Probe
    @AppStorage("health-enabled") private var enabled = false
    @AppStorage("monitor-reason") private var reason = "尚无提醒评估"
    @AppStorage("monitor-sync") private var sync = "暂无传输结果"
    @State private var permission = "读取中"

    private func time(_ date: Date?) -> String { date?.formatted(date: .abbreviated, time: .standard) ?? "暂无记录" }
    var body: some View {
        let entries = probe.entries
        let today = entries.filter { Calendar.current.isDateInToday($0.evaluatedAt ?? $0.time) }
        let sample = entries.first { $0.analysis != nil }
        let callback = UserDefaults.standard.object(forKey: "monitor-callback") as? Date
        let background = UserDefaults.standard.object(forKey: "monitor-background") as? Date
        List {
            Text(enabled ? "日常监测已开启" : "日常监测等待健康授权")
            Text("高频监测受限于系统采样。日常模式随可用样本更新。")
            Text("心率采样 · " + time(probe.physiology?.sampledAt))
            Text(UserDefaults.standard.string(forKey: "monitor-heart-state") ?? "尚未查询心率")
            Text("最近收到回调 · " + time(callback))
            Text("最近后台回调 · " + time(background))
            ForEach(["heartRate", "heartRateVariabilitySDNN", "sleepAnalysis"], id: \.self) { type in
                let registration = entries.first { $0.kind.hasPrefix("后台注册") && $0.detail.lowercased().contains(type.lowercased()) && (type != "heartRate" || !$0.detail.contains("Variability")) }
                Text(type + " · " + (registration?.kind ?? "尚无注册结果"))
            }
            Text("最近判断 · " + time(sample?.evaluatedAt))
            Text(sample.map { Date.now.timeIntervalSince($0.time) >= MoodFaceSnapshot.freshFor ? "数据已过期" : ($0.analysis?.label ?? "线索不足") + " · " + ($0.analysis?.confidence ?? "") } ?? "尚无手表判断")
            Text("本机今日分析或同步判断 \(today.filter { $0.analysis != nil }.count) 次")
            Text("今日提交通知 \(today.filter { $0.kind == "主动提醒" }.count) 次")
            Text("今日反馈 \(today.filter { $0.kind == "情绪反馈" }.count) 次")
            Text("通知权限 · " + permission)
            Text(reason)
            Text("双端同步 · " + sync)
        }.navigationTitle("监测状态").task {
            let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
            permission = status == .authorized ? "已允许" : (status == .denied ? "已拒绝" : "未授权或受限")
        }
    }
}
