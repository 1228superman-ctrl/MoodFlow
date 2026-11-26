import Foundation
import Combine
import WatchConnectivity

@MainActor
final class Companion: NSObject, ObservableObject, WCSessionDelegate {
    static let shared = Companion()
    private nonisolated static func outboxURL() throws -> URL {
        let directory = try Journal.directory().appendingPathComponent("CompanionOutbox", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private var retry: Task<Void, Never>?
    private var retryDelay = 30
    #if os(watchOS)
    @Published private(set) var pendingEntries = 0
    private var statusTask: Task<Void, Never>?
    private var sentAt: [String: Date] = [:]

    private func refreshPendingEntries() {
        statusTask?.cancel()
        statusTask = Task {
            let count = await Task.detached(priority: .utility) {
                guard let folder = try? Self.outboxURL() else { return 0 }
                return ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
                    .filter { UUID(uuidString: $0) != nil }.count
            }.value
            if !Task.isCancelled, pendingEntries != count { pendingEntries = count }
        }
    }

    func retryNow() {
        retry?.cancel()
        retry = nil
        retryDelay = 30
        sentAt.removeAll(keepingCapacity: true)
        flush()
    }

    private func waitingForReceipt(_ id: String) -> Bool {
        guard let last = sentAt[id], Date.now.timeIntervalSince(last) < 120 else { return false }
        scheduleRetry()
        return true
    }

    private func confirm(_ id: String, recording: Bool) {
        guard UUID(uuidString: id) != nil else { return }
        do {
            if recording {
                guard let url = Journal.audioURL(id + ".m4a"), ((try? Journal.captureManifests(suffix: "ready")) ?? [])
                    .contains(where: { $0.deletingPathExtension().lastPathComponent == id }) else { return }
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                Journal.removeCaptureManifest(id, suffix: "ready")
                WatchCapture.shared.updatePendingCount()
            } else {
                let url = try Self.outboxURL().appendingPathComponent(id)
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                try FileManager.default.removeItem(at: url)
                refreshPendingEntries()
            }
            sentAt[id] = nil
            retryDelay = 30
            UserDefaults.standard.set(Date.now.timeIntervalSince1970,
                forKey: recording ? "monitor-watch-audio-receipt" : "monitor-watch-entry-receipt")
            UserDefaults.standard.set("iPhone 已确认收到 " + Date.now.formatted(), forKey: "monitor-sync")
        } catch {
            UserDefaults.standard.set("收到确认，清理待传文件失败", forKey: "monitor-sync")
            scheduleRetry()
        }
    }
    #endif

    private func scheduleRetry() {
        guard retry == nil else { return }
        let delay = retryDelay
        retryDelay = min(600, retryDelay * 2)
        retry = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
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
            try data.write(to: Self.outboxURL().appendingPathComponent(entry.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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

    #if os(watchOS)
    func enqueueSelection(_ entries: [Entry]) {
        #if !targetEnvironment(simulator)
        guard !entries.isEmpty, WCSession.isSupported() else { return }
        Task {
            do {
                try await Task.detached(priority: .utility) {
                    let directory = try Self.outboxURL()
                    let encoder = JSONEncoder()
                    for entry in entries {
                        try encoder.encode(entry).write(to: directory.appendingPathComponent(entry.id),
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    }
                }.value
            } catch {
                UserDefaults.standard.set("写入同步队列失败", forKey: "monitor-sync")
            }
            flush()
        }
        #endif
    }
    #endif

    func flush() {
        #if os(watchOS)
        refreshPendingEntries()
        #endif
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        let session = WCSession.default
        #if os(iOS)
        guard session.isPaired && session.isWatchAppInstalled else { return }
        #else
        guard session.isCompanionAppInstalled else { return }
        #endif
        let queued = Set(session.outstandingUserInfoTransfers.compactMap { $0.userInfo["entryID"] as? String })
        guard let directory = try? Self.outboxURL(),
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            let id = file.lastPathComponent
            guard UUID(uuidString: id) != nil, !queued.contains(id) else { continue }
            #if os(watchOS)
            guard !waitingForReceipt(id) else { continue }
            #endif
            guard let data = try? Data(contentsOf: file) else { continue }
            #if os(watchOS)
            session.transferUserInfo(["entryID": id, "entry": data, "requiresPhoneReceipt": true])
            #else
            session.transferUserInfo(["entryID": id, "entry": data])
            #endif
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
            Task { @MainActor in self.confirm(id, recording: true) }
            return
        }
        if let id = userInfo["watchEntryReceived"] as? String, UUID(uuidString: id) != nil {
            Task { @MainActor in self.confirm(id, recording: false) }
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
            guard !queued.contains(id), !waitingForReceipt(id), let data = try? Data(contentsOf: manifest),
                  let clip = try? JSONDecoder().decode(Entry.self, from: data), clip.id == id,
                  let name = clip.recording, let url = Journal.audioURL(name),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            session.transferFile(url, metadata: ["recordingID": id, "recording": data])
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        guard let id = fileTransfer.file.metadata?["recordingID"] as? String else { return }
        let succeeded = error == nil
        Task { @MainActor in
            guard ((try? Journal.captureManifests(suffix: "ready")) ?? []).contains(where: {
                $0.deletingPathExtension().lastPathComponent == id
            }) else { return }
            if succeeded { self.sentAt[id] = .now }
            UserDefaults.standard.set(succeeded ? "录音已发出，等待 iPhone 确认" : "录音发送失败，原件待重试",
                forKey: "monitor-sync")
            self.scheduleRetry()
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
        if session.activationState == .activated { session.transferUserInfo(["watchRecordingReceived": clip.id]) }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "monitor-phone-last-receipt")
        Task { @MainActor in Probe.shared.didPersist(clip) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        receiveEntry(message)
    }
    #endif

    private nonisolated func receiveEntry(_ payload: [String: Any]) {
        guard let data = payload["entry"] as? Data,
              let entry = try? JSONDecoder().decode(Entry.self, from: data),
              UUID(uuidString: entry.id) != nil else { return }
        let receipt = payload["requiresPhoneReceipt"] as? Bool == true && (payload["entryID"] as? String) == entry.id
        Task { @MainActor in
            guard let exists = try? Journal.contains(entry.id) else { return }
            if !exists {
                guard Probe.shared.receive(entry) else { return }
                UserDefaults.standard.set("收到记录 " + Date.now.formatted(), forKey: "monitor-sync")
                #if os(iOS)
                UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: "monitor-phone-last-receipt")
                #endif
            }
            #if os(iOS)
            let session = WCSession.default
            if receipt, session.activationState == .activated,
               !session.outstandingUserInfoTransfers.contains(where: { ($0.userInfo["watchEntryReceived"] as? String) == entry.id }) {
                session.transferUserInfo(["watchEntryReceived": entry.id])
            }
            #endif
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        if error != nil {
            UserDefaults.standard.set("发送失败，保留待传记录 " + Date.now.formatted(), forKey: "monitor-sync")
            Task { @MainActor in self.scheduleRetry() }
            return
        }
        guard let id = userInfoTransfer.userInfo["entryID"] as? String,
              UUID(uuidString: id) != nil else { return }
        Task { @MainActor in
            #if os(watchOS)
            if let path = try? Self.outboxURL().appendingPathComponent(id), FileManager.default.fileExists(atPath: path.path) {
                self.sentAt[id] = .now
                UserDefaults.standard.set("记录已发出，等待 iPhone 确认", forKey: "monitor-sync")
                self.scheduleRetry()
            }
            #else
            UserDefaults.standard.set("发送成功 " + Date.now.formatted(), forKey: "monitor-sync")
            self.retryDelay = 30
            if let path = try? Self.outboxURL().appendingPathComponent(id) {
                try? FileManager.default.removeItem(at: path)
            }
            #endif
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
