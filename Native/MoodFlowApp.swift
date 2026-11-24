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

    func reload() {
        do {
            entries = try Journal.entries()
            writeError = false
            #if os(watchOS)
            updateWatchFace()
            #endif
        }
        catch { writeError = true }
    }

    @discardableResult
    func add(_ entry: Entry, sync: Bool = true) -> Bool {
        do {
            try Journal.write(entry)
            writeError = false
            reload()
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
        entries.first { $0.kind == "生理数据" }?.physiology
    }

    var moodEvents: [Entry] { entries.filter(\.isMoodEvent) }
    var lastMood: Mood? { entries.first(where: { $0.kind == "情绪反馈" }).flatMap { Mood(rawValue: $0.detail) } }

    func mood(for event: Entry) -> Mood? {
        entries.first { $0.kind == "情绪反馈" && $0.eventID == event.id }
            .flatMap { Mood(rawValue: $0.detail) }
    }

    func suggestion(for event: Entry) -> Mood? {
        MoodEstimate.suggestion(for: event, entries: entries)
    }

    #if os(watchOS)
    private func updateWatchFace() {
        let snapshot = MoodEstimate.watchFace(entries: entries)
        guard var file = MoodFaceSnapshot.sharedFile, snapshot != MoodFaceSnapshot.read() else { return }
        do {
            if let snapshot {
                try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                var metadata = URLResourceValues()
                metadata.isExcludedFromBackup = true
                try? file.setResourceValues(metadata)
            } else {
                try FileManager.default.removeItem(at: file)
            }
            WidgetCenter.shared.reloadTimelines(ofKind: MoodFaceSnapshot.kind)
        } catch {
            // The journal remains the source of truth. A later reload can retry the widget update.
        }
    }
    #endif

    func variation(id: String = UUID().uuidString, time: Date = Date(), detail: String, physiology: Physiology? = nil) {
        do { if try Journal.contains(id) { return } }
        catch { writeError = true; return }
        guard detail.hasPrefix("模拟") || !moodEvents.contains(where: {
            $0.physiology?.delta != nil && !$0.detail.hasPrefix("模拟") && abs($0.time.timeIntervalSince(time)) < 600
        }) else { return }
        let event = Entry(id: id, time: time, kind: "波动事件", detail: detail, physiology: physiology)
        guard add(event) else { return }
        if isActive {
            activeEvent = event
            #if os(watchOS)
            WKInterfaceDevice.current().play(.click)
            #endif
        } else if noticesEnabled {
            let content = UNMutableNotificationContent()
            content.title = "有新的身体波动"
            content.body = "打开「心绪」记录此刻的感受。"
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: event.id, content: content, trigger: nil))
        }
        if locationEnabled { locate(eventID: id) }
    }

    func manual(_ mood: Mood) {
        let event = Entry(kind: "手动心情", detail: "自己记录", physiology: physiology)
        if add(event) { feedback(mood.rawValue, for: event) }
    }

    func receive(_ entry: Entry) {
        guard add(entry, sync: false) else { return }
        if entry.kind == "波动事件", isActive, abs(entry.time.timeIntervalSinceNow) < 120 {
            #if os(watchOS)
            WKInterfaceDevice.current().play(.click)
            #endif
        }
        restorePendingEvent()
    }

    func restorePendingEvent() {
        if activeEvent == nil {
            activeEvent = moodEvents.first { $0.kind == "波动事件" && mood(for: $0) == nil }
        }
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
final class LaunchDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if !MOODFLOW_SIM
        HealthProbe.shared.installObservers()
        #endif
        Companion.shared.activate()
        return true
    }
}
#else
@MainActor
final class LaunchDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() {
        #if !MOODFLOW_SIM
        HealthProbe.shared.installObservers()
        #endif
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
                        probe.reload()
                        probe.restorePendingEvent()
                        Companion.shared.flush()
                        #if targetEnvironment(simulator) && MOODFLOW_SIM
                        runLaunchScenario()
                        #endif
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
