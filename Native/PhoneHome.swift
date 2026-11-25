#if os(iOS)
import SwiftUI
import Charts
import UniformTypeIdentifiers
import UserNotifications
import UIKit

struct PhoneHome: View {
    @ObservedObject var probe: Probe
    @StateObject private var audio = AudioProbe()
    @State private var selected = 0
    @State private var recordingEvent: Entry?
    @State private var confirmRecording = false
    @State private var connecting = false
    @State private var healthMessage: String?
    @State private var noticesDenied = false
    @Environment(\.scenePhase) private var phase
    @Environment(\.openURL) private var openURL

    var body: some View {
        TabView(selection: $selected) {
            NavigationStack { today }.tabItem { Label("今天", systemImage: "heart.text.clipboard") }.tag(0)
            NavigationStack { HistoryHome(probe: probe, audio: audio, onRecord: requestRecording) }
                .tabItem { Label("回顾", systemImage: "calendar") }.tag(1)
            NavigationStack { SummaryHome(probe: probe) }.tabItem { Label("总结", systemImage: "doc.text") }.tag(2)
            NavigationStack { settings }.tabItem { Label("设置", systemImage: "gearshape") }.tag(3)
        }
        .tint(Color(red: 0.12, green: 0.45, blue: 0.37))
        .onChange(of: probe.phoneNoticeSelection, initial: true) { _, selection in
            if selection != nil { selected = 0 }
        }
        .onChange(of: phase, initial: true) { _, value in
            if value == .active {
                DailyQueue.enqueueDue()
                Task { await refreshNoticeSettings() }
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { now in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: now)
            if parts.hour == 23 && parts.minute == 59 { DailyQueue.enqueueDue(now: now) }
        }
        .confirmationDialog("本次录音最多三分钟。请先确认在场者同意。", isPresented: $confirmRecording,
            titleVisibility: .visible) {
            Button("同意并开始录音") { Task { await audio.start(for: recordingEvent) } }
            Button("取消", role: .cancel) {}
        }
    }

    private var today: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(Date.now.formatted(.dateTime.month().day().weekday()))
                        .font(.subheadline.weight(.medium))
                    Text(probe.lastMood?.title ?? "此刻感觉如何？")
                        .font(.system(.largeTitle, design: .rounded).weight(.semibold))
                    MoodPicker { probe.manual($0) }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 22))

                if let event = probe.activeEvent {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("待确认的波动").font(.headline)
                        Text(event.detail).foregroundStyle(.secondary)
                        if let suggestion = probe.suggestion(for: event) {
                            Button("确认 " + suggestion.title) { probe.feedback(suggestion.rawValue, for: event) }
                                .buttonStyle(.borderedProminent)
                            Text("也可以选择其他感受").font(.caption)
                        }
                        MoodPicker { probe.feedback($0.rawValue, for: event) }
                        Button("为此事件录音") { requestRecording(event) }
                    }.padding(14).background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))
                }

                healthPanel
                if audio.recording {
                    Button("录音中 · 停止", role: .destructive) { audio.stop() }
                        .buttonStyle(.bordered)
                } else {
                    Button { requestRecording(nil) } label: {
                        Label("录一段语音", systemImage: "mic")
                    }.buttonStyle(.bordered).disabled(audio.starting)
                }
                if probe.writeError { Text("本机记录暂时无法保存或读取。").foregroundStyle(.red) }
            }.padding(16)
        }.navigationTitle("心绪")
    }

    private var healthPanel: some View {
        let metrics = probe.physiology
        let history = Array(probe.entries.filter { $0.kind == "生理数据" && $0.physiology?.bpm != nil }.prefix(35))
        return VStack(alignment: .leading, spacing: 10) {
            Text("身体状态").font(.title3.weight(.semibold))
            HStack(spacing: 12) {
                metric("身体电量", value: metrics?.energy().map(String.init), symbol: "battery.75percent", tint: .teal)
                metric("压力评分", value: metrics?.stress.map(String.init), symbol: "waveform.path", tint: .orange)
            }
            Text(metrics?.energy() == nil ? "身体电量需要近 36 小时的睡着记录。" :
                "身体电量以最近一段睡眠为起点，结合可用的 HRV、心率和活动能量估算。")
                .font(.footnote).foregroundStyle(.secondary)
            HStack {
                Label(metrics?.bpm.map { "\(Int($0)) bpm" } ?? "心率 —", systemImage: "heart")
                Spacer()
                Text(metrics?.hrv.map { "HRV \(Int($0)) ms" } ?? "HRV —")
                Spacer()
                Text(metrics?.sleepHours.map { "\($0.formatted(.number.precision(.fractionLength(1)))) 小时" } ?? "睡眠 —")
            }.font(.footnote)
            if history.count > 1 {
                Chart(history) { entry in
                    if let bpm = entry.physiology?.bpm {
                        LineMark(x: .value("时间", entry.time), y: .value("心率 bpm", bpm))
                        PointMark(x: .value("时间", entry.time), y: .value("心率 bpm", bpm))
                    }
                }.frame(height: 115).accessibilityLabel("近期心率趋势")
            }
            #if MOODFLOW_SIM
            Text("模拟版使用虚构数据。").font(.footnote).foregroundStyle(.secondary)
            #else
            if metrics == nil { Button("连接 Apple 健康", action: connectHealth).disabled(connecting) }
            #endif
        }
    }

    private func metric(_ title: String, value: String?, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol).font(.caption.weight(.semibold))
            Text(value ?? "—").font(.system(.title, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var settings: some View {
        Form {
            NavigationLink("监测状态") { MonitorStatus(probe: probe) }
            Section("事件") {
                Toggle("事件定位", isOn: $probe.locationEnabled)
                    .onChange(of: probe.locationEnabled) { _, enabled in if enabled { probe.configureLocation() } }
                Toggle("手机波动提醒", isOn: $probe.noticesEnabled)
                    .onChange(of: probe.noticesEnabled) { _, enabled in
                        if enabled {
                            Task {
                                let granted = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
                                if !granted { probe.noticesEnabled = false }
                                await refreshNoticeSettings()
                            }
                        }
                    }
                if noticesDenied, let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    Button("打开系统通知设置") { openURL(url) }
                } else if probe.noticesEnabled {
                    Button("发送测试通知", action: sendTestNotice)
                }
                Text("手机检测到波动，或收到手表同步的近期事件时会提醒。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("健康数据") {
                #if MOODFLOW_SIM
                Button("载入模拟数据") {
                    let sample = Physiology(bpm: 95, delta: 27, hrv: 38, sleepHours: 7)
                    probe.add(Entry(kind: "生理数据", detail: "模拟", physiology: sample))
                    probe.variation(detail: "模拟 · 68 → 95 bpm", physiology: sample)
                    selected = 0
                }
                #else
                Button("授权或刷新 Apple 健康", action: connectHealth).disabled(connecting)
                #endif
                if let healthMessage { Text(healthMessage).font(.footnote) }
            }
            Section("隐私") {
                Text("事件会与已配对的手表同步。录音、转写和地图保存在设备上。ChatGPT 仅处理你选择导出的日统计。")
            }
        }.navigationTitle("设置")
    }

    private func refreshNoticeSettings() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        noticesDenied = settings.authorizationStatus == .denied
        if noticesDenied { probe.noticesEnabled = false }
    }

    private func sendTestNotice() {
        let content = UNMutableNotificationContent()
        content.title = "心绪通知测试"
        content.body = "手机波动提醒已开启。"
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "moodflow-notice-test", content: content, trigger: trigger))
    }

    private func requestRecording(_ event: Entry?) {
        recordingEvent = event
        confirmRecording = true
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
                healthMessage = probe.physiology == nil ? "暂未读到样本，请检查 Apple 健康里的授权及记录。" : "已刷新本机健康记录。"
            } catch { healthMessage = "未能连接 Apple 健康，请检查权限和当前签名。" }
        }
        #endif
    }
}

struct MoodPicker: View {
    let select: (Mood) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 91), alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(Mood.allCases) { mood in
                Button(mood.title) { select(mood) }.buttonStyle(.bordered)
            }
        }
    }
}

struct HistoryHome: View {
    @ObservedObject var probe: Probe
    @ObservedObject var audio: AudioProbe
    let onRecord: (Entry?) -> Void
    @State private var tab = "日历"
    @State private var month = Date.now
    @State private var day = Date.now
    @State private var mapped: Entry?
    private let calendar = Calendar.current

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("回顾", selection: $tab) {
                    Text("日历").tag("日历")
                    Text("地图").tag("地图")
                    Text("录音").tag("录音")
                }.pickerStyle(.segmented)
                switch tab {
                case "地图": map
                case "录音": recordings
                default: monthCalendar
                }
            }.padding(16)
        }.navigationTitle("回顾")
    }

    private var monthCalendar: some View {
        let start = calendar.dateInterval(of: .month, for: month)?.start ?? month
        let days = calendar.range(of: .day, in: .month, for: start)?.count ?? 0
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let grouped = Dictionary(grouping: probe.moodEvents) { calendar.startOfDay(for: $0.time) }
        let weekdays = ["日", "一", "二", "三", "四", "五", "六"]
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button { month = calendar.date(byAdding: .month, value: -1, to: start) ?? month } label: { Image(systemName: "chevron.left") }.accessibilityLabel("上个月")
                Spacer()
                Text(month.formatted(.dateTime.year().month())).font(.headline)
                Spacer()
                Button { month = calendar.date(byAdding: .month, value: 1, to: start) ?? month } label: { Image(systemName: "chevron.right") }.accessibilityLabel("下个月")
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7)) {
                ForEach(0..<7, id: \.self) { index in
                    Text(weekdays[(index + calendar.firstWeekday - 1) % 7]).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(0..<(leading + days), id: \.self) { index in
                    if index < leading {
                        Color.clear.frame(height: 46)
                    } else if let date = calendar.date(byAdding: .day, value: index - leading, to: start) {
                        let key = calendar.startOfDay(for: date)
                        let emoji = grouped[key]?.compactMap { probe.mood(for: $0)?.emoji ?? $0.automaticMood?.emoji }.first
                        Button { day = date } label: {
                            VStack(spacing: 1) {
                                Text("\(index - leading + 1)").font(.subheadline.monospacedDigit())
                                Text(emoji ?? (grouped[key] == nil ? " " : "•")).font(.caption)
                            }.frame(maxWidth: .infinity, minHeight: 46)
                                .background(calendar.isDate(day, inSameDayAs: date) ? Color.teal.opacity(0.17) : .clear,
                                            in: RoundedRectangle(cornerRadius: 9))
                        }.buttonStyle(.plain)
                    }
                }
            }
            Text(day.formatted(date: .abbreviated, time: .omitted)).font(.headline)
            let entries = grouped[calendar.startOfDay(for: day)] ?? []
            if entries.isEmpty { Text("当天还没有记录").foregroundStyle(.secondary) }
            ForEach(entries) { event in eventRow(event) }
        }
    }

    private var map: some View {
        let positions = probe.entries.filter { $0.position != nil && $0.eventID != nil }
        let points = positions.compactMap(\.position)
        let minLat = points.map(\.latitude).min() ?? 0
        let minLon = points.map(\.longitude).min() ?? 0
        let height = max((points.map(\.latitude).max() ?? 0) - minLat, 0.01)
        let width = max((points.map(\.longitude).max() ?? 0) - minLon, 0.01)
        return VStack(alignment: .leading, spacing: 14) {
            Text("情绪地图").font(.headline)
            if positions.isEmpty {
                Text("记录带位置的事件后，在这里查看。").foregroundStyle(.secondary)
            } else {
                GeometryReader { proxy in
                    ZStack {
                        Path { path in
                            for i in 1..<5 {
                                let x = proxy.size.width * Double(i) / 5
                                let y = proxy.size.height * Double(i) / 5
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: proxy.size.width, y: y))
                            }
                        }.stroke(.teal.opacity(0.17))
                        ForEach(positions) { item in
                            if let point = item.position, let event = probe.moodEvents.first(where: { $0.id == item.eventID }) {
                                Button { mapped = event } label: {
                                    Text(probe.mood(for: event)?.emoji ?? "📍").font(.title2)
                                }.buttonStyle(.plain).accessibilityLabel(event.detail)
                                    .position(x: 24 + (proxy.size.width - 48) * (point.longitude - minLon) / width,
                                              y: 24 + (proxy.size.height - 48) * (1 - (point.latitude - minLat) / height))
                            }
                        }
                    }
                }.frame(height: 245).background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                Text("北 ↑ · 按本机坐标绘制").font(.footnote).foregroundStyle(.secondary)
                if let mapped { eventRow(mapped) }
            }
        }
    }

    private func eventRow(_ event: Entry) -> some View {
        let mood = probe.mood(for: event)
        let estimate = event.automaticMood
        let estimatedTitle = estimate.map { "\($0.emoji) \($0.label)" }
        let title = mood?.title ?? estimatedTitle ?? "待确认"
        let time = event.time.formatted(date: .omitted, time: .shortened)
        let summary: String
        if let estimate {
            summary = mood == nil ? "自动推测 · \(estimate.confidence)" : "已确认 · 原推测 \(estimate.label)"
        } else {
            summary = event.detail
        }
        let matchingClip = probe.entries.first { clip in
            guard let duration = clip.recordingDuration else { return false }
            return (0..<duration).contains(event.time.timeIntervalSince(clip.time))
        }
        return VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text("\(time) · \(summary)").font(.subheadline)
            if let bpm = event.physiology?.bpm { Text("心率 \(Int(bpm)) bpm").font(.caption).foregroundStyle(.secondary) }
            if let matchingClip {
                Button("播放当时的录音") {
                    audio.play(matchingClip, from: event.time.timeIntervalSince(matchingClip.time))
                }
            }
            if let reason = estimate?.reason { Text(reason).font(.caption) }
            if let estimate {
                Text("原始推测 · " + estimate.label + " · " + estimate.confidence).font(.caption)
                ForEach(probe.entries.filter { $0.kind == "情绪反馈" && $0.eventID == event.id }) { feedback in
                    Text(feedback.time.formatted() + " · " + feedback.detail).font(.caption)
                }
                EstimateFeedback(probe: probe, event: event)
            }
            DisclosureGroup("补充或纠正") {
                MoodPicker { probe.feedback($0.rawValue, for: event) }
                Button("为此事件录音") { onRecord(event) }
            }
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
    }

    private var recordings: some View {
        let notes = probe.entries.filter { $0.audioName != nil }
        return VStack(alignment: .leading, spacing: 12) {
            if notes.isEmpty { Text("还没有录音。").foregroundStyle(.secondary) }
            if let message = audio.message { Text(message).font(.footnote) }
            ForEach(notes) { entry in
                VStack(alignment: .leading, spacing: 8) {
                    Text(entry.time.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                    Text(entry.detail).foregroundStyle(.secondary)
                    if let duration = entry.recordingDuration {
                        let end = entry.time.addingTimeInterval(duration)
                        Text("到 " + end.formatted(date: .omitted, time: .shortened)).font(.caption)
                        recordingEvents(for: entry, endingAt: end)
                    }
                    HStack {
                        Button("播放") { audio.play(entry) }
                        Button("停止") { audio.stopPlayback() }
                        Button("转成文字") { Task { await audio.transcribe(entry) } }.disabled(audio.transcribing)
                    }.buttonStyle(.bordered)
                    if let transcript = probe.entries.first(where: { $0.kind == "本地转写" && $0.eventID == entry.id }) {
                        Text(transcript.detail).textSelection(.enabled)
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.teal.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func recordingEvents(for clip: Entry, endingAt end: Date) -> some View {
        let events = probe.moodEvents.filter { (clip.time..<end).contains($0.time) }
        return ForEach(events) { event in
            let label = probe.mood(for: event)?.title ?? event.automaticMood?.label ?? "生理波动"
            let pulse = event.physiology?.bpm.map { " · \(Int($0)) bpm" } ?? ""
            let time = event.time.formatted(date: .omitted, time: .shortened)
            Button("\(time) · \(label)\(pulse)") {
                audio.play(clip, from: event.time.timeIntervalSince(clip.time))
            }.font(.caption)
        }
    }
}
#endif
