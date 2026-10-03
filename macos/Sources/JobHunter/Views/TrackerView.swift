import Charts
import JobHunterCore
import SwiftUI

/// Application tracker + statistics: counts per status, last run, pipeline of tracked jobs.
struct TrackerView: View {
    @Environment(AppModel.self) private var model

    private let pipeline: [JobStatus] = [.interessant, .beworben, .gespraech, .angebot, .absage]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                tiles
                chart
                lastRun
                ForEach(pipeline) { status in
                    let items = model.allJobs.filter { $0.status == status }
                    if !items.isEmpty {
                        section(status, items)
                    }
                }
                if model.allJobs.allSatisfy({ $0.status == .neu }) && !model.allJobs.isEmpty {
                    Text("Noch keine Stelle markiert. Setze im Detail den Status auf „Interessant“ oder „Beworben“.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
        }
        .navigationTitle("Tracker")
        .overlay {
            if model.stats == nil {
                if model.isLoading { ProgressView() } else {
                    ContentUnavailableView("Keine Statistik", systemImage: "chart.bar.xaxis",
                                           description: Text(model.errorMessage ?? "Noch keine Daten geladen."))
                }
            }
        }
    }

    private var tiles: some View {
        let s = model.stats
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Tile(title: "Gesamt", value: s?.total ?? 0, symbol: "tray.full", tint: .blue)
                Tile(title: "Neu im letzten Lauf", value: s?.newSinceLastRun ?? 0, symbol: "sparkles", tint: .indigo)
                Tile(title: "Davon ≥ \(s?.threshold ?? model.settings.notifyThreshold)",
                     value: s?.newSinceLastRunAboveThreshold ?? 0, symbol: "flame", tint: .orange)
            }
            GridRow {
                Tile(title: "Beworben", value: s?.count(.beworben) ?? 0, symbol: JobStatus.beworben.symbolName, tint: .teal)
                Tile(title: "Gespräche", value: s?.count(.gespraech) ?? 0, symbol: JobStatus.gespraech.symbolName, tint: .orange)
                Tile(title: "Angebote", value: s?.count(.angebot) ?? 0, symbol: JobStatus.angebot.symbolName, tint: .green)
            }
        }
    }

    @ViewBuilder
    private var chart: some View {
        if let s = model.stats {
            GroupBox("Stellen nach Status") {
                Chart(JobStatus.allCases) { status in
                    BarMark(x: .value("Anzahl", s.count(status)), y: .value("Status", status.label))
                        .foregroundStyle(by: .value("Status", status.label))
                        .annotation(position: .trailing) {
                            Text("\(s.count(status))").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                }
                .chartLegend(.hidden)
                .frame(height: 180)
                .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var lastRun: some View {
        if let run = model.stats?.lastRun {
            GroupBox("Letzter Suchlauf") {
                VStack(alignment: .leading, spacing: 4) {
                    if let end = ServerDate.parse(run.finishedAt) {
                        LabeledContent("Beendet") { Text(end, format: .dateTime.day().month().hour().minute()) }
                    }
                    LabeledContent("Neue Stellen", value: "\(run.newJobs)")
                    ForEach(run.errors, id: \.self) { err in
                        Label(err, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .textSelection(.enabled)
                    }
                }
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func section(_ status: JobStatus, _ items: [JobSummary]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("\(status.label) (\(items.count))", systemImage: status.symbolName)
                .font(.headline)
            ForEach(items) { job in
                Button {
                    model.selectedJobID = job.id
                } label: {
                    HStack {
                        ScoreBadge(score: job.score)
                        VStack(alignment: .leading) {
                            Text(job.title).lineLimit(1)
                            Text(job.companyAndLocation).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let applied = job.appliedDate, let d = ServerDate.parse(applied) {
                            Text(d, format: .dateTime.day().month().year())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(6)
                    .contentShape(Rectangle())
                    .background(model.selectedJobID == job.id ? Color.accentColor.opacity(0.15) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct Tile: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text("\(value)")
                .font(.title.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
