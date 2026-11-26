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
    @AppStorage("mood-art-theme") private var artTheme = MoodTheme.sunrise
    @State private var recordingMood = false
    @State private var faceEventID: String?
    @State private var healthMessage: String?
    @State private var connecting = false
    @StateObject private var capture = WatchCapture.shared
    @StateObject private var companion = Companion.shared
    @AppStorage("monitor-watch-entry-receipt") private var lastEntryReceipt = 0.0

    var body: some View {
        NavigationStack {
            List {
                display
                if companion.pendingEntries > 0 {
                    Label("手表已保存 · \(companion.pendingEntries) 条待同步", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                    Button("重试同步") { companion.retryNow() }.font(.caption2)
                } else if lastEntryReceipt > 0 {
                    Label("iPhone 已收到记录", systemImage: "checkmark.icloud")
                        .font(.caption2)
                    Text(Date(timeIntervalSince1970: lastEntryReceipt).formatted(date: .omitted, time: .shortened))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                NavigationLink {
                    WatchRecordingScreen(capture: capture)
                } label: {
                    VStack(alignment: .leading) {
                        Label(capture.isRecording ? "正在录音" : (capture.enabled ? "录音已暂停" : "全天录音"),
                            systemImage: capture.isRecording ? "mic.fill" : "mic")
                        if capture.isRecording, let start = capture.startedAt {
                            Text(start, style: .timer).font(.caption2.monospacedDigit())
                        }
                        if capture.pendingCount > 0 { Text("\(capture.pendingCount) 段待同步").font(.caption2) }
                    }
                }
                if let event = probe.activeEvent {
                    Section("发现波动") {
                        Text(event.detail).font(.caption2)
                        if let suggested = probe.suggestion(for: event) {
                            Button("确认 " + suggested.title) { probe.feedback(suggested.rawValue, for: event) }
                        }
                        if event.analysis != nil { EstimateFeedback(probe: probe, event: event) }
                        NavigationLink("选择或纠正心情") {
                            List(Mood.allCases) { mood in
                                Button(mood.title) { probe.feedback(mood.rawValue, for: event) }
                            }.navigationTitle("此刻心情")
                        }
                    }
                }
                NavigationLink {
                    WatchMoodThemeScreen(probe: probe, theme: artTheme)
                } label: {
                    Label("主题预览", systemImage: "paintpalette")
                }
                Button("记录心情", systemImage: "plus.circle") { showMoodPicker(eventID: nil) }
                NavigationLink("展示和权限") {
                    List {
                        NavigationLink("监测状态") { MonitorStatus(probe: probe) }
                        Picker("展示模板", selection: $template) {
                            ForEach(WatchTemplate.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Picker("预览主题", selection: $artTheme) {
                            ForEach(MoodTheme.allCases) { Text($0.title).tag($0) }
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
        }
        .onOpenURL { url in
            guard url.scheme == "moodflow", url.host == "mood" else { return }
            let eventID = url.lastPathComponent
            showMoodPicker(eventID: UUID(uuidString: eventID) == nil ? nil : eventID)
        }
        .sheet(isPresented: $recordingMood) {
            WatchMoodChoices(probe: probe, eventID: faceEventID)
        }
    }

    private func showMoodPicker(eventID: String?) {
        faceEventID = eventID
        recordingMood = true
    }

    @ViewBuilder private var display: some View {
        let sample = probe.physiology
        let mood = probe.lastMood
        let freshMood = probe.displayedMood.flatMap { $0.expires > .now ? $0 : nil }
        switch template {
        case .mood:
            stat(freshMood.map { $0.emoji + " " + $0.label } ?? "等待新数据",
                freshMood?.status ?? "暂无近期判断", icon: "face.smiling", color: .mint)
        case .energy:
            energyMeter(sample)
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
                energyMeter(sample)
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
                Text(sample?.energy().map { "\($0)%" } ?? "缺少睡眠").monospacedDigit()
            }.accessibilityLabel("心情和身体电量")
        }
    }

    private func energyMeter(_ sample: Physiology?) -> some View {
        VStack(alignment: .leading) {
            meter(sample?.energy(), "身体电量", color: .mint)
            if sample?.energy() == nil { Text("未读到近 36 小时睡眠").font(.caption2) }
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
