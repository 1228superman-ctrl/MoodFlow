#if os(iOS)
import AVFoundation
import SwiftUI

@MainActor
final class AudioProbe: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var starting = false
    @Published private(set) var recording = false
    private var recorder: AVAudioRecorder?

    func start() async {
        guard !starting, !recording else { return }
        starting = true
        defer { starting = false }
        guard await AVAudioApplication.requestRecordPermission(), Probe.shared.isActive else {
            Probe.shared.add(Entry(kind: "录音未启动", detail: "需要麦克风权限和前台"))
            return
        }
        let session = AVAudioSession.sharedInstance()
        do {
            let file = try Journal.directory().appendingPathComponent(UUID().uuidString + ".m4a")
            try session.setCategory(.playAndRecord)
            try session.setActive(true)
            let newRecorder = try AVAudioRecorder(url: file, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 22050,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue
            ])
            newRecorder.delegate = self
            guard newRecorder.prepareToRecord() else {
                throw NSError(domain: "MoodFlowAudioPrepare", code: 1)
            }
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
            guard newRecorder.record(forDuration: 180) else {
                throw NSError(domain: "MoodFlowAudioStart", code: 1)
            }
            recorder = newRecorder
            recording = true
            Probe.shared.add(Entry(kind: "录音启动", detail: "前台确认 · 上限 180 秒"))
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            Probe.shared.add(Entry(kind: "录音失败", detail: "\((error as NSError).domain)/\((error as NSError).code)"))
        }
    }

    func stop() { recorder?.stop() }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor in self.finish(url, reportedSuccess: flag) }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor in
            guard self.recorder?.url == url else { return }
            self.recorder?.stop()
            self.finish(url, reportedSuccess: false)
        }
    }

    private func finish(_ url: URL, reportedSuccess: Bool) {
        guard recorder?.url == url else { return }
        let duration = (try? AVAudioPlayer(contentsOf: url).duration) ?? 0
        recorder = nil
        recording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        let seconds = duration.formatted(.number.precision(.fractionLength(1)))
        Probe.shared.add(Entry(kind: "录音结束",
            detail: "\(reportedSuccess ? "文件关闭" : "录制中断") · 可读时长 \(seconds) 秒 · \(url.lastPathComponent)"))
    }
}
#endif
