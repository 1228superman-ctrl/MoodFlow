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
        precondition(MoodEstimate.watchFace(entries: [detected])?.status == "待确认")
        precondition(MoodEstimate.watchFace(entries: [detected] + history)?.label == "可能紧张")

        let falling = Entry(time: now, kind: "波动事件", detail: "心率下降", physiology: Physiology(delta: -24))
        precondition(MoodEstimate.watchFace(entries: [falling] + history)?.label == "心率下降")

        let feedback = Entry(time: now.addingTimeInterval(10), kind: "情绪反馈", detail: "兴奋", eventID: detected.id)
        let corrected = MoodEstimate.watchFace(entries: [feedback, detected] + history)
        precondition(corrected?.label == "兴奋" && corrected?.status == "已确认")
        precondition(corrected?.eventID == detected.id)

        let simulated = Entry(time: now, kind: "波动事件", detail: "模拟 · 心率上升", physiology: Physiology(delta: 24))
        precondition(MoodEstimate.watchFace(entries: [simulated]) == nil)
        print("PASS: measured variation, learned estimate, opposite signal, correction and simulation privacy")
    }
}
