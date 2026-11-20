import SwiftUI
import CoreLocation
#if os(iOS)
import UIKit
#else
import WatchKit
#endif

@MainActor
final class Probe: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = Probe()
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var writeError = false
    @Published private(set) var activeEvent: Entry?
    @Published var locationEnabled = false
    private lazy var location = CLLocationManager()
    private var locating: String?
    private var locationTimeout: Task<Void, Never>?
    var isActive = false

    func reload() {
        do { entries = try Journal.recent() }
        catch { writeError = true }
    }

    @discardableResult
    func add(_ entry: Entry) -> Bool {
        do {
            try Journal.write(entry)
            writeError = false
            reload()
            return true
        } catch {
            writeError = true
            return false
        }
    }

    func variation(id: String = UUID().uuidString, detail: String) {
        do { if try Journal.contains(id) { return } }
        catch { writeError = true; return }
        let event = Entry(id: id, kind: "波动事件", detail: detail)
        guard add(event) else { return }
        if isActive {
            activeEvent = event
            #if os(watchOS)
            WKInterfaceDevice.current().play(.click)
            #endif
        }
        if locationEnabled { locate(eventID: id) }
    }

    func feedback(_ label: String, for event: Entry) {
        if add(Entry(kind: "情绪反馈", detail: label, eventID: event.id)) {
            activeEvent = nil
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

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let fix = locations.last, fix.horizontalAccuracy >= 0,
              abs(fix.timestamp.timeIntervalSinceNow) <= 30 else {
            endLocation("无近期有效坐标")
            return
        }
        endLocation("\(fix.coordinate.latitude), \(fix.coordinate.longitude) · 精度约 \(Int(fix.horizontalAccuracy)) m")
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        endLocation("定位失败 · \((error as NSError).domain)/\((error as NSError).code)")
    }

    private func endLocation(_ result: String) {
        guard let eventID = locating else { return }
        locating = nil
        locationTimeout?.cancel()
        locationTimeout = nil
        add(Entry(kind: "定位结果", detail: result, eventID: eventID))
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

    var body: some Scene {
        WindowGroup {
            ProbeView(probe: probe)
                .onChange(of: phase, initial: true) { _, value in
                    probe.isActive = value == .active
                    if probe.isActive { probe.reload() }
                }
        }
    }
}

struct ProbeView: View {
    @ObservedObject var probe: Probe
    @State private var checkingHealth = false
    #if os(iOS)
    @StateObject private var audio = AudioProbe()
    @State private var confirmRecording = false
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("心绪 · 技术验证").font(.headline)
                #if MOODFLOW_SIM
                Text("模拟包 · 无 HealthKit 权限").font(.caption)
                #else
                Button("授权并读取健康样本", action: checkHealth).disabled(checkingHealth)
                Button("注册后台观察") {
                    Task { await HealthProbe.shared.register() }
                }.disabled(checkingHealth)
                #endif
                Toggle("前台事件定位", isOn: $probe.locationEnabled)
                    .onChange(of: probe.locationEnabled) { _, value in
                        if value { probe.configureLocation() }
                    }
                Button("注入模拟心率波动") {
                    probe.variation(detail: "模拟 · 68 → 95 bpm")
                }
                if let event = probe.activeEvent {
                    Text("这次感觉如何？").font(.caption)
                    Button("🙂 确认愉快") { probe.feedback("愉快", for: event) }
                    Button("😟 纠正为紧张") { probe.feedback("紧张", for: event) }
                    Button("😐 纠正为平静") { probe.feedback("平静", for: event) }
                }
                #if os(iOS)
                if audio.recording {
                    Button("停止录音", role: .destructive) { audio.stop() }
                } else {
                    Button("录音验证（最多 3 分钟）") { confirmRecording = true }
                        .disabled(audio.starting)
                }
                #endif
                if probe.writeError {
                    Text("本机记录写入或读取失败").foregroundStyle(.red)
                }
                Text("本机记录 · 最近 25 条").font(.headline)
                ForEach(probe.entries) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.kind + " · " + entry.time.formatted(date: .abbreviated, time: .standard))
                        Text(entry.detail)
                        Text(String((entry.eventID ?? entry.id).prefix(8))).foregroundStyle(.secondary)
                    }.font(.caption)
                }
            }.padding()
        }
        #if os(iOS)
        .confirmationDialog("请确认本次录音及在场者同意。音频只保存在本机，锁屏后可继续。", isPresented: $confirmRecording,
            titleVisibility: .visible) {
            Button("同意并开始录音") { Task { await audio.start() } }
            Button("取消", role: .cancel) {}
        }
        #endif
    }

    private func checkHealth() {
        #if !MOODFLOW_SIM
        checkingHealth = true
        Task {
            defer { checkingHealth = false }
            do {
                try await HealthProbe.shared.authorize()
                await HealthProbe.shared.readAll()
            } catch {
                probe.add(Entry(kind: "健康请求失败",
                    detail: "\((error as NSError).domain)/\((error as NSError).code)"))
            }
        }
        #endif
    }
}
