import SwiftUI
import WidgetKit

private struct MoodFaceEntry: TimelineEntry {
    let date: Date
    let mood: MoodFaceSnapshot?
}

private struct MoodFaceProvider: TimelineProvider {
    func placeholder(in context: Context) -> MoodFaceEntry { MoodFaceEntry(date: .now, mood: nil) }

    func getSnapshot(in context: Context, completion: @escaping (MoodFaceEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MoodFaceEntry>) -> Void) {
        let current = entry()
        let expiry = current.mood.map { MoodFaceEntry(date: $0.expires, mood: nil) }
        completion(Timeline(entries: [current] + (expiry.map { [$0] } ?? []), policy: .never))
    }

    private func entry() -> MoodFaceEntry {
        let now = Date()
        let snapshot = MoodFaceSnapshot.read().flatMap { $0.expires > now ? $0 : nil }
        return MoodFaceEntry(date: now, mood: snapshot)
    }
}

private struct MoodFaceView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MoodFaceEntry

    var body: some View {
        let mood = entry.mood
        Group {
            switch family {
            case .accessoryInline:
                Text(mood.map { $0.emoji + " " + $0.label } ?? "心绪 · 等待数据")
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text(mood.map { $0.emoji + " " + $0.label } ?? "心绪 · 等待数据")
                        .font(.headline).lineLimit(1).minimumScaleFactor(0.8)
                    if let mood {
                        HStack(spacing: 4) {
                            Text(mood.status)
                            Text(mood.date, style: .relative)
                        }.font(.caption2).lineLimit(1)
                    } else {
                        Text("轻点记录心情").font(.caption2)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryCorner:
                symbol(mood).widgetLabel { Text(mood?.label ?? "心绪") }
            default:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 1) {
                        symbol(mood)
                        if let mood { Text(mood.label).font(.system(size: 8)).lineLimit(1).minimumScaleFactor(0.75) }
                    }
                }
            }
        }
        .accessibilityLabel(mood.map { "\($0.label)，\($0.status)，轻点选择心情" } ?? "心绪等待数据，轻点记录心情")
        .privacySensitive()
        .widgetURL(mood?.link ?? MoodFaceSnapshot.recordLink)
        .containerBackground(.clear, for: .widget)
    }

    @ViewBuilder private func symbol(_ mood: MoodFaceSnapshot?) -> some View {
        if let mood { Text(mood.emoji).font(.title3).widgetAccentable() }
        else { Image(systemName: "face.smiling").font(.title3).widgetAccentable() }
    }
}

@main
struct MoodFaceWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: MoodFaceSnapshot.kind, provider: MoodFaceProvider()) { entry in
            MoodFaceView(entry: entry)
        }
        .configurationDisplayName("心绪 · 自动判断")
        .description("显示近期心情推测。轻点确认、纠正或记录心情。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
