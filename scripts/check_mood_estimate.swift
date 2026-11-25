import Foundation

@main
enum EstimateChecks {
    static func main() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let detected = Entry(time: now, kind: "波动事件", detail: "心率上升", physiology: Physiology(delta: 24))
        let history = (1...3).flatMap { index in
            let past = Entry(time: now.addingTimeInterval(-Double(index) * 3600), kind: "波动事件",
                detail: "心率上升", physiology: Physiology(delta: Double(22 + index)))
            return [Entry(time: past.time.addingTimeInterval(20), kind: "情绪反馈", detail: "紧张", eventID: past.id), past]
        }
        precondition(MoodEstimate.watchFace(entries: [detected], now: now)?.status == "低把握")
        precondition(MoodEstimate.watchFace(entries: [detected] + history, now: now)?.label == "可能紧张")

        let falling = Entry(time: now, kind: "波动事件", detail: "心率下降", physiology: Physiology(delta: -24))
        precondition(MoodEstimate.watchFace(entries: [falling] + history, now: now)?.label == "可能平静")

        let feedback = Entry(time: now.addingTimeInterval(10), kind: "情绪反馈", detail: "兴奋", eventID: detected.id)
        let corrected = MoodEstimate.watchFace(entries: [feedback, detected] + history, now: now)
        precondition(corrected?.label == "兴奋" && corrected?.status == "已确认")
        precondition(corrected?.eventID == detected.id)

        let simulated = Entry(time: now, kind: "波动事件", detail: "模拟 · 心率上升", physiology: Physiology(delta: 24))
        precondition(MoodEstimate.watchFace(entries: [simulated], now: now) == nil)
        print("PASS: measured variation, learned estimate, opposite signal, correction and simulation privacy")

        let sample = Entry(time: now, kind: "生理数据", detail: "Apple 健康",
            physiology: Physiology(bpm: 71, delta: 3, sampledAt: now.addingTimeInterval(-60), heartSampleInterval: 240))
        let oldWave = Entry(time: now.addingTimeInterval(-120), kind: "波动事件", detail: "心率上升", physiology: Physiology(delta: 22))
        let ordinary = MoodEstimate.watchFace(entries: [oldWave, sample], now: now)
        precondition(ordinary?.label == "可能平静" && ordinary?.status == "低把握" && ordinary?.eventID == sample.id)
        precondition(ordinary?.date == sample.physiology?.sampledAt)
        precondition(MoodEstimate.watchFace(entries: [sample, detected], now: now)?.eventID == detected.id)
        let later = now.addingTimeInterval(MoodFaceSnapshot.freshFor)
        precondition(MoodEstimate.watchFace(entries: [sample, oldWave], now: later) == nil)

        var single = sample
        single.physiology?.heartSampleInterval = 3600
        precondition(MoodEstimate.watchFace(entries: [single], now: now)?.label == "情绪待判断")
        single.physiology?.typicalStillBPM = 70
        precondition(MoodEstimate.watchFace(entries: [single], now: now)?.label == "可能平静")
        var elevated = sample
        elevated.physiology?.typicalStillBPM = 58
        precondition(MoodEstimate.watchFace(entries: [elevated], now: now)?.label == "可能激动")
        elevated.physiology?.hrvRelativeToUsual = 0.7
        precondition(MoodEstimate.watchFace(entries: [elevated], now: now)?.label == "可能紧张")
        elevated.physiology?.inMotion = true
        precondition(MoodEstimate.watchFace(entries: [elevated], now: now)?.status == "活动中")
        var mock = Entry(time: now, kind: "生理数据", detail: "模拟", physiology: sample.physiology)
        precondition(MoodEstimate.watchFace(entries: [mock], now: now) == nil)
        mock = Entry(time: now, kind: "生理数据", detail: "Apple 健康", physiology: Physiology(bpm: 71))
        precondition(MoodEstimate.watchFace(entries: [mock], now: now) == nil)

        let confirmedHistory = (1...3).flatMap { index in
            let time = now.addingTimeInterval(-Double(index) * 3600)
            let record = Entry(time: time, kind: "手动心情", detail: "自己记录",
                physiology: Physiology(bpm: Double(70 + index), delta: 2, sampledAt: time, heartSampleInterval: 240))
            return [Entry(time: time, kind: "情绪反馈", detail: "平静", eventID: record.id), record]
        }
        precondition(MoodEstimate.watchFace(entries: [sample] + confirmedHistory, now: now)?.status == "个性推测")
        precondition(MoodEstimate.watchFace(entries: [elevated] + confirmedHistory, now: now)?.status == "活动中")
        let duplicate = Array(confirmedHistory.prefix(2))
        precondition(MoodEstimate.watchFace(entries: [sample] + duplicate + duplicate + duplicate, now: now)?.status == "低把握")
        let linked = Entry(time: now, kind: "手动心情", detail: "自己记录", eventID: sample.id, physiology: sample.physiology)
        let correction = Entry(time: now, kind: "情绪反馈", detail: "紧张", eventID: linked.id)
        let repeated = Entry(time: now.addingTimeInterval(1), kind: sample.kind, detail: sample.detail, physiology: sample.physiology)
        let face = MoodEstimate.watchFace(entries: [repeated, correction, linked, sample] + confirmedHistory, now: now)
        precondition(face?.status == "已确认" && face?.label == "紧张" && face?.eventID == sample.id)
        precondition(ordinary?.appearance == .calm && face?.appearance == .tense)
        let standalone = Entry(time: now, kind: "手动心情", detail: "自己记录")
        let selfReport = Entry(time: now, kind: "情绪反馈", detail: "愉快", eventID: standalone.id)
        let displayedReport = MoodEstimate.watchFace(entries: [selfReport, standalone, sample], now: now)
        precondition(displayedReport?.appearance == .bright && displayedReport?.eventID == standalone.id)
        precondition(MoodEstimate.watchFace(entries: [selfReport, standalone, sample], now: later) == nil)
        let automatic = Entry(time: now, kind: "自动推测", detail: "手表自动推测", eventID: sample.id,
            physiology: sample.physiology,
            automaticMood: AutomaticMood(label: "可能平静", emoji: "😌", confidence: "低把握"))
        let autoCorrection = Entry(time: now, kind: "情绪反馈", detail: "紧张", eventID: automatic.id)
        precondition(automatic.isMoodEvent)
        precondition(MoodEstimate.watchFace(entries: [autoCorrection, automatic, sample], now: now)?.label == "紧张")
        print("PASS: recent samples, calm/arousal/tension estimates, motion guard, expiry, personalized estimates and corrections")

        let night = DateInterval(start: now.addingTimeInterval(-15 * 3600), duration: 7 * 3600)
        let overlapping = DateInterval(start: night.start.addingTimeInterval(2 * 3600), duration: 3600)
        let nap = DateInterval(start: now.addingTimeInterval(-2 * 3600), duration: 30 * 60)
        let recovery = RecoverySleep.latest(in: [nap, overlapping, night])
        precondition(recovery?.hours == 7 && recovery?.end == night.end)
        var test = Physiology(bpm: 70, delta: 1, sampledAt: now, heartSampleInterval: 200, typicalStillBPM: 70, inMotion: false)
        func estimate(_ p: Physiology) -> AutomaticMood { MoodEstimate.analyze(p, history: []) }
        precondition(estimate(test).label == "可能平静")
        test.bpm = 91; test.delta = 21
        precondition(estimate(test).meaningful == true)
        test.delta = 2; test.trendBPM = 13
        precondition(estimate(test).meaningful == true)
        test.hrvRelativeToUsual = 0.72
        precondition(estimate(test).label == "可能紧张")
        test.inMotion = true
        precondition(estimate(test).label == "线索不足")
        test.inMotion = nil
        precondition(estimate(test).confidence == "低把握")
        test.hrvRelativeToUsual = nil; test.trendBPM = -13; test.bpm = 60
        precondition(estimate(test).meaningful == true)
        test.asleep = true
        precondition(estimate(test).confidence == "睡眠中")
        let alert = Entry(time: now, kind: "自动推测", detail: "合成测试", analysis: AutomaticMood(label: "可能紧张", emoji: "", confidence: "低把握", meaningful: true))
        precondition(MoodEstimate.notificationReason(alert, previous: nil, now: now) == nil)
        precondition(MoodEstimate.notificationReason(alert, previous: alert, now: now) != nil)
        precondition(MoodEstimate.notificationReason(alert, previous: nil, now: now.addingTimeInterval(360)) != nil)
        var similar = test
        similar.asleep = false; similar.bpm = 71; similar.delta = 2; similar.trendBPM = nil
        similar.inMotion = false; similar.heartSampleInterval = 240
        precondition(MoodEstimate.analyze(similar, history: confirmedHistory).label == "可能平静")
        let correctedHistory = confirmedHistory.map { row in
            row.kind == "情绪反馈" ? Entry(time: row.time, kind: row.kind, detail: "愉快", eventID: row.eventID) : row
        }
        precondition(MoodEstimate.analyze(similar, history: correctedHistory).label == "可能愉快")
        precondition(MoodEstimate.analyze(similar, history: Array(correctedHistory.prefix(2))).label != "可能愉快")
        let sampleUUID = UUID()
        precondition(MoodEstimate.analysisID(sampleUUID) == MoodEstimate.analysisID(sampleUUID))
        print("PASS: stationary, rapid/gradual rise, falling trend, HRV, motion, missing context, delayed and duplicate alerts")
        let baseline = Physiology(hrv: 40, recoverySleep: recovery)
        let afterActivity = Physiology(hrv: 40, recoverySleep: recovery, activeKilocalories: 400)
        precondition(baseline.energy(at: now) == 73 && afterActivity.energy(at: now) == 63)
        precondition(baseline.energy(at: now.addingTimeInterval(37 * 3600)) == nil)
        precondition(Physiology(bpm: 70, hrv: 40).energy(at: now) == nil)
        let oldData = Data(#"{"kind":"手动心情","detail":"自己记录","id":"05231DC0-F414-4938-A5AE-D909122D69F9","time":0,"physiology":{"sleepHours":7}}"#.utf8)
        let oldEntry = try! JSONDecoder().decode(Entry.self, from: oldData)
        precondition(oldEntry.isMoodEvent && oldEntry.automaticMood == nil && oldEntry.physiology?.sleepHours == 7)
        print("PASS: sleep overlap, recovery estimate, activity impact and legacy journal compatibility")

        precondition(PhoneVariationNotice.canSend(detected, after: nil, now: now))
        precondition(!PhoneVariationNotice.canSend(detected, after: now, now: now))
        precondition(!PhoneVariationNotice.canSend(oldWave, after: now, now: now))
        precondition(!PhoneVariationNotice.canSend(detected, after: now.addingTimeInterval(-599), now: now))
        precondition(PhoneVariationNotice.canSend(detected, after: now.addingTimeInterval(-600), now: now))
        precondition(!PhoneVariationNotice.canSend(detected, after: nil, now: now.addingTimeInterval(301)))
        precondition(!PhoneVariationNotice.canSend(simulated, after: nil, now: now))
        precondition(!PhoneVariationNotice.canSend(standalone, after: nil, now: now))
        print("PASS: mood artwork state and phone notice freshness, deduplication and sample exclusions")
    }
}
