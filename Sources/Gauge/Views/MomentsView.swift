import Charts
import SwiftUI

struct MomentsView: View {
    @Environment(Monitor.self) private var monitor
    @State private var selection: Moment.ID?

    var body: some View {
        HSplitView {
            List(selection: $selection) {
                ForEach(monitor.moments) { moment in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(moment.date.formatted(date: .abbreviated, time: .shortened))
                        Text(moment.note.isEmpty ? "CPU \(Format.percent(moment.cpu)) · \(moment.apps.first?.name ?? "—")" : moment.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 2)
                    .tag(moment.id)
                    .contextMenu {
                        Button("Delete", role: .destructive) { monitor.delete(moment) }
                    }
                }
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
            .overlay {
                if monitor.moments.isEmpty {
                    ContentUnavailableView(
                        "No saved moments",
                        systemImage: "bookmark",
                        description: Text("When something feels slow, press ⌘S to capture what every app is doing.")
                    )
                }
            }

            Group {
                if let moment = monitor.moments.first(where: { $0.id == selection }) {
                    MomentDetail(moment: moment)
                        .id(moment.id)
                } else {
                    Text("Select a moment")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Moments")
        .onAppear { selection = selection ?? monitor.moments.first?.id }
        .onDeleteCommand {
            if let moment = monitor.moments.first(where: { $0.id == selection }) {
                monitor.delete(moment)
                selection = monitor.moments.first?.id
            }
        }
    }
}

private struct MomentDetail: View {
    @Environment(Monitor.self) private var monitor
    let moment: Moment
    @State private var note = ""
    @State private var context: [SystemSample] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(moment.date.formatted(date: .complete, time: .standard)).font(.title3.weight(.semibold))
                    Text("CPU \(Format.percent(moment.cpu)) · Memory \(Format.bytes(moment.memoryUsed)) of \(Format.bytes(moment.memoryTotal))")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                TextField("Add a note — what were you doing?", text: $note, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .onSubmit(saveNote)
                    .onChange(of: note) { _, _ in saveNote() }

                VStack(alignment: .leading, spacing: 8) {
                    Text("CPU around this moment").font(.headline)
                    if context.isEmpty {
                        Text("No history recorded around this time.").foregroundStyle(.secondary)
                    } else {
                        Chart {
                            ForEach(context) { sample in
                                AreaMark(x: .value("Time", sample.date), y: .value("CPU", sample.cpu))
                                    .foregroundStyle(Metric.cpu.color.opacity(0.18))
                                    .interpolationMethod(.monotone)
                                LineMark(x: .value("Time", sample.date), y: .value("CPU", sample.cpu))
                                    .foregroundStyle(Metric.cpu.color)
                                    .interpolationMethod(.monotone)
                            }
                            RuleMark(x: .value("Moment", moment.date))
                                .foregroundStyle(.yellow)
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        }
                        .chartYScale(domain: 0...1)
                        .chartYAxis {
                            AxisMarks(values: [0, 0.5, 1]) { value in
                                AxisGridLine()
                                AxisValueLabel { Text(Format.percent(value.as(Double.self) ?? 0)) }
                            }
                        }
                        .frame(height: 140)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("What was running").font(.headline)
                    VStack(spacing: 0) {
                        ForEach(Array(moment.apps.enumerated()), id: \.element.id) { index, app in
                            if index > 0 { Divider() }
                            HStack(spacing: 10) {
                                AppIconView(bundlePath: app.bundlePath, size: 20)
                                Text(app.name).lineLimit(1)
                                Spacer()
                                Text(Format.cpu(app.cpu)).monospacedDigit().frame(width: 64, alignment: .trailing)
                                Text(Format.bytes(app.memory)).monospacedDigit().foregroundStyle(.secondary)
                                    .frame(width: 84, alignment: .trailing)
                            }
                            .padding(.vertical, 7)
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(.background.secondary, in: .rect(cornerRadius: 10))
                }
            }
            .padding(20)
        }
        .onAppear {
            note = moment.note
            context = monitor.store.series(
                from: moment.date.addingTimeInterval(-30 * 60),
                to: moment.date.addingTimeInterval(30 * 60),
                maxPoints: 60
            )
        }
    }

    private func saveNote() {
        guard note != moment.note else { return }
        monitor.updateNote(note, for: moment)
    }
}
