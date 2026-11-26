import SwiftUI
import WidgetKit

private struct MoodFaceEntry: TimelineEntry {
    let date: Date
    let mood: MoodFaceSnapshot?
    var expired = false
}

private struct MoodFaceProvider: TimelineProvider {
    func placeholder(in context: Context) -> MoodFaceEntry { MoodFaceEntry(date: .now, mood: nil) }

    func getSnapshot(in context: Context, completion: @escaping (MoodFaceEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MoodFaceEntry>) -> Void) {
        let current = entry()
        let expiry = current.mood.map { MoodFaceEntry(date: $0.expires, mood: nil, expired: true) }
        completion(Timeline(entries: [current] + (expiry.map { [$0] } ?? []), policy: .never))
    }

    private func entry() -> MoodFaceEntry {
        let now = Date()
        let stored = MoodFaceSnapshot.read()
        let snapshot = stored.flatMap { $0.expires > now ? $0 : nil }
        return MoodFaceEntry(date: now, mood: snapshot, expired: stored != nil && snapshot == nil)
    }
}

private struct MoodFaceView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: MoodFaceEntry
    let theme: MoodTheme?

    var body: some View {
        let mood = entry.mood
        Group {
            switch family {
            case .accessoryInline:
                Text(mood.map { $0.emoji + " " + $0.label } ?? (entry.expired ? "心绪 · 数据过期" : "心绪 · 等待数据"))
            case .accessoryRectangular:
                if let theme {
                    themedRectangle(theme)
                } else {
                    rectangularText(alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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

    private func rectangularText(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(entry.mood.map { $0.emoji + " " + $0.label } ?? (entry.expired ? "心绪 · 数据过期" : "心绪 · 等待数据"))
                .font(.headline).lineLimit(1).minimumScaleFactor(0.72)
            if let mood = entry.mood {
                HStack(spacing: 4) {
                    Text(mood.status)
                    Text(mood.date, style: .relative)
                }.font(.caption2).lineLimit(1)
            } else {
                Text("轻点记录心情").font(.caption2)
            }
        }
    }

    private func themedRectangle(_ theme: MoodTheme) -> some View {
        let appearance = entry.mood?.appearance ?? .neutral
        let fullColor = renderingMode == .fullColor
        let textOnRight = theme == .ink
        let base = theme.colors(for: appearance).base

        return rectangularText(alignment: textOnRight ? .trailing : .leading)
            .foregroundStyle(fullColor ? theme.foreground : Color.primary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: textOnRight ? .trailing : .leading)
            .background {
                ZStack {
                    if fullColor {
                        MoodArtwork(theme: theme, mood: appearance)
                        LinearGradient(
                            stops: [
                                .init(color: base, location: 0),
                                .init(color: base.opacity(0.92), location: 0.30),
                                .init(color: base.opacity(0.60), location: 0.55),
                                .init(color: .clear, location: 0.83)
                            ],
                            startPoint: textOnRight ? .trailing : .leading,
                            endPoint: textOnRight ? .leading : .trailing
                        )
                    } else {
                        AccessoryWidgetBackground()
                        MoodArtwork(theme: theme, mood: appearance, compact: true)
                            .opacity(0.35)
                            .widgetAccentable()
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder private func symbol(_ mood: MoodFaceSnapshot?) -> some View {
        if let mood { Text(mood.emoji).font(.title3).widgetAccentable() }
        else { Image(systemName: "face.smiling").font(.title3).widgetAccentable() }
    }
}

private struct MoodFaceWidget: Widget {
    var theme: MoodTheme? = nil

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: theme?.widgetKind ?? MoodFaceSnapshot.kind, provider: MoodFaceProvider()) { entry in
            MoodFaceView(entry: entry, theme: theme)
        }
        .configurationDisplayName("心绪 · " + (theme?.title ?? "自动判断"))
        .description("显示近期心情推测。轻点确认、纠正或记录心情。")
        .supportedFamilies(theme == nil ? [.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner] : [.accessoryRectangular])
    }
}

@main
struct MoodFaceWidgets: WidgetBundle {
    var body: some Widget {
        MoodFaceWidget()
        MoodFaceWidget(theme: .sunrise)
        MoodFaceWidget(theme: .ink)
        MoodFaceWidget(theme: .contour)
    }
}
