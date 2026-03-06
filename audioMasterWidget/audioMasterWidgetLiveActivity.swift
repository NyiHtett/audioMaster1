import ActivityKit
import SwiftUI
import WidgetKit

struct audioMasterWidgetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: audioMasterWidgetAttributes.self) { context in
            VStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        RecordingBadgeView(state: context.state.recordingState)
                        Spacer()
                        Text(timerInterval: context.state.recordingStart...Date.distantFuture, countsDown: false)
                            .font(.caption.monospacedDigit())
                    }

                    Text(prettyDeviceName(context.state.inputDevice))
                        .font(.caption2)
                        .lineLimit(1)

                    Text("\(context.state.transcribedSegments)/\(context.state.totalSegments) segments")
                        .font(.caption2.bold())

                    IslandWaveformView(
                        heights: context.state.barHeights,
                        barCount: 16,
                        barWidth: 4,
                        barSpacing: 2,
                        minBarHeight: 4,
                        maxBarHeight: 22
                    )
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .activityBackgroundTint(.black)
            .activitySystemActionForegroundColor(.green)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    RecordingBadgeView(state: context.state.recordingState)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(timerInterval: context.state.recordingStart...Date.distantFuture, countsDown: false)
                        .font(.caption2.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(spacing: 6) {
                        Text(prettyDeviceName(context.state.inputDevice))
                            .font(.caption2)
                            .lineLimit(1)
                        IslandWaveformView(
                            heights: context.state.barHeights,
                            barCount: 20,
                            barWidth: 4,
                            barSpacing: 2,
                            minBarHeight: 4,
                            maxBarHeight: 26
                        )
                    }
                }
            } compactLeading: {
                Circle()
                    .fill(context.state.recordingState == "recording" ? Color.red : Color.yellow)
                    .frame(width: 10, height: 10)
            } compactTrailing: {
                Text(timerInterval: context.state.recordingStart...Date.distantFuture, countsDown: false)
                    .font(.caption2.monospacedDigit())
                    .frame(width: 40)
            } minimal: {
                Circle()
                    .fill(context.state.recordingState == "recording" ? Color.red : Color.yellow)
                    .frame(width: 10, height: 10)
            }
            .keylineTint(.red)
        }
    }
}

struct RecordingStatusWidget: Widget {
    let kind = "RecordingStatusWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: RecordingStatusProvider()) { entry in
            RecordingStatusWidgetView(entry: entry)
        }
        .configurationDisplayName("Recorder")
        .description("Shows recording status and quick actions")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct RecordingStatusEntry: TimelineEntry {
    let date: Date
    let isRecording: Bool
    let startedAt: Date?
}

struct RecordingStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> RecordingStatusEntry {
        RecordingStatusEntry(date: Date(), isRecording: true, startedAt: Date().addingTimeInterval(-120))
    }

    func getSnapshot(in context: Context, completion: @escaping (RecordingStatusEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RecordingStatusEntry>) -> Void) {
        let entry = currentEntry()
        let refresh = Date().addingTimeInterval(15)
        completion(Timeline(entries: [entry], policy: .after(refresh)))
    }

    private func currentEntry() -> RecordingStatusEntry {
        if let activity = Activity<audioMasterWidgetAttributes>.activities.first {
            return RecordingStatusEntry(
                date: Date(),
                isRecording: true,
                startedAt: activity.content.state.recordingStart
            )
        }
        return RecordingStatusEntry(date: Date(), isRecording: false, startedAt: nil)
    }
}

struct RecordingStatusWidgetView: View {
    let entry: RecordingStatusEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        ZStack {
            Color.black

            if entry.isRecording, let startedAt = entry.startedAt {
                VStack(alignment: .leading, spacing: family == .systemMedium ? 10 : 6) {
                    Text("REC")
                        .font(family == .systemMedium ? .title2.bold() : .headline.bold())
                        .foregroundStyle(.red)
                    Text(timerInterval: startedAt...Date.distantFuture, countsDown: false)
                        .font((family == .systemMedium ? Font.largeTitle : .title3).monospacedDigit().bold())
                        .foregroundStyle(.white)
                    Link(destination: URL(string: "audiomaster://stop")!) {
                        Text("STOP")
                            .font(family == .systemMedium ? .headline.bold() : .caption.bold())
                            .padding(family == .systemMedium ? 10 : 6)
                            .frame(maxWidth: family == .systemMedium ? 180 : .infinity)
                            .background(Color.white)
                            .foregroundStyle(.black)
                    }
                }
                .padding(8)
            } else {
                VStack(spacing: family == .systemMedium ? 12 : 8) {
                    Text("IDLE")
                        .font(family == .systemMedium ? .title2.bold() : .headline.bold())
                        .foregroundStyle(.white)
                    Link(destination: URL(string: "audiomaster://start")!) {
                        Text("START")
                            .font(family == .systemMedium ? .headline.bold() : .caption.bold())
                            .padding(family == .systemMedium ? 10 : 6)
                            .frame(maxWidth: family == .systemMedium ? 180 : .infinity)
                            .background(Color.red)
                            .foregroundStyle(.black)
                    }
                }
                .padding(8)
            }
        }
        .containerBackground(for: .widget) {
            Color.black
        }
    }
}

struct IslandWaveformView: View {
    let heights: [Double]
    let barCount: Int
    let barWidth: CGFloat
    let barSpacing: CGFloat
    let minBarHeight: CGFloat
    let maxBarHeight: CGFloat

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.16)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: barSpacing) {
                ForEach(0..<barCount, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.red)
                        .frame(width: barWidth, height: animatedBarHeight(for: i, t: t))
                }
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard !heights.isEmpty else { return minBarHeight }
        let sourceIndex = index % heights.count
        let value = heights[sourceIndex]
        let clamped = max(Double(minBarHeight), min(value, Double(maxBarHeight)))
        return CGFloat(clamped)
    }

    private func animatedBarHeight(for index: Int, t: TimeInterval) -> CGFloat {
        let base = barHeight(for: index)
        let phase = Double(index) * 0.45
        let wave = sin((t * 7.5) + phase) * 1.8
        let jitter = sin((t * 3.3) + phase * 1.7) * 0.8
        let value = base + CGFloat(wave + jitter)
        return min(max(value, minBarHeight), maxBarHeight)
    }
}

private struct RecordingBadgeView: View {
    let state: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.6)) { timeline in
            let phase = Int(timeline.date.timeIntervalSince1970) % 2 == 0
            HStack(spacing: 4) {
                Rectangle()
                    .fill(state == "interrupted" ? Color.yellow : Color.red)
                    .frame(width: 3, height: 12)
                    .opacity(state == "recording" ? (phase ? 1 : 0.35) : 1)
                Text(state == "interrupted" ? "INT" : "REC")
                    .font(.caption2.bold())
                    .foregroundStyle(state == "interrupted" ? .yellow : .red)
            }
        }
    }
}

private func prettyDeviceName(_ raw: String) -> String {
    if raw.contains("MicrophoneBuiltIn") || raw.contains("BuiltIn") {
        return "iPhone Microphone"
    }
    return raw
}

#Preview("Notification", as: .content, using: audioMasterWidgetAttributes(sessionID: UUID(), sessionTitle: "Preview")) {
    audioMasterWidgetLiveActivity()
} contentStates: {
    audioMasterWidgetAttributes.ContentState(
        recordingState: "recording",
        recordingStart: Date().addingTimeInterval(-95),
        inputDevice: "iPhone Microphone",
        transcribedSegments: 3,
        totalSegments: 6,
        barHeights: [8, 12, 16, 10, 6],
        interruptionMessage: nil
    )
}
