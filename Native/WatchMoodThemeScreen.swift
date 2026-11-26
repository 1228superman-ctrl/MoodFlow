#if os(watchOS)
import SwiftUI
import WatchKit

struct WatchMoodThemeScreen: View {
    @ObservedObject var probe: Probe
    let theme: MoodTheme
    @State private var editing = false
    @State private var eventID: String?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { timeline in
            let mood = probe.displayedMood.flatMap { $0.expires > max(timeline.date, .now) ? $0 : nil }
            let alignment: HorizontalAlignment = theme == .ink ? .trailing : .leading
            VStack(alignment: alignment) {
                Text(timeline.date, format: .dateTime.hour().minute())
                    .font(.system(.title2, design: .rounded).weight(.medium))
                    .monospacedDigit()
                    .minimumScaleFactor(0.6)
                    .accessibilityLabel("当前时间，\(timeline.date.formatted(date: .omitted, time: .shortened))")
                Spacer(minLength: 20)
                Button {
                    eventID = mood?.eventID
                    editing = true
                } label: {
                    VStack(alignment: alignment, spacing: 2) {
                        Text(mood.map { $0.emoji + " " + $0.label } ?? "等待数据")
                            .font(.title3.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.65)
                        Text(mood?.status ?? "轻点记录心情")
                            .font(.caption2).foregroundStyle(theme.foreground.opacity(0.76))
                    }
                    .frame(maxWidth: .infinity, alignment: theme == .ink ? .trailing : .leading)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("选择或纠正心情")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: theme == .ink ? .trailing : .leading)
            .foregroundStyle(theme.foreground)
            .background {
                MoodArtwork(theme: theme, mood: mood?.appearance ?? .neutral).ignoresSafeArea()
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $editing) { WatchMoodChoices(probe: probe, eventID: eventID) }
    }
}

struct WatchMoodChoices: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var probe: Probe
    let eventID: String?
    @State private var event: Entry?
    @State private var resolvedID: String?
    @State private var selectedMood: Mood?
    @State private var saveFailed = false

    var body: some View {
        NavigationStack {
            List {
                if let current = probe.displayedMood, current.eventID == event?.id, current.expires > .now {
                    Text("\(current.label) · \(current.status)").font(.footnote).foregroundStyle(.secondary)
                }
                if saveFailed {
                    Text("保存失败，请重试").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(Mood.allCases) { mood in
                    Button(mood.title) {
                        selectedMood = mood
                        saveFailed = false
                        Task {
                            if await probe.saveWatchSelection(mood, basedOn: event) {
                                WKInterfaceDevice.current().play(.success)
                                dismiss()
                            } else {
                                selectedMood = nil
                                saveFailed = true
                            }
                        }
                    }
                    .disabled(selectedMood != nil || (eventID != nil && resolvedID != eventID))
                    .overlay(alignment: .trailing) {
                        if selectedMood == mood { ProgressView().controlSize(.mini) }
                    }
                }
            }.navigationTitle(event == nil ? "此刻心情" : "确认或纠正")
        }
        .task(id: eventID) {
            guard let eventID else {
                event = nil
                resolvedID = nil
                return
            }
            let stored = await probe.entryForInteraction(eventID)
            guard !Task.isCancelled else { return }
            event = stored.flatMap { $0.isMoodEvent || $0.kind == "生理数据" ? $0 : nil }
            resolvedID = eventID
        }
    }
}
#endif
