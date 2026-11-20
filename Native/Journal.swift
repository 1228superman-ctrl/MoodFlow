import Foundation

struct Entry: Codable, Identifiable {
    var id = UUID().uuidString
    var time = Date()
    let kind: String
    let detail: String
    var eventID: String? = nil
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
        let file = try directory().appendingPathComponent(entry.id + ".json")
        try JSONEncoder().encode(entry).write(to: file,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func contains(_ id: String) throws -> Bool {
        let file = try directory().appendingPathComponent(id + ".json")
        return FileManager.default.fileExists(atPath: file.path)
    }

    static func recent() throws -> [Entry] {
        let files = try FileManager.default.contentsOfDirectory(at: directory(),
            includingPropertiesForKeys: [.contentModificationDateKey])
        let dated = files.filter { $0.pathExtension == "json" }.map { file in
            (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(25).compactMap { file, _ in
            guard let data = try? Data(contentsOf: file) else { return nil }
            return try? JSONDecoder().decode(Entry.self, from: data)
        }
    }
}
