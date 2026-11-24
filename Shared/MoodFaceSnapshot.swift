import Foundation

enum MoodAppearance: String, Codable, Sendable {
    case neutral, calm, bright, tense, subdued
}

struct MoodFaceSnapshot: Codable, Equatable {
    static let kind = "MoodFlowWatchFace"
    static let group = "group.org.moodflow.validation.moodface"
    static let freshFor: TimeInterval = 30 * 60

    let eventID: String
    let date: Date
    let emoji: String
    let label: String
    let status: String
    var appearance: MoodAppearance? = nil

    var expires: Date { date.addingTimeInterval(Self.freshFor) }

    var link: URL {
        // The journal only supplies UUIDs, so the path cannot change the URL scheme or host.
        URL(string: "moodflow://mood/\(eventID)") ?? Self.recordLink
    }

    static let recordLink = URL(string: "moodflow://mood")!

    static var sharedFile: URL? {
        let components = Bundle.main.bundleIdentifier?.split(separator: ".") ?? []
        var groups = [group]
        // Personal-team signing suffixes the parent ID and app group with the team ID.
        if let watch = components.firstIndex(of: "watchkitapp"), watch == 4 {
            let team = components[3]
            if team.count == 10, team.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }) {
                groups.insert(group + "." + String(team), at: 0)
            }
        }
        return groups.lazy.compactMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
            .first?.appendingPathComponent("mood-face.json")
    }

    static func read() -> Self? {
        guard let file = sharedFile, let data = try? Data(contentsOf: file) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
