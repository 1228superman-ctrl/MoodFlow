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
        precondition(MoodEstimate.watchFace(entries: [detected], now: now)?.status == "待确认")
        precondition(MoodEstimate.watchFace(entries: [detected] + history, now: now)?.label == "可能紧张")

        let falling = Entry(time: now, kind: "波动事件", detail: "心率下降", physiology: Physiology(delta: -24))
        precondition(MoodEstimate.watchFace(entries: [falling] + history, now: now)?.label == "心率下降")

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
        precondition(ordinary?.label == "心率平稳" && ordinary?.eventID == sample.id)
        precondition(ordinary?.date == sample.physiology?.sampledAt)
        precondition(MoodEstimate.watchFace(entries: [sample, detected], now: now)?.eventID == detected.id)
        let later = now.addingTimeInterval(MoodFaceSnapshot.freshFor)
        precondition(MoodEstimate.watchFace(entries: [sample, oldWave], now: later) == nil)

        var single = sample
        single.physiology?.heartSampleInterval = 3600
        precondition(MoodEstimate.watchFace(entries: [single], now: now)?.label == "有近期心率")
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
        precondition(MoodEstimate.watchFace(entries: [sample] + confirmedHistory, now: now)?.label == "可能平静")
        let duplicate = Array(confirmedHistory.prefix(2))
        precondition(MoodEstimate.watchFace(entries: [sample] + duplicate + duplicate + duplicate, now: now)?.label == "心率平稳")
        let linked = Entry(time: now, kind: "手动心情", detail: "自己记录", eventID: sample.id, physiology: sample.physiology)
        let correction = Entry(time: now, kind: "情绪反馈", detail: "紧张", eventID: linked.id)
        let repeated = Entry(time: now.addingTimeInterval(1), kind: sample.kind, detail: sample.detail, physiology: sample.physiology)
        let face = MoodEstimate.watchFace(entries: [repeated, correction, linked, sample] + confirmedHistory, now: now)
        precondition(face?.status == "已确认" && face?.label == "紧张" && face?.eventID == sample.id)
        print("PASS: ordinary and single samples, expiry, independent personalized labels and sample correction")
    }
}
