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
        } catch {
            // Leave the original journal entry intact even if it could not be queued.
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
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in self.flush() }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo["entry"] as? Data,
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else { return }
        Task { @MainActor in
            guard (try? Journal.contains(entry.id)) == false else { return }
            Probe.shared.receive(entry)
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard error == nil, let id = userInfoTransfer.userInfo["entryID"] as? String,
              UUID(uuidString: id) != nil else { return }
        Task { @MainActor in
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
