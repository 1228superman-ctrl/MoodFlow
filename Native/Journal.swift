import Foundation

struct Entry: Codable, Identifiable, Sendable {
    var id = UUID().uuidString
    var time = Date()
    let kind: String
    let detail: String
    var eventID: String? = nil
    var physiology: Physiology? = nil
    var position: EventPosition? = nil
    var recording: String? = nil
    var automaticMood: AutomaticMood? = nil
    var recordingDuration: TimeInterval? = nil

    var isMoodEvent: Bool { kind == "波动事件" || kind == "手动心情" || automaticMood != nil }
    var audioName: String? {
        if let recording { return recording }
        guard kind == "录音结束", let name = detail.split(separator: " ").last else { return nil }
        return name.hasSuffix(".m4a") ? String(name) : nil
    }
}

struct AutomaticMood: Codable, Sendable {
    let label: String
    let emoji: String
    let confidence: String
}

struct Physiology: Codable, Sendable, Equatable {
    var bpm: Double? = nil
    var delta: Double? = nil
    var hrv: Double? = nil
    var sleepHours: Double? = nil
    var sampledAt: Date? = nil
    var heartSampleInterval: TimeInterval? = nil
    var typicalStillBPM: Double? = nil
    var hrvRelativeToUsual: Double? = nil
    var inMotion: Bool? = nil
    var recoverySleep: RecoverySleep? = nil
    var activeKilocalories: Double? = nil
    var stress: Int? {
        guard let bpm else { return nil }
        let pulseLoad = (bpm - 58) * 1.25
        let variationLoad = abs(delta ?? 0) * 0.7
        let variabilityAdjustment = (hrv ?? 40) * 0.25
        return asScore(pulseLoad + variationLoad - variabilityAdjustment)
    }
    func energy(at date: Date = .now) -> Int? {
        guard let recoverySleep,
              (0...RecoverySleep.maximumAge).contains(date.timeIntervalSince(recoverySleep.end)) else { return nil }
        let rest = min(recoverySleep.hours / 8, 1) * 80
        let variability = hrv.map { min($0, 80) / 4 } ?? 0
        let awakeHours = date.timeIntervalSince(recoverySleep.end) / 3600
        let pulseLoad = sampledAt.map { (0...1800).contains(date.timeIntervalSince($0)) } == true
            ? Double(stress ?? 0) * 0.15 : 0
        return asScore(rest + variability - awakeHours * 0.8 - (activeKilocalories ?? 0) / 40 - pulseLoad)
    }

    private func asScore(_ value: Double) -> Int? {
        value.isFinite ? Int(min(100.0, max(0.0, value))) : nil
    }
}

struct RecoverySleep: Codable, Sendable, Equatable {
    static let maximumAge: TimeInterval = 36 * 3600
    let hours: Double
    let end: Date

    static func latest(in intervals: [DateInterval]) -> RecoverySleep? {
        var periods: [RecoverySleep] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.duration > 0 {
            if let previous = periods.last, interval.start.timeIntervalSince(previous.end) <= 3600 {
                let addedTime = max(0, interval.end.timeIntervalSince(max(interval.start, previous.end)))
                periods[periods.count - 1] = RecoverySleep(hours: previous.hours + addedTime / 3600,
                    end: max(interval.end, previous.end))
            } else {
                periods.append(RecoverySleep(hours: interval.duration / 3600, end: interval.end))
            }
        }
        return periods.last(where: { $0.hours >= 3 }) ?? periods.last
    }
}

struct EventPosition: Codable, Sendable {
    let latitude: Double
    let longitude: Double
    let accuracy: Double
}

enum Mood: String, CaseIterable, Identifiable {
    case joyful = "愉快", calm = "平静", excited = "兴奋", tense = "紧张", low = "低落", tired = "疲惫"

    var id: String { rawValue }
    var emoji: String {
        switch self {
        case .joyful: "😊"
        case .calm: "😌"
        case .excited: "✨"
        case .tense: "😟"
        case .low: "😔"
        case .tired: "😴"
        }
    }
    var title: String { emoji + " " + rawValue }
}

enum Journal {
    static func directory() throws -> URL {
        var folder = try FileManager.default.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("MoodFlowValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var options = URLResourceValues()
        options.isExcludedFromBackup = true
        try folder.setResourceValues(options)
        return folder
    }

    static func write(_ entry: Entry) throws {
        guard UUID(uuidString: entry.id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        let file = try directory().appendingPathComponent(entry.id + ".json")
        try JSONEncoder().encode(entry).write(to: file,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func contains(_ id: String) throws -> Bool {
        let file = try directory().appendingPathComponent(id + ".json")
        return FileManager.default.fileExists(atPath: file.path)
    }

    static func recent() throws -> [Entry] {
        Array(try entries().prefix(25))
    }

    static func entries() throws -> [Entry] {
        let files = try FileManager.default.contentsOfDirectory(at: directory(),
            includingPropertiesForKeys: nil)
        return files.filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
            .compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }.sorted { $0.time > $1.time }
    }

    static func audioURL(_ name: String) -> URL? {
        guard name.hasSuffix(".m4a"), UUID(uuidString: String(name.dropLast(4))) != nil else { return nil }
        return try? directory().appendingPathComponent(name)
    }

    static func captureManifests(suffix: String) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: captureDirectory(), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == suffix }
    }

    static func writeCaptureManifest(_ entry: Entry, suffix: String) throws {
        let url = try captureManifest(entry.id, suffix: suffix)
        try JSONEncoder().encode(entry).write(to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func removeCaptureManifest(_ id: String, suffix: String) {
        guard let url = try? captureManifest(id, suffix: suffix) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func captureDirectory() throws -> URL {
        let path = try directory().appendingPathComponent("WatchCapture", isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }

    private static func captureManifest(_ id: String, suffix: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw CocoaError(.fileWriteInvalidFileName) }
        return try captureDirectory().appendingPathComponent(id).appendingPathExtension(suffix)
    }
}
