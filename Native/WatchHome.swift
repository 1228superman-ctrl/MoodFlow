#if os(watchOS)
import SwiftUI
import UserNotifications

private enum WatchTemplate: String, CaseIterable, Identifiable {
    case mood = "心情", energy = "身体电量", stress = "压力", pulse = "心率", hrv = "HRV", sleep = "睡眠"
    case count = "今日记录", latest = "最新波动", compare = "恢复与压力", vital = "生理速览", recent = "近期心情", compact = "极简"

    var id: String { rawValue }
}

struct WatchHome: View {
    @ObservedObject var probe: Probe
    @AppStorage("watch-template") private var template = WatchTemplate.mood
    @State private var recordingMood = false
    @State private var healthMessage: String?
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            List {
                display
                if let event = probe.activeEvent {
                    Section("发现波动") {
                        Text(event.detail).font(.caption2)
                        if let suggested = probe.suggestion(for: event) {
                            Button("确认 " + suggested.title) { probe.feedback(suggested.rawValue, for: event) }
                        }
                        NavigationLink("选择或纠正心情") {
                            List(Mood.allCases) { mood in
                                Button(mood.title) { probe.feedback(mood.rawValue, for: event) }
                            }.navigationTitle("此刻心情")
                        }
                    }
                }
                Button("记录心情", systemImage: "plus.circle") { recordingMood = true }
                NavigationLink("展示和权限") {
                    List {
                        Picker("展示模板", selection: $template) {
                            ForEach(WatchTemplate.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Toggle("波动提醒", isOn: $probe.noticesEnabled)
                            .onChange(of: probe.noticesEnabled) { _, enabled in
                                if enabled {
                                    Task {
                                        let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                                        if !granted { probe.noticesEnabled = false }
                                    }
                                }
                            }
                        Toggle("事件定位", isOn: $probe.locationEnabled)
                            .onChange(of: probe.locationEnabled) { _, enabled in if enabled { probe.configureLocation() } }
                        #if MOODFLOW_SIM
                        Button("模拟波动") {
                            let sample = Physiology(bpm: 95, delta: 27, hrv: 38, sleepHours: 7)
                            probe.add(Entry(kind: "生理数据", detail: "模拟", physiology: sample))
                            probe.variation(detail: "模拟 · 68 → 95 bpm", physiology: sample)
                        }
                        #else
                        Button("连接 Apple 健康", action: connectHealth).disabled(connecting)
                        #endif
                        if let healthMessage { Text(healthMessage).font(.footnote) }
                    }.navigationTitle("设置")
                }
                #if MOODFLOW_SIM
                Text("模拟数据版").font(.caption2).foregroundStyle(.secondary)
                #endif
            }.navigationTitle("心绪")
                .sheet(isPresented: $recordingMood) {
                    List(Mood.allCases) { mood in
                        Button(mood.title) { probe.manual(mood); recordingMood = false }
                    }
                }
        }
    }

    @ViewBuilder private var display: some View {
        let sample = probe.physiology
        let mood = probe.lastMood
        switch template {
        case .mood:
            stat(mood?.title ?? "记录此刻", "最近心情", icon: "face.smiling", color: .mint)
        case .energy:
            meter(sample?.energy, template.rawValue, color: .mint)
        case .stress:
            meter(sample?.stress, template.rawValue, color: .orange)
        case .pulse:
            stat(sample?.bpm.map { "\(Int($0)) bpm" } ?? "—", "最近心率", icon: "heart.fill", color: .pink)
        case .hrv:
            stat(sample?.hrv.map { "\(Int($0)) ms" } ?? "—", "HRV SDNN", icon: "waveform.path.ecg", color: .cyan)
        case .sleep:
            stat(sample?.sleepHours.map { "\($0.formatted(.number.precision(.fractionLength(1)))) 小时" } ?? "—",
                "最近 24 小时睡眠", icon: "moon.stars.fill", color: .indigo)
        case .count:
            let count = probe.moodEvents.filter { Calendar.current.isDateInToday($0.time) }.count
            stat("\(count) 条", "今日记录", icon: "list.bullet", color: .yellow)
        case .latest:
            let event = probe.moodEvents.first { $0.kind == "波动事件" }
            VStack(alignment: .leading) {
                Text(event?.time.formatted(date: .omitted, time: .shortened) ?? "暂无波动").font(.headline)
                if let event { Text(event.detail).font(.caption2) }
            }
        case .compare:
            VStack(alignment: .leading) {
                meter(sample?.energy, "身体电量", color: .mint)
                meter(sample?.stress, "压力", color: .orange)
            }
        case .vital:
            VStack(alignment: .leading) {
                Label(sample?.bpm.map { "\(Int($0)) bpm" } ?? "心率 —", systemImage: "heart")
                Label(sample?.hrv.map { "\(Int($0)) ms" } ?? "HRV —", systemImage: "waveform")
            }.font(.caption)
        case .recent:
            let moods = probe.moodEvents.compactMap { probe.mood(for: $0) }.prefix(5)
            VStack(alignment: .leading) {
                Text(moods.map(\.emoji).joined(separator: " ")).font(.headline)
                Text(moods.isEmpty ? "还没有心情记录" : "最近五次标记").font(.caption2)
            }
        case .compact:
            HStack {
                Text(mood?.emoji ?? "—").font(.title2)
                Spacer()
                Text(sample?.energy.map { "\($0)%" } ?? "—").monospacedDigit()
            }.accessibilityLabel("心情和身体电量")
        }
    }

    private func stat(_ value: String, _ label: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: icon).foregroundStyle(color).font(.caption2)
            Text(value).font(.system(.title3, design: .rounded).weight(.semibold))
        }.accessibilityElement(children: .combine)
    }

    private func meter(_ value: Int?, _ title: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title + " " + (value.map(String.init) ?? "—")).font(.caption)
            if let value { ProgressView(value: Double(value), total: 100).tint(color) }
        }
    }

    private func connectHealth() {
        #if !MOODFLOW_SIM
        connecting = true
        Task {
            defer { connecting = false }
            do {
                try await HealthProbe.shared.authorize()
                await HealthProbe.shared.register()
                await HealthProbe.shared.readAll()
                healthMessage = probe.physiology == nil ? "暂未读到样本" : "已刷新健康数据"
            } catch { healthMessage = "连接失败，请检查权限和签名。" }
        }
        #endif
    }
}
#endif
