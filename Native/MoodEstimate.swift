import Foundation

enum MoodEstimate {
    static func analysisID(_ sample: UUID) -> String {
        var bytes = sample.uuid
        bytes.0 ^= 0x80
        return UUID(uuid: bytes).uuidString
    }

    static func analyze(_ p: Physiology, history: [Entry]) -> AutomaticMood {
        func result(_ mood: Mood?, _ confidence: String, _ reason: String, significant: Bool = false) -> AutomaticMood {
            AutomaticMood(label: mood.map { "可能" + $0.rawValue } ?? "线索不足", emoji: mood?.emoji ?? "♡",
                confidence: confidence, reason: reason, meaningful: significant)
        }
        guard let bpm = p.bpm, bpm.isFinite, bpm > 0 else { return result(nil, "低把握", "缺少有效心率") }
        if p.asleep == true { return result(nil, "睡眠中", "样本处于已记录的睡眠时段") }
        if p.inMotion == true { return result(nil, "活动中", "活动期间心率变化可由运动引起") }
        let difference = p.typicalStillBPM.map { bpm - $0 }
        let threshold = max(10, (p.stillSpread ?? 5) * 2)
        let swing = p.trendBPM ?? ((p.heartSampleInterval ?? .infinity) <= 600 ? p.delta : nil)
        let elevated = (difference ?? 0) >= threshold
        let changing = abs(swing ?? 0) >= 10
        let confidence = p.inMotion == nil || p.hrvRelativeToUsual == nil ? "低把握" : "中等把握"
        if let learned = sampleSuggestion(for: p, entries: history, labels: feedbackLabels(history)) {
            return result(learned, confidence, "与你多次确认的相似生理状态一致", significant: elevated || changing)
        }
        if elevated, let ratio = p.hrvRelativeToUsual, ratio <= 0.8 {
            return result(.tense, confidence, "心率高于个人静止基线，近期 HRV 偏低", significant: true)
        }
        if changing || elevated {
            return result(nil, "低把握", "心率持续偏离或出现变化，情绪方向待确认", significant: true)
        }
        if let recovery = p.recoverySleep, recovery.hours < 5, let difference, difference < -threshold {
            return result(.tired, "低把握", "最近睡眠较短，静止心率低于个人基线")
        }
        if let difference, abs(difference) < threshold, let swing, abs(swing) < 8 {
            return result(.calm, "低把握", "近期心率平稳，接近个人静止基线")
        }
        return result(nil, "低把握", "缺少可比较的个人基线或趋势")
    }

    static func notificationReason(_ entry: Entry, previous: Entry?, now: Date) -> String? {
        guard (0...300).contains(now.timeIntervalSince(entry.time)) else { return "延迟样本，仅补记历史" }
        guard entry.analysis?.meaningful == true else { return "未达到变化提醒条件" }
        if let previous {
            let changed = previous.analysis?.label != entry.analysis?.label
            if entry.time.timeIntervalSince(previous.time) < (changed ? 180 : 1800) { return "近期已提醒" }
        }
        return nil
    }

    private static func isMeasuredVariation(_ entry: Entry) -> Bool {
        entry.kind == "波动事件" && !entry.detail.hasPrefix("模拟") && entry.physiology?.delta?.isFinite == true
    }

    static func suggestion(for event: Entry, entries: [Entry]) -> Mood? {
        guard isMeasuredVariation(event), let delta = event.physiology?.delta, delta != 0 else { return nil }
        let labels = feedbackLabels(entries)
        let measuredHRV = event.physiology?.hrv
        let similar = entries.compactMap { candidate -> (Mood, Double)? in
            guard isMeasuredVariation(candidate), candidate.time < event.time,
                  sameMotion(candidate.physiology, event.physiology),
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
        if let sample = entries.first(where: { $0.analysis != nil }),
           let analysis = sample.analysis,
           !entries.contains(where: { $0.kind == "手动心情" && $0.eventID == nil && $0.time > sample.time }) {
            guard (0..<MoodFaceSnapshot.freshFor).contains(now.timeIntervalSince(sample.time)) else { return nil }
            let id = sample.automaticMood == nil ? sample.eventID ?? sample.id : sample.id
            let corrected = feedbackLabels(entries)[id]
            let mood = corrected ?? Mood(rawValue: String(analysis.label.dropFirst(2)))
            return MoodFaceSnapshot(eventID: id, date: sample.time, emoji: corrected?.emoji ?? analysis.emoji,
                label: corrected?.rawValue ?? analysis.label, status: corrected == nil ? analysis.confidence : "已确认",
                appearance: mood?.appearance)
        }
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
        let labels = feedbackLabels(entries)
        if let manual = entries.first(where: {
            $0.kind == "手动心情" && $0.eventID == nil && labels[$0.id] != nil &&
            $0.time > (latest?.date ?? .distantPast) && (0..<MoodFaceSnapshot.freshFor).contains(now.timeIntervalSince($0.time))
        }), let mood = labels[manual.id] {
            return MoodFaceSnapshot(eventID: manual.id, date: manual.time, emoji: mood.emoji, label: mood.rawValue,
                status: "已确认", appearance: mood.appearance)
        }
        guard let (event, date) = latest, let original = event.physiology else { return nil }
        let isVariation = isMeasuredVariation(event)
        let confirmed = labels[event.id] ?? entries.lazy
            .filter { $0.automaticMood != nil && $0.eventID == event.id }
            .compactMap { labels[$0.id] }.first ?? entries.lazy
            .filter { $0.kind == "手动心情" && $0.eventID == event.id }
            .compactMap { labels[$0.id] }.first
        if let mood = confirmed {
            return MoodFaceSnapshot(eventID: event.id, date: date, emoji: mood.emoji, label: mood.rawValue, status: "已确认", appearance: mood.appearance)
        }
        // Keep the original tap target, while using updated estimates from later reads of the same sample.
        let current = entries.first { isMeasuredSample($0) && $0.physiology?.sampledAt == date }?.physiology
        let physiology = isVariation ? original : current ?? original
        let estimate = sampleSuggestion(for: physiology, entries: entries, labels: labels)
            ?? (isVariation ? suggestion(for: event, entries: entries) : nil)
        if let mood = estimate {
            return MoodFaceSnapshot(eventID: event.id, date: date, emoji: mood.emoji, label: "可能" + mood.rawValue, status: "个性推测", appearance: mood.appearance)
        }
        if let impression = initialImpression(physiology, variation: isVariation) {
            return MoodFaceSnapshot(eventID: event.id, date: date, emoji: impression.emoji,
                label: "可能" + impression.label, status: "低把握", appearance: impression.appearance)
        }
        return MoodFaceSnapshot(eventID: event.id, date: date, emoji: "♡", label: "情绪待判断",
            status: physiology.inMotion == true ? "活动中" : "线索不足")
    }

    private static func initialImpression(_ physiology: Physiology, variation: Bool) -> (emoji: String, label: String, appearance: MoodAppearance)? {
        guard physiology.inMotion != true else { return nil }
        let direction = trend(physiology, variation: variation)
        let aboveUsual = physiology.bpm.flatMap { pulse in physiology.typicalStillBPM.map { pulse - $0 } }
        if direction == 1 || (aboveUsual ?? 0) >= 10 {
            if let ratio = physiology.hrvRelativeToUsual, ratio <= 0.8 { return (Mood.tense.emoji, Mood.tense.rawValue, .tense) }
            return ("⚡", "激动", .bright)
        }
        if let aboveUsual, aboveUsual <= -10 { return nil }
        if direction == 0 || direction == -1 || aboveUsual.map({ abs($0) < 10 }) == true {
            return (Mood.calm.emoji, Mood.calm.rawValue, .calm)
        }
        return nil
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
                  sameMotion(prior, sample),
                  entry.time <= date, priorDate < date, (0...600).contains(entry.time.timeIntervalSince(priorDate)),
                  abs(pulse - priorPulse) <= 10, trend(prior) == direction else { return nil }
            return (priorDate, mood, abs(pulse - priorPulse))
        }.sorted { $0.distance == $1.distance ? $0.date > $1.date : $0.distance < $1.distance }
        var seen = Set<Date>()
        return majority(similar.filter { seen.insert($0.date).inserted }.prefix(5).map { $0.mood })
    }

    private static func sameMotion(_ first: Physiology?, _ second: Physiology?) -> Bool {
        (first?.inMotion == true) == (second?.inMotion == true)
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

extension Mood {
    var appearance: MoodAppearance {
        switch self {
        case .calm: .calm
        case .joyful, .excited: .bright
        case .tense: .tense
        case .low, .tired: .subdued
        }
    }
}
