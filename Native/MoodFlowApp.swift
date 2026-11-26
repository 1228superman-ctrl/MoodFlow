import SwiftUI
import CoreLocation
import UserNotifications
#if os(iOS)
import UIKit
#else
import WatchKit
import WidgetKit
#endif

@MainActor
final class Probe: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Probe()
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var writeError = false
    @Published private(set) var activeEvent: Entry?
    #if os(watchOS)
    @Published private(set) var displayedMood: MoodFaceSnapshot?
    #endif
    #if os(iOS)
    @Published private(set) var phoneNoticeSelection: UUID?
    private let lastPhoneNoticeKey = "last-phone-variation-notice"
    #endif
    @Published var locationEnabled = UserDefaults.standard.bool(forKey: "event-location") {
        didSet { UserDefaults.standard.set(locationEnabled, forKey: "event-location") }
    }
    @Published var noticesEnabled = UserDefaults.standard.bool(forKey: "event-notices") {
        didSet { UserDefaults.standard.set(noticesEnabled, forKey: "event-notices") }
    }
    private lazy var location = CLLocationManager()
    private var locating: String?
    private var locationTimeout: Task<Void, Never>?
    var isActive = false

    private var loadedHistory = false
    private var historyLoad: Task<Void, Never>?

    func loadHistoryIfNeeded() async {
        guard !loadedHistory else { return }
        if let historyLoad { await historyLoad.value; return }
        let task = Task { @MainActor in
            defer { historyLoad = nil }
            do {
                let history = try await Task.detached(priority: .utility) { try Journal.entries() }.value
                // A choice or synced entry can arrive while the disk snapshot is being read.
                let liveIDs = Set(entries.map(\.id))
                entries = (entries + history.filter { !liveIDs.contains($0.id) }).sorted { $0.time > $1.time }
                loadedHistory = true
                #if os(watchOS)
                updateWatchFace()
                #endif
            } catch { writeError = true }
        }
        historyLoad = task
        await task.value
    }

    func entryForInteraction(_ id: String) async -> Entry? {
        if let entry = entries.first(where: { $0.id == id }) { return entry }
        return await Task.detached(priority: .userInitiated) { try? Journal.read(id) }.value
    }

    func didPersist(_ entry: Entry) {
        if let old = entries.firstIndex(where: { $0.id == entry.id }) {
            entries.remove(at: old)
        }
        let index = entries.firstIndex { $0.time <= entry.time } ?? entries.endIndex
        entries.insert(entry, at: index)
        #if os(watchOS)
        updateWatchFace()
        #endif
    }

    @discardableResult
    func add(_ entry: Entry, sync: Bool = true) -> Bool {
        do {
            try Journal.write(entry)
            writeError = false
            didPersist(entry)
            if sync && (entry.isMoodEvent || ["情绪反馈", "定位结果", "生理数据"].contains(entry.kind)) {
                Companion.shared.enqueue(entry)
            }
            return true
        } catch {
            writeError = true
            return false
        }
    }

    var physiology: Physiology? {
        guard var current = entries.first(where: { $0.kind == "生理数据" })?.physiology else { return nil }
        if current.recoverySleep == nil, let previous = entries.lazy.compactMap(\.physiology).first(where: {
            $0.recoverySleep.map { (0...RecoverySleep.maximumAge).contains(Date.now.timeIntervalSince($0.end)) } ?? false
        }) {
            current.recoverySleep = previous.recoverySleep
            current.activeKilocalories = previous.activeKilocalories
        }
        return current
    }

    var moodEvents: [Entry] { entries.filter(\.isMoodEvent) }
    var lastMood: Mood? { entries.first(where: { $0.kind == "情绪反馈" }).flatMap { Mood(rawValue: $0.detail) } }

    func mood(for event: Entry) -> Mood? {
        entries.first { $0.kind == "情绪反馈" && $0.eventID == event.id }
            .flatMap { Mood(rawValue: $0.detail) }
    }

    func suggestion(for event: Entry) -> Mood? {
        event.automaticMood.flatMap { Mood(rawValue: String($0.label.dropFirst(2))) } ?? MoodEstimate.suggestion(for: event, entries: entries)
    }

    #if os(watchOS)
    func analyzeSamples(_ samples: [Entry]) {
        guard !samples.isEmpty else { return }
        var last = entries.first { $0.automaticMood != nil }
        var newestAlert: Entry?
        var saved: [Entry] = []
        let history = entries.filter { $0.isMoodEvent || $0.kind == "情绪反馈" }
        for source in samples {
            guard let physiology = source.physiology, (try? Journal.contains(source.id)) == false else { continue }
            let estimate = MoodEstimate.analyze(physiology, history: history)
            let elapsed = last.map { source.time.timeIntervalSince($0.time) } ?? .infinity
            let changed = last?.automaticMood?.label != estimate.label || last?.automaticMood?.confidence != estimate.confidence
            let crossedFreshBoundary = source.time.timeIntervalSinceNow >= -300 && (last?.time.timeIntervalSinceNow ?? 0) < -300
            let saveEvent = changed || elapsed >= 900 || elapsed < 0 || crossedFreshBoundary
            let entry = Entry(id: source.id, time: source.time, kind: saveEvent ? "自动推测" : "分析样本",
                detail: estimate.reason ?? "线索不足", eventID: saveEvent ? nil : last?.id, physiology: physiology,
                automaticMood: saveEvent ? estimate : nil, analysis: estimate, evaluatedAt: .now)
            do {
                try Journal.write(entry)
                saved.append(entry)
                if saveEvent {
                    last = entry
                    Companion.shared.enqueue(entry)
                    newestAlert = entry
                } else if newestAlert?.analysis?.label != estimate.label { newestAlert = nil }
            } catch { writeError = true; break }
        }
        if !saved.isEmpty {
            let savedIDs = Set(saved.map(\.id))
            entries = (entries.filter { !savedIDs.contains($0.id) } + saved).sorted { $0.time > $1.time }
            updateWatchFace()
        }
        if let newestAlert { Task { await self.notifyEstimate(newestAlert) } }
    }

    private func updateWatchFace() {
        let snapshot = MoodEstimate.watchFace(entries: entries)
        if displayedMood != snapshot { displayedMood = snapshot }
        guard var file = MoodFaceSnapshot.sharedFile, snapshot != MoodFaceSnapshot.read() else { return }
        do {
            if let snapshot {
                try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var metadata = URLResourceValues()
                metadata.isExcludedFromBackup = true
                try? file.setResourceValues(metadata)
            } else if MoodFaceSnapshot.read().map({ $0.expires > .now }) == true {
                try FileManager.default.removeItem(at: file)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: MoodFaceSnapshot.kind)
            for theme in MoodTheme.allCases {
                WidgetCenter.shared.reloadTimelines(ofKind: theme.widgetKind)
            }
        } catch {
            // The journal remains the source of truth. A later reload can retry the widget update.
        }
    }
    #endif

    func variation(id: String = UUID().uuidString, time: Date = Date(), detail: String, physiology: Physiology? = nil) {
        do { if try Journal.contains(id) { return } }
        catch { writeError = true; return }
        guard detail.hasPrefix("模拟") || !moodEvents.contains(where: {
            $0.kind == "波动事件" && $0.physiology?.delta != nil && !$0.detail.hasPrefix("模拟") && abs($0.time.timeIntervalSince(time)) < 600
        }) else { return }
        let event = Entry(id: id, time: time, kind: "波动事件", detail: detail, physiology: physiology)
        guard add(event) else { return }
        #if os(iOS)
        if isActive && detail.hasPrefix("模拟") { activeEvent = event }
        if event.detail.hasPrefix("模拟") { postPhoneNotice(for: event) }
        #else
        if isActive && detail.hasPrefix("模拟") {
            activeEvent = event
            WKInterfaceDevice.current().play(.click)
        } else if noticesEnabled && detail.hasPrefix("模拟") {
            let content = UNMutableNotificationContent()
            content.title = "有新的身体波动"
            content.body = "打开「心绪」记录此刻的感受。"
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
        #endif
        if locationEnabled { locate(eventID: id) }
    }

    func manual(_ mood: Mood, basedOn sample: Entry? = nil) {
        if let sample, let event = entries.first(where: { $0.kind == "手动心情" && $0.eventID == sample.id }) {
            feedback(mood.rawValue, for: event)
            return
        }
        let event = Entry(kind: "手动心情", detail: "自己记录", eventID: sample?.id,
            physiology: sample?.physiology ?? physiology)
        if add(event) { feedback(mood.rawValue, for: event) }
    }

    func receive(_ entry: Entry) {
        guard add(entry, sync: false) else { return }
        if entry.kind == "波动事件", entry.detail.hasPrefix("模拟"), abs(entry.time.timeIntervalSinceNow) < 120, isActive {
            #if os(iOS)
            if mood(for: entry) == nil, activeEvent.map({ $0.time < entry.time }) ?? true { activeEvent = entry }
            #else
            WKInterfaceDevice.current().play(.click)
            #endif
        }
        #if os(iOS)
        if entry.analysis != nil { Task { await self.notifyEstimate(entry) } }
        #endif
        restorePendingEvent()
    }

    #if os(iOS)
    private func postPhoneNotice(for event: Entry) {
        let defaults = UserDefaults.standard
        guard noticesEnabled,
              PhoneVariationNotice.canSend(event, after: defaults.object(forKey: lastPhoneNoticeKey) as? Date),
              mood(for: event) == nil else { return }
        defaults.set(event.time, forKey: lastPhoneNoticeKey)
        let content = UNMutableNotificationContent()
        content.title = "心绪提醒"
        content.body = "检测到一次波动，轻点确认当时的感受。"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
    }

    func openPhoneNotice(_ identifier: String) async {
        guard UUID(uuidString: identifier) != nil else { return }
        await loadHistoryIfNeeded()
        if let event = await entryForInteraction(identifier), event.kind == "波动事件", mood(for: event) == nil {
            activeEvent = event
        }
        phoneNoticeSelection = UUID()
    }
    #endif

    func restorePendingEvent() {
        if activeEvent == nil {
            activeEvent = moodEvents.first { $0.kind == "波动事件" && mood(for: $0) == nil }
        }
    }

    func selectEstimate(_ entry: Entry) {
        activeEvent = entry
        #if os(iOS)
        phoneNoticeSelection = UUID()
        #endif
    }

    func feedback(_ label: String, for event: Entry) {
        if add(Entry(kind: "情绪反馈", detail: label, eventID: event.id)) {
            if activeEvent?.id == event.id { activeEvent = nil }
            restorePendingEvent()
        }
    }

    func configureLocation() {
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if location.authorizationStatus == .notDetermined {
            location.requestWhenInUseAuthorization()
        }
    }

    private func locate(eventID: String) {
        let authorization = location.authorizationStatus
        guard isActive, authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            add(Entry(kind: "定位跳过", detail: "需要前台及定位权限", eventID: eventID))
            return
        }
        guard locating == nil else {
            add(Entry(kind: "定位跳过", detail: "已有定位请求", eventID: eventID))
            return
        }
        locating = eventID
        location.requestLocation()
        locationTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, locating == eventID else { return }
            location.stopUpdatingLocation()
            endLocation("定位超时")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0,
              abs(fix.timestamp.timeIntervalSinceNow) <= 30 else {
            Task { @MainActor in endLocation("无近期有效坐标") }
            return
        }
        let position = EventPosition(latitude: fix.coordinate.latitude, longitude: fix.coordinate.longitude,
            accuracy: fix.horizontalAccuracy)
        Task { @MainActor in endLocation("位置已保存 · 精度约 \(Int(position.accuracy)) m", position: position) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let result = "定位失败 · \((error as NSError).domain)/\((error as NSError).code)"
        Task { @MainActor in endLocation(result) }
    }

    private func endLocation(_ result: String, position: EventPosition? = nil) {
        guard let eventID = locating else { return }
        locating = nil
        locationTimeout?.cancel()
        locationTimeout = nil
        add(Entry(kind: "定位结果", detail: result, eventID: eventID, position: position))
    }
}

#if os(iOS)
@MainActor
final class LaunchDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        #if !MOODFLOW_SIM
        HealthProbe.shared.installObservers()
        #endif
        MonitorActions.install()
        Companion.shared.activate()
        return true
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse) async {
        if response.notification.request.content.categoryIdentifier.hasPrefix(MonitorActions.category) {
            await MonitorActions.respond(response)
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let identifier = response.notification.request.identifier
        await Probe.shared.openPhoneNotice(identifier)
    }
}
#else
@MainActor
final class LaunchDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MonitorActions.respond(response)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions { [.banner, .sound] }

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        #if !MOODFLOW_SIM
        HealthProbe.shared.installObservers()
        #endif
        MonitorActions.install()
        Companion.shared.activate()
    }
}
#endif

@main
struct MoodFlowApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(LaunchDelegate.self) private var delegate
    #else
    @WKApplicationDelegateAdaptor(LaunchDelegate.self) private var delegate
    #endif
    @Environment(\.scenePhase) private var phase
    @StateObject private var probe = Probe.shared
    #if targetEnvironment(simulator) && MOODFLOW_SIM
    @State private var ranSimulation = false
    #endif

    var body: some Scene {
        WindowGroup {
            rootView
                .onChange(of: phase, initial: true) { _, value in
                    probe.isActive = value == .active
                    if probe.isActive {
                        Task {
                            await probe.loadHistoryIfNeeded()
                            guard probe.isActive else { return }
                            probe.restorePendingEvent()
                            #if os(watchOS)
                            WatchCapture.shared.recoverFinishedSegments()
                            #endif
                            Companion.shared.flush()
                            #if !MOODFLOW_SIM
                            await HealthProbe.shared.readAll()
                            #endif
                            #if targetEnvironment(simulator) && MOODFLOW_SIM
                            runLaunchScenario()
                            #endif
                        }
                    }
                }
        }
        #if os(iOS)
        .backgroundTask(.appRefresh(DailyQueue.refreshIdentifier)) {
            _ = await DailyQueue.enqueueDue()
        }
        #endif
    }

    @ViewBuilder private var rootView: some View {
        #if os(iOS)
        PhoneHome(probe: probe)
        #else
        WatchHome(probe: probe)
        #endif
    }

    #if targetEnvironment(simulator) && MOODFLOW_SIM
    private func runLaunchScenario() {
        guard !ranSimulation else { return }
        ranSimulation = true
        let arguments = ProcessInfo.processInfo.arguments
        #if os(watchOS)
        if arguments.contains("--moodflow-ci-analyze") {
            let date = Date.now.addingTimeInterval(-3600)
            let sample = Entry(id: "529BC90D-5555-43A8-B159-D6B90EF3937B", time: date, kind: "分析样本", detail: "模拟",
                physiology: Physiology(bpm: 90, delta: 4, sampledAt: date, typicalStillBPM: 68,
                    hrvRelativeToUsual: 0.7, inMotion: false, trendBPM: 15))
            probe.analyzeSamples([sample, sample])
            return
        }
        #endif
        let label: String
        if arguments.contains("--moodflow-ci-confirm") {
            label = "愉快"
        } else if arguments.contains("--moodflow-ci-correct") {
            label = "紧张"
        } else {
            return
        }
        probe.variation(detail: "模拟 · 68 → 95 bpm", physiology: Physiology(bpm: 95, delta: 27, hrv: 38, sleepHours: 7))
        if let event = probe.activeEvent { probe.feedback(label, for: event) }
        #if os(iOS)
        if label == "愉快" {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
            DailyQueue.enqueueDue(now: tomorrow)
        } else {
            _ = try? DailyQueue.request(.now, entries: probe.entries, repeatAnalysis: true)
        }
        #endif
    }
    #endif
}
