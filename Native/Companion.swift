import Foundation
import WatchConnectivity

@MainActor
final class Companion: NSObject, WCSessionDelegate {
    static let shared = Companion()
    private func outboxURL() throws -> URL {
        let directory = try Journal.directory().appendingPathComponent("CompanionOutbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var retry: Task<Void, Never>?
    private var retryDelay = 30
    private func scheduleRetry() {
        guard retry == nil else { return }
        let delay = retryDelay
        retryDelay = min(600, retryDelay * 2)
        retry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            self.retry = nil
            self.flush()
        }
    }

    func activate() {
        #if !targetEnvironment(simulator)
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
        #endif
    }

    func enqueue(_ entry: Entry) {
        #if !targetEnvironment(simulator)
        guard WCSession.isSupported(), let data = try? JSONEncoder().encode(entry) else { return }
        do {
            try data.write(to: outboxURL().appendingPathComponent(entry.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            flush()
            #if os(watchOS)
            let session = WCSession.default
            if entry.kind == "波动事件", session.activationState == .activated, session.isReachable {
                session.sendMessage(["entry": data], replyHandler: nil, errorHandler: nil)
            }
            #endif
        } catch {
            UserDefaults.standard.set("写入同步队列失败", forKey: "monitor-sync")
        }
        #endif
    }

    func flush() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        #if os(iOS)
        guard session.isPaired && session.isWatchAppInstalled else { return }
        #else
        guard session.isCompanionAppInstalled else { return }
        #endif
        let queued = Set(session.outstandingUserInfoTransfers.compactMap { $0.userInfo["entryID"] as? String })
        guard let directory = try? outboxURL(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let id = file.lastPathComponent
            guard !queued.contains(id), let data = try? Data(contentsOf: file) else { continue }
            session.transferUserInfo(["entryID": id, "entry": data])
        }
        #if os(watchOS)
        flushRecordings(session)
        #endif
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            if error != nil { UserDefaults.standard.set("会话激活失败", forKey: "monitor-sync") }
            self.flush()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        #if os(watchOS)
        if let id = userInfo["watchRecordingReceived"] as? String, UUID(uuidString: id) != nil {
            Task { @MainActor in
                if let url = Journal.audioURL(id + ".m4a"), FileManager.default.fileExists(atPath: url.path) {
                    do { try FileManager.default.removeItem(at: url) }
                    catch { return }
                }
                Journal.removeCaptureManifest(id, suffix: "ready")
                WatchCapture.shared.updatePendingCount()
            }
            return
        }
        #endif
        receiveEntry(userInfo)
    }

    #if os(watchOS)
    private func flushRecordings(_ session: WCSession) {
        let queued = Set(session.outstandingFileTransfers.compactMap { $0.file.metadata?["recordingID"] as? String })
        for manifest in (try? Journal.captureManifests(suffix: "ready")) ?? [] {
            let id = manifest.deletingPathExtension().lastPathComponent
            guard !queued.contains(id), let data = try? Data(contentsOf: manifest),
                  let clip = try? JSONDecoder().decode(Entry.self, from: data), clip.id == id,
                  let name = clip.recording, let url = Journal.audioURL(name),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            session.transferFile(url, metadata: ["recordingID": id, "recording": data])
        }
    }
    #endif

    #if os(iOS)
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let data = file.metadata?["recording"] as? Data,
              let clip = try? JSONDecoder().decode(Entry.self, from: data),
              clip.kind == "录音结束", clip.recording == clip.id + ".m4a",
              let duration = clip.recordingDuration, duration > 0, duration <= 910,
              let name = clip.recording, let destination = Journal.audioURL(name) else { return }
        let manager = FileManager.default
        do {
            if !manager.fileExists(atPath: destination.path) {
                do { try manager.moveItem(at: file.fileURL, to: destination) }
                catch { if !manager.fileExists(atPath: destination.path) { throw error } }
            }
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: destination.path)
            if try !Journal.contains(clip.id) { try Journal.write(clip) }
        } catch {
            // The watch keeps its copy until the file and its journal entry are safely stored here.
            return
        }
        session.transferUserInfo(["watchRecordingReceived": clip.id])
        Task { @MainActor in Probe.shared.didPersist(clip) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveEntry(message)
    }
    #endif

    private nonisolated func receiveEntry(_ payload: [String: Any]) {
        guard let data = payload["entry"] as? Data,
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return }
        Task { @MainActor in
            guard (try? Journal.contains(entry.id)) == false else { return }
            Probe.shared.receive(entry)
            UserDefaults.standard.set("收到记录 " + Date.now.formatted(), forKey: "monitor-sync")
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if error != nil {
            UserDefaults.standard.set("发送失败，保留待传记录 " + Date.now.formatted(), forKey: "monitor-sync")
            Task { @MainActor in self.scheduleRetry() }
            return
        }
        UserDefaults.standard.set("发送成功 " + Date.now.formatted(), forKey: "monitor-sync")
        guard let id = userInfoTransfer.userInfo["entryID"] as? String,
              UUID(uuidString: id) != nil else { return }
        Task { @MainActor in
            self.retryDelay = 30
            if let path = try? self.outboxURL().appendingPathComponent(id) {
                try? FileManager.default.removeItem(at: path)
            }
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.flush() }
    }
    #endif
}
