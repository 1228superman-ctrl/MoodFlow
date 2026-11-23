import Foundation
import WatchConnectivity

@MainActor
final class Companion: NSObject, WCSessionDelegate {
    static let shared = Companion()
    private let key = "moodflow-companion-outbox"
    private var outbox: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
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
        outbox[entry.id] = data
        flush()
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
        for (id, data) in outbox where !queued.contains(id) {
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
            Probe.shared.add(entry, sync: false)
            Probe.shared.restorePendingEvent()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard error == nil, let id = userInfoTransfer.userInfo["entryID"] as? String else { return }
        Task { @MainActor in self.outbox.removeValue(forKey: id) }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.flush() }
    }
    #endif
}
