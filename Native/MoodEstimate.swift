import Foundation

enum MoodEstimate {
    private static func isMeasuredVariation(_ entry: Entry) -> Bool {
        entry.kind == "波动事件" && !entry.detail.hasPrefix("模拟") && entry.physiology?.delta?.isFinite == true
    }

    static func suggestion(for event: Entry, entries: [Entry]) -> Mood? {
        guard isMeasuredVariation(event), let delta = event.physiology?.delta, delta != 0 else { return nil }
        var labels: [String: Mood] = [:]
        for feedback in entries where feedback.kind == "情绪反馈" {
            if let id = feedback.eventID, labels[id] == nil { labels[id] = Mood(rawValue: feedback.detail) }
        }
        let measuredHRV = event.physiology?.hrv
        let similar = entries.compactMap { candidate -> (Mood, Double)? in
            guard isMeasuredVariation(candidate), candidate.time < event.time,
                  let prior = candidate.physiology?.delta, (prior > 0) == (delta > 0),
                  abs(prior - delta) <= 14, let label = labels[candidate.id] else { return nil }
            let hrvDistance = measuredHRV.flatMap { hrv in
                candidate.physiology?.hrv.map { min(abs($0 - hrv), 40) * 0.2 }
            } ?? 0
            return (label, abs(prior - delta) + (hrvDistance.isFinite ? hrvDistance : 0))
        }.sorted { $0.1 < $1.1 }.prefix(5)
        guard similar.count >= 3 else { return nil }
        return Mood.allCases.first { mood in similar.filter { $0.0 == mood }.count * 3 >= similar.count * 2 }
    }

    static func watchFace(entries: [Entry]) -> MoodFaceSnapshot? {
        guard let event = entries.first(where: isMeasuredVariation), let delta = event.physiology?.delta else { return nil }
        if let feedback = entries.first(where: { $0.kind == "情绪反馈" && $0.eventID == event.id }),
           let mood = Mood(rawValue: feedback.detail) {
            return MoodFaceSnapshot(eventID: event.id, date: event.time, emoji: mood.emoji, label: mood.rawValue, status: "已确认")
        }
        if let mood = suggestion(for: event, entries: entries) {
            return MoodFaceSnapshot(eventID: event.id, date: event.time, emoji: mood.emoji, label: "可能" + mood.rawValue, status: "自动判断")
        }
        return MoodFaceSnapshot(eventID: event.id, date: event.time, emoji: delta > 0 ? "↑" : "↓",
            label: delta > 0 ? "心率上升" : "心率下降", status: "待确认")
    }
}
