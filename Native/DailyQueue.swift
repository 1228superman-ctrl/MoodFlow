#if os(iOS)
import BackgroundTasks
import Foundation

struct SummaryInput: Codable, Sendable {
    let schema: Int
    let id: UUID
    let day: String
    let eventCount: Int
    let moodCounts: [String: Int]
    let averageBpm: Int?
    let averageHrv: Int?
    let sleepHours: Double?
}

struct SummaryResult: Codable {
    let schema: Int
    let id: UUID
    let day: String
    let status: String
    let summary: String?
    let reason: String?
}

struct SummaryJob: Codable, Identifiable {
    let input: SummaryInput
    let created: Date
    var result: SummaryResult?
    var id: UUID { input.id }
}

@MainActor enum DailyQueue {
    static let refreshIdentifier = "org.moodflow.validation.summary"

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func folder() throws -> URL {
        let url = try Journal.directory().appendingPathComponent("Summaries", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func jobs() throws -> [SummaryJob] {
        try FileManager.default.contentsOfDirectory(at: folder(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(SummaryJob.self, from: Data(contentsOf: $0)) }
            .sorted { $0.created > $1.created }
    }

    private static func save(_ job: SummaryJob) throws {
        let url = try folder().appendingPathComponent(job.id.uuidString + ".json")
        try JSONEncoder().encode(job).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func request(_ date: Date, entries: [Entry], repeatAnalysis: Bool) throws -> SummaryJob? {
        let target = day(date)
        if !repeatAnalysis, let existing = try jobs().first(where: { $0.input.day == target }) { return existing }
        let events = entries.filter { $0.isMoodEvent && day($0.time) == target }
        guard !events.isEmpty else { return nil }
        let labels = events.compactMap { event in
            entries.first(where: { $0.kind == "情绪反馈" && $0.eventID == event.id })
                .flatMap { Mood(rawValue: $0.detail)?.rawValue }
        }
        let realSamples = events.filter { !$0.detail.hasPrefix("模拟") }.compactMap(\.physiology)
        func average(_ values: [Double]) -> Int? {
            values.isEmpty ? nil : Int((values.reduce(0,+) / Double(values.count)).rounded())
        }
        let input = SummaryInput(schema: 1, id: UUID(), day: target, eventCount: events.count,
            moodCounts: Dictionary(grouping: labels, by: { $0 }).mapValues(\.count),
            averageBpm: average(realSamples.compactMap(\.bpm)), averageHrv: average(realSamples.compactMap(\.hrv)),
            sleepHours: realSamples.compactMap(\.sleepHours).first.map { ($0 * 10).rounded() / 10 })
        let job = SummaryJob(input: input, created: Date())
        try save(job)
        return job
    }

    @discardableResult
    static func enqueueDue(now: Date = Date()) -> Bool {
        schedule(now: now)
        let calendar = Calendar.current
        guard let cutoff = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now) else { return false }
        do {
            let entries = try Journal.entries()
            var knownDays = Set(try jobs().map(\.input.day))
            for event in entries where event.isMoodEvent && event.time <= now &&
                (!calendar.isDate(event.time, inSameDayAs: now) || now >= cutoff) {
                let key = day(event.time)
                if knownDays.insert(key).inserted {
                    _ = try request(event.time, entries: entries, repeatAnalysis: false)
                }
            }
            return true
        } catch { return false }
    }

    private static func schedule(now: Date) {
        guard let next = Calendar.current.nextDate(after: now,
            matching: DateComponents(hour: 23, minute: 59, second: 0), matchingPolicy: .nextTime) else { return }
        let request = BGAppRefreshTaskRequest(identifier: refreshIdentifier)
        request.earliestBeginDate = next
        try? BGTaskScheduler.shared.submit(request)
    }

    static func importResult(_ data: Data) throws {
        guard data.count <= 100_000 else { throw CocoaError(.fileReadCorruptFile) }
        let result = try JSONDecoder().decode(SummaryResult.self, from: data)
        guard result.schema == 1,
              var job = try jobs().first(where: { $0.id == result.id && $0.input.day == result.day }),
              (result.status == "completed" && !(result.summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && result.reason == nil)
              || (result.status == "failed" && result.summary == nil && ["usage_limit", "authorization", "offline", "other"].contains(result.reason ?? "")) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if job.result?.status == "completed" { return }
        job.result = result
        try save(job)
    }
}
#endif
