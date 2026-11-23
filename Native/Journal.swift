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

    var isMoodEvent: Bool { kind == "波动事件" || kind == "手动心情" }
    var audioName: String? {
        if let recording { return recording }
        guard kind == "录音结束", let name = detail.split(separator: " ").last else { return nil }
        return name.hasSuffix(".m4a") ? String(name) : nil
    }
}

struct Physiology: Codable, Sendable, Equatable {
    var bpm: Double? = nil
    var delta: Double? = nil
    var hrv: Double? = nil
    var sleepHours: Double? = nil
    var stress: Int? {
        guard let bpm else { return nil }
        let pulseLoad = (bpm - 58) * 1.25
        let variationLoad = abs(delta ?? 0) * 0.7
        let variabilityAdjustment = (hrv ?? 40) * 0.25
        return asScore(pulseLoad + variationLoad - variabilityAdjustment)
    }
    var energy: Int? {
        guard let sleepHours else { return nil }
        let rest = sleepHours / 8 * 75
        let variability = min(hrv ?? 40, 80) / 4
        let load = Double(stress ?? 0) * 0.25
        return asScore(rest + variability - load)
    }

    private func asScore(_ value: Double) -> Int? {
        value.isFinite ? Int(min(100.0, max(0.0, value))) : nil
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
}
