#if os(watchOS)
import AVFoundation
import SwiftUI
import UserNotifications

@MainActor
final class WatchCapture: NSObject, ObservableObject, AVAudioRecorderDelegate {
    static let shared = WatchCapture()
    @Published private(set) var enabled = false
    @Published private(set) var isRecording = false
    @Published private(set) var starting = false
    @Published private(set) var startedAt: Date?
    @Published private(set) var message: String?
    @Published private(set) var pendingCount = 0

    private let session = AVAudioSession.sharedInstance()
    private var recorder: AVAudioRecorder?
    private var segment: Entry?
    private var interrupted = false
    private var interruptionObserver: NSObjectProtocol?

    private override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: nil
        ) { [weak self] notification in
            guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let canResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume)
            Task { @MainActor in self?.handleInterruption(type, canResume: canResume) }
        }
    }

    func start() async {
        guard !starting, !enabled else { return }
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission() else {
            message = "请在 Apple Watch 设置中允许心绪使用麦克风。"
            return
        }
        guard Probe.shared.isActive else { message = "请返回心绪后重新开始。"; return }
        enabled = true
        startedAt = .now
        resume()
        if !isRecording { stopAfterFailure(message ?? "录音未能开始，请重试。", alert: false) }
    }

    func resume() {
        guard enabled, !isRecording else { return }
        do {
            try session.setCategory(.playAndRecord)
            try session.setActive(true)
            try beginSegment()
            interrupted = false
            message = nil
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            message = "暂时无法录音，请检查麦克风、可用空间后重试。已保存的片段会保留。"
        }
    }

    func stop() {
        enabled = false
        startedAt = nil
        interrupted = false
        closeSegment()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        message = "录音已停止。"
    }

    func recoverFinishedSegments() {
        for url in (try? Journal.captureManifests(suffix: "open")) ?? [] {
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  entry.id != segment?.id else { continue }
            save(entry)
        }
        updatePendingCount()
    }

    func updatePendingCount() {
        pendingCount = ((try? Journal.captureManifests(suffix: "ready")) ?? []).count
    }

    private func beginSegment() throws {
        let id = UUID().uuidString
        let entry = Entry(id: id, kind: "录音结束", detail: "手表全天录音", recording: id + ".m4a")
        guard let name = entry.recording, let url = Journal.audioURL(name) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try Journal.writeCaptureManifest(entry, suffix: "open")
        do {
            let next = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 24000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32000
            ])
            next.delegate = self
            guard next.prepareToRecord() else { throw CocoaError(.fileWriteUnknown) }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
            guard next.record(forDuration: 900) else { throw CocoaError(.fileWriteUnknown) }
            recorder = next
            segment = entry
            isRecording = true
        } catch {
            try? FileManager.default.removeItem(at: url)
            Journal.removeCaptureManifest(id, suffix: "open")
            throw error
        }
    }

    private func closeSegment() {
        let previous = segment
        let active = recorder
        segment = nil
        recorder = nil
        isRecording = false
        active?.stop()
        if let previous { save(previous) }
    }

    private func save(_ entry: Entry) {
        guard let name = entry.recording, let url = Journal.audioURL(name) else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            Journal.removeCaptureManifest(entry.id, suffix: "open")
            return
        }
        // If an abrupt system exit left the container unfinished, keep the original for recovery.
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return }
        var ready = entry
        ready.recordingDuration = Double(file.length) / file.fileFormat.sampleRate
        do {
            try Journal.writeCaptureManifest(ready, suffix: "ready")
            Journal.removeCaptureManifest(entry.id, suffix: "open")
            updatePendingCount()
            Companion.shared.flush()
        } catch {
            message = "片段仍保存在手表上，稍后重试同步。"
        }
    }

    private func handleInterruption(_ type: AVAudioSession.InterruptionType, canResume: Bool) {
        guard enabled else { return }
        switch type {
        case .began:
            interrupted = true
            closeSegment()
            message = "录音因系统音频被打断，已保存上一段。"
        case .ended:
            guard interrupted else { return }
            interrupted = false
            if canResume { resume() }
            if !isRecording {
                message = "录音已暂停，返回心绪继续录音。"
                postPauseNotice()
            }
        @unknown default:
            break
        }
    }

    private func finishFromRecorder(_ url: URL, success: Bool) {
        guard recorder?.url == url, let previous = segment else { return }
        segment = nil
        recorder = nil
        isRecording = false
        defer { save(previous) }
        guard enabled, !interrupted else { return }
        guard success else {
            stopAfterFailure("录音已停止，请检查麦克风和可用空间。", alert: true)
            return
        }
        do { try beginSegment() }
        catch { stopAfterFailure("录音已停止，上一段会保留。请检查手表可用空间。", alert: true) }
    }

    private func stopAfterFailure(_ detail: String, alert: Bool) {
        stop()
        message = detail
        if alert { postPauseNotice() }
    }

    private func postPauseNotice() {
        guard Probe.shared.noticesEnabled, !Probe.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = "心绪录音已中断"
        content.body = "打开手表上的心绪查看录音状态。"
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "moodflow-watch-recording-interrupted", content: content, trigger: nil))
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor in self.finishFromRecorder(url, success: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor in
            guard self.recorder?.url == url else { return }
            self.stopAfterFailure("录音出错，已经保存的片段会保留。", alert: true)
        }
    }
}

struct WatchRecordingScreen: View {
    @ObservedObject var capture: WatchCapture
    @State private var confirming = false
    @AppStorage("monitor-watch-audio-receipt") private var lastReceipt = 0.0

    var body: some View {
        List {
            if capture.isRecording {
                Label("正在录音", systemImage: "mic.fill").foregroundStyle(.red)
                if let startedAt = capture.startedAt { Text(startedAt, style: .timer).monospacedDigit() }
            } else if capture.enabled {
                Button("继续录音") { capture.resume() }
            }
            if capture.enabled {
                Button("停止录音", role: .destructive) { capture.stop() }
            } else {
                Button("开启全天录音") { confirming = true }.disabled(capture.starting)
                Text("停止前持续录音。每 15 分钟保存一段并同步到配对 iPhone。")
                    .font(.footnote)
            }
            if capture.pendingCount > 0 {
                Text("\(capture.pendingCount) 段已保存在手表，等待同步").font(.footnote)
                Button("重试同步") { Companion.shared.retryNow() }
            }
            if lastReceipt > 0 {
                Text("iPhone 最近收到录音")
                    .font(.footnote)
                Text(Date(timeIntervalSince1970: lastReceipt).formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2)
            }
            if let message = capture.message { Text(message).font(.footnote) }
        }
        .navigationTitle("全天录音")
        .confirmationDialog("请先取得在场者同意。", isPresented: $confirming, titleVisibility: .visible) {
            Button("已获同意，开始录音") { Task { await capture.start() } }
            Button("取消", role: .cancel) {}
        }
    }
}
#endif
