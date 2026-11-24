import Foundation

enum MoodEstimate {
    private static func isMeasuredVariation(_ entry: Entry) -> Bool {
        entry.kind == "波动事件" && !entry.detail.hasPrefix("模拟") && entry.physiology?.delta?.isFinite == true
    }

    static func suggestion(for event: Entry, entries: [Entry]) -> Mood? {
        guard isMeasuredVariation(event), let delta = event.physiology?.delta, delta != 0 else { return nil }
        let labels = feedbackLabels(entries)
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
        return majority(similar.map { $0.0 })
    }

    static func watchFace(entries: [Entry], now: Date = .now) -> MoodFaceSnapshot? {
        var latest: (entry: Entry, date: Date)?
        for entry in entries {
            let variation = isMeasuredVariation(entry)
            guard variation || isMeasuredSample(entry) else { continue }
            guard let date = entry.physiology?.sampledAt ?? (variation ? entry.time : nil),
                  date <= now, now.timeIntervalSince(date) < MoodFaceSnapshot.freshFor else { continue }
            if let previous = latest {
                if date < previous.date { continue }
                if date == previous.date {
                    // Prefer a detected event, then keep the same source across repeated reads of a sample.
                    if isMeasuredVariation(previous.entry) { continue }
                    if !variation && entry.time >= previous.entry.time { continue }
                }
            }
            latest = (entry, date)
        }
        guard let (event, date) = latest, let physiology = event.physiology else { return nil }
        let labels = feedbackLabels(entries)
        let isVariation = isMeasuredVariation(event)
        let confirmed = labels[event.id] ?? entries.lazy
            .filter { $0.kind == "手动心情" && $0.eventID == event.id }
            .compactMap { labels[$0.id] }.first
        if let mood = confirmed {
            return MoodFaceSnapshot(eventID: event.id, date: date, emoji: mood.emoji, label: mood.rawValue, status: "已确认")
        }
        let estimate = isVariation ? suggestion(for: event, entries: entries) : sampleSuggestion(for: physiology, entries: entries, labels: labels)
        if let mood = estimate {
            return MoodFaceSnapshot(eventID: event.id, date: date, emoji: mood.emoji, label: "可能" + mood.rawValue, status: "自动判断")
        }
        let direction = trend(physiology, variation: isVariation)
        let display: (emoji: String, label: String) = switch direction {
        case .some(1): ("↑", "心率上升")
        case .some(-1): ("↓", "心率下降")
        case .some(0): ("→", "心率平稳")
        default: ("♡", "有近期心率")
        }
        return MoodFaceSnapshot(eventID: event.id, date: date, emoji: display.emoji, label: display.label, status: "待确认")
    }

    private static func isMeasuredSample(_ entry: Entry) -> Bool {
        guard entry.kind == "生理数据", !entry.detail.hasPrefix("模拟"), let pulse = entry.physiology?.bpm else { return false }
        return pulse.isFinite && pulse > 0
    }

    private static func trend(_ physiology: Physiology, variation: Bool = false) -> Int? {
        guard let delta = physiology.delta, delta.isFinite,
              variation || (1...900).contains(physiology.heartSampleInterval ?? 0) else { return nil }
        if abs(delta) <= 8 { return 0 }
        return delta > 0 ? 1 : -1
    }

    private static func sampleSuggestion(for sample: Physiology, entries: [Entry], labels: [String: Mood]) -> Mood? {
        guard let date = sample.sampledAt, let pulse = sample.bpm else { return nil }
        let direction = trend(sample)
        let similar = entries.compactMap { entry -> (date: Date, mood: Mood, distance: Double)? in
            guard entry.isMoodEvent, !entry.detail.hasPrefix("模拟"), let mood = labels[entry.id],
                  let prior = entry.physiology, let priorDate = prior.sampledAt, let priorPulse = prior.bpm,
                  entry.time <= date, priorDate < date, (0...600).contains(entry.time.timeIntervalSince(priorDate)),
                  abs(pulse - priorPulse) <= 10, trend(prior) == direction else { return nil }
            return (priorDate, mood, abs(pulse - priorPulse))
        }.sorted { $0.distance == $1.distance ? $0.date > $1.date : $0.distance < $1.distance }
        var seen = Set<Date>()
        return majority(similar.filter { seen.insert($0.date).inserted }.prefix(5).map { $0.mood })
    }

    private static func feedbackLabels(_ entries: [Entry]) -> [String: Mood] {
        var labels: [String: Mood] = [:]
        for feedback in entries where feedback.kind == "情绪反馈" {
            if let id = feedback.eventID, labels[id] == nil { labels[id] = Mood(rawValue: feedback.detail) }
        }
        return labels
    }

    private static func majority(_ labels: [Mood]) -> Mood? {
        guard labels.count >= 3 else { return nil }
        return Mood.allCases.first { mood in labels.filter { $0 == mood }.count * 3 >= labels.count * 2 }
    }
}
