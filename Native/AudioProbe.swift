#if os(iOS)
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class AudioProbe: NSObject, ObservableObject, AVAudioRecorderDelegate {
    @Published private(set) var starting = false
    @Published private(set) var recording = false
    @Published private(set) var transcribing = false
    @Published private(set) var message: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var recordingEventID: String?

    func start(for event: Entry?) async {
        guard !starting, !recording else { return }
        if player != nil { stopPlayback() }
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
            recordingEventID = event?.id
            recording = true
            Probe.shared.add(Entry(kind: "录音启动", detail: "前台确认 · 上限 180 秒"))
        } catch {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            Probe.shared.add(Entry(kind: "录音失败", detail: "\((error as NSError).domain)/\((error as NSError).code)"))
        }
    }

    func stop() { recorder?.stop() }

    func play(_ entry: Entry, from offset: TimeInterval = 0) {
        guard !recording, let filename = entry.audioName, let url = Journal.audioURL(filename) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback)
            try AVAudioSession.sharedInstance().setActive(true)
            let next = try AVAudioPlayer(contentsOf: url)
            next.currentTime = min(max(0, offset), next.duration)
            player?.stop()
            guard next.play() else { throw CocoaError(.fileReadUnknown) }
            player = next
            message = "正在播放录音"
        } catch {
            message = "无法播放这段录音。"
        }
    }

    func stopPlayback() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        message = nil
    }

    func transcribe(_ entry: Entry) async {
        guard !transcribing, !recording, let filename = entry.audioName, let url = Journal.audioURL(filename) else { return }
        transcribing = true
        defer { transcribing = false }
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard authorization == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN")),
              recognizer.supportsOnDeviceRecognition else {
            message = "本机中文语音识别不可用，请检查语音识别权限和系统语音资源。"
            return
        }
        var chunks: [URL] = []
        defer { chunks.forEach { try? FileManager.default.removeItem(at: $0) } }
        do {
            let source = try AVAudioFile(forReading: url)
            let format = source.processingFormat
            let length = AVAudioFrameCount(format.sampleRate * 40)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: length) else {
                throw CocoaError(.fileReadUnknown)
            }
            while source.framePosition < source.length {
                try source.read(into: buffer, frameCount: length)
                guard buffer.frameLength > 0 else { break }
                let chunk = try Journal.directory().appendingPathComponent("segment-\(UUID().uuidString).caf")
                chunks.append(chunk)
                let output = try AVAudioFile(forWriting: chunk, settings: format.settings)
                try output.write(from: buffer)
            }
            var fragments: [String] = []
            for chunk in chunks { fragments.append(try await recognize(chunk, with: recognizer)) }
            let transcript = fragments.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else { throw CocoaError(.fileReadUnknown) }
            if Probe.shared.add(Entry(kind: "本地转写", detail: transcript, eventID: entry.id)) {
                message = "已保存转写"
            }
        } catch {
            message = "本地转写未完成，录音仍可播放。"
        }
    }

    private func recognize(_ url: URL, with recognizer: SFSpeechRecognizer) async throws -> String {
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        return try await withCheckedThrowingContinuation { continuation in
            let operation = SpeechSegment(continuation)
            operation.task = recognizer.recognitionTask(with: request) { result, error in
                let value = result?.isFinal == true ? result?.bestTranscription.formattedString : nil
                Task { @MainActor in
                    if let error { operation.complete(.failure(error)) }
                    else if let value { operation.complete(.success(value)) }
                }
            }
            operation.timeout = Task { @MainActor in
                try? await Task.sleep(for: .seconds(60))
                if !Task.isCancelled { operation.complete(.failure(URLError(.timedOut))) }
            }
        }
    }

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
            detail: "\(reportedSuccess ? "录音" : "中断录音") · \(seconds) 秒",
            eventID: recordingEventID, recording: url.lastPathComponent))
        recordingEventID = nil
    }
}

@MainActor private final class SpeechSegment {
    var task: SFSpeechRecognitionTask?
    var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<String, Error>?

    init(_ continuation: CheckedContinuation<String, Error>) { self.continuation = continuation }

    func complete(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        task?.cancel()
        task = nil
        continuation.resume(with: result)
    }
}
#endif
