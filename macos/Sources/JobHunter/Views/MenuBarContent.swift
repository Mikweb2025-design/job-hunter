import JobHunterCore
import SwiftUI

/// Menu-bar menu: new high-score jobs (status "neu", score ≥ threshold) + quick actions.
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let jobs = model.highScoreNew
        let threshold = model.settings.notifyThreshold

        if model.isOffline {
            Text("Offline – gespeicherte Daten" + (model.dataDate.map { " von \($0.formatted(date: .omitted, time: .shortened))" } ?? ""))
        } else if let error = model.errorMessage {
            Text(error)
        }
        if model.pendingCount > 0 {
            Text(pendingText(model.pendingCount))
        }
        let today = model.todayJobs
        if !today.isEmpty {
            Button("Heute zu tun: \(today.count) manuelle Bewerbungen …") {
                openWindow(id: "main")
                model.sidebarSelection = .today
                NSApp.activate()
            }
        }
        Divider()

        Text(model.bannerKind.headline(model.sendSettings))
        if let s = model.sendSettings {
            Text("Heute gesendet: \(s.sentToday) · Insgesamt: \(s.sentTotal)")
        }
        Button("Postausgang …") {
            openWindow(id: "main")
            model.sidebarSelection = .outbox
            NSApp.activate()
        }
        Divider()

        if jobs.isEmpty {
            Text("Keine neuen Stellen ab Score \(threshold)")
        } else {
            Section("Neu ab Score \(threshold) (\(jobs.count))") {
                ForEach(jobs.prefix(10)) { job in
                    Button {
                        openMain(jobID: job.id)
                    } label: {
                        Text("\(job.score)  \(job.title)" + (job.company.map { " – \($0)" } ?? ""))
                    }
                }
                if jobs.count > 10 {
                    Button("Alle \(jobs.count) anzeigen …") {
                        model.filter = JobFilter(status: .only(.neu), minScore: threshold)
                        openMain(jobID: nil)
                    }
                }
            }
        }

        Divider()
        Button(model.isRunActive ? "Suche läuft …" : "Jetzt suchen") { model.triggerRun() }
            .disabled(model.isRunActive || model.client == nil || !model.isOnline)
        Button("Aktualisieren") { Task { await model.refresh() } }
            .keyboardShortcut("r")
        Button("JobHunter öffnen") { openMain(jobID: nil) }
            .keyboardShortcut("o")
        SettingsLink { Text("Einstellungen …") }
            .keyboardShortcut(",")
        Divider()
        Button("JobHunter beenden") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func openMain(jobID: Int?) {
        openWindow(id: "main")
        if let jobID {
            model.open(jobID: jobID)
        }
        NSApp.activate()
    }
}
