import Foundation

enum PhoneVariationNotice {
    static func canSend(_ entry: Entry, after last: Date?, now: Date = .now) -> Bool {
        guard entry.kind == "波动事件", !entry.detail.hasPrefix("模拟"),
              (0...300).contains(now.timeIntervalSince(entry.time)) else { return false }
        return last.map { entry.time.timeIntervalSince($0) >= 600 } ?? true
    }
}
