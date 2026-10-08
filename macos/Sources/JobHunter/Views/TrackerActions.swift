import AppKit
import JobHunterCore
import SwiftUI

/// Context-menu / "Stelle" menu actions for one or more jobs (lists, tracker cards, menu bar
/// commands). Everything goes through the offline-capable edit queue; nothing is ever sent –
/// "Nachfassen" only opens a draft in the mail app.
struct JobActionsMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [Int]

    private var single: JobSummary? { ids.count == 1 ? model.job(ids[0]) : nil }

    var body: some View {
        if ids.count > 1 {
            Text("\(ids.count) Stellen ausgewählt")
        }
        Menu("Status setzen") {
            ForEach(JobStatus.allCases) { s in
                Button {
                    if s == .absage {
                        model.reasonSheetJobIDs = ids
                    } else {
                        model.setStatus(ids: ids, s)
                        if s == .gespraech, let job = single, job.interviewAt == nil {
                            model.interviewSheetJobID = job.id
                        }
                    }
                } label: {
                    Label(s.label + (s == .absage ? " …" : ""), systemImage: s.symbolName)
                }
                .disabled(single?.status == s)
            }
        }
        if let job = single {
            if job.status != .beworben, Tracker.isApplied(job) == false {
                Button("Als beworben markieren") { _ = model.markApplied(id: job.id) }
            }
            if let link = JobLinks.applyLink(for: job) {
                Link("Bewerbung öffnen", destination: link)
                Button("Link kopieren") { copyToPasteboard(link.absoluteString) }
            }
            Divider()
            Button(job.interviewAt == nil ? "Gesprächstermin eintragen …" : "Gesprächstermin ändern …") {
                model.interviewSheetJobID = job.id
            }
            if job.interviewAt != nil {
                Button("Gespräch in Kalender übernehmen …") { model.openInterviewInCalendar(job) }
            }
            Button("Notiz …") { model.noteSheetJobID = job.id }
            if job.status == .beworben {
                Menu("Nachfassen") {
                    Button("E-Mail-Entwurf öffnen (wird nicht gesendet)") { model.openFollowUpDraft(job) }
                    Button("Nachfass-Text kopieren") { copyToPasteboard(model.followUpDraft(for: job).body) }
                    Divider()
                    Button("Als nachgefasst markieren (+\(Tracker.followUpDays) Tage)") { model.followUpDone(id: job.id) }
                    Button("Erinnerung in 7 Tagen") { model.snoozeFollowUp(id: job.id, days: 7) }
                    if job.followUpAt != nil {
                        Button("Erinnerung zurücksetzen (14 Tage nach Bewerbung)") { _ = model.setFollowUp(id: job.id, on: nil) }
                    }
                }
            }
        } else {
            Button("Als beworben markieren") { model.setStatus(ids: ids, .beworben) }
        }
        Divider()
        Button("Zu weit (nicht bewerben)") { model.setStatus(ids: ids, .zuWeit) }
        Button("Duplikat ausblenden") { model.markDuplicate(ids: ids) }
            .help("Status Absage mit Grund „Duplikat“ – zählt nicht als Antwort")
        Button(ids.count > 1 ? "KI-Anschreiben für \(ids.count) Stellen schreiben" : "KI-Anschreiben schreiben") {
            model.writeLetters(ids: ids)
        }
        .disabled(model.isWritingBatch)
    }
}

// MARK: - Sheets (attached once in ContentView)

struct TrackerSheets: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .sheet(item: Binding(get: { model.interviewSheetJobID.map(IDBox.init) },
                                 set: { model.interviewSheetJobID = $0?.id })) { box in
                InterviewSheet(jobID: box.id)
            }
            .sheet(item: Binding(get: { model.noteSheetJobID.map(IDBox.init) },
                                 set: { model.noteSheetJobID = $0?.id })) { box in
                NoteSheet(jobID: box.id)
            }
            .sheet(item: Binding(get: { model.reasonSheetJobIDs.map(IDsBox.init) },
                                 set: { model.reasonSheetJobIDs = $0?.ids })) { box in
                ReasonSheet(ids: box.ids)
            }
    }
}

private struct IDBox: Identifiable { let id: Int }
private struct IDsBox: Identifiable {
    let ids: [Int]
    var id: String { ids.map(String.init).joined(separator: ",") }
}

struct InterviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let jobID: Int
    @State private var date = Date.now
    @State private var note = ""
    @State private var openCalendar = false

    var body: some View {
        let job = model.job(jobID)
        VStack(alignment: .leading, spacing: 12) {
            Text("Gesprächstermin").font(.title3.weight(.semibold))
            if let job {
                Text("\(job.title) – \(job.company ?? "")").foregroundStyle(.secondary).lineLimit(2)
            }
            DatePicker("Datum und Uhrzeit", selection: $date, displayedComponents: [.date, .hourAndMinute])
            TextField("Notiz zum Gespräch (optional, z. B. Teams, Ansprechpartner)", text: $note, axis: .vertical)
                .lineLimit(2...4)
            Toggle("Danach in Kalender übernehmen (Kalender fragt vor dem Hinzufügen)", isOn: $openCalendar)
            Text("Der Status wird auf „Gespräch“ gesetzt. Die Notiz wird mit Datum an die Notizen angehängt.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                if job?.interviewAt != nil {
                    Button("Termin entfernen", role: .destructive) {
                        model.setInterview(id: jobID, at: nil)
                        dismiss()
                    }
                }
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    model.setInterview(id: jobID, at: date, note: note)
                    if openCalendar, let j = model.job(jobID) { model.openInterviewInCalendar(j) }
                    model.transientMessage = "Gespräch am \(Tracker.fmtDateTime(date)) eingetragen."
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear {
            if let d = Tracker.interviewDate(job?.interviewAt) {
                date = d
            } else {
                // Default: next working day, 10:00.
                var day = Tracker.calendar.date(byAdding: .day, value: 1, to: .now) ?? .now
                while Tracker.calendar.isDateInWeekend(day) { day = Tracker.calendar.date(byAdding: .day, value: 1, to: day) ?? day }
                date = Tracker.calendar.date(bySettingHour: 10, minute: 0, second: 0, of: day) ?? day
            }
        }
    }
}

struct NoteSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let jobID: Int
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Notiz").font(.title3.weight(.semibold))
            if let job = model.job(jobID) {
                Text("\(job.title) – \(job.company ?? "")").foregroundStyle(.secondary).lineLimit(2)
            }
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text(model.isOnline ? "" : "Offline – wird später synchronisiert.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Speichern") {
                    model.saveNotes(id: jobID, text)
                    model.transientMessage = "Notiz gespeichert."
                    dismiss()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear { text = model.notes(for: jobID) }
    }
}

struct ReasonSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let ids: [Int]
    @State private var reason: Tracker.CloseReason? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ids.count == 1 ? "Absage" : "Absage für \(ids.count) Stellen").font(.title3.weight(.semibold))
            Picker("Grund", selection: $reason) {
                Text("Absage der Firma / ohne Grund").tag(Tracker.CloseReason?.none)
                ForEach(Tracker.CloseReason.allCases) { r in Text(r.label).tag(Tracker.CloseReason?.some(r)) }
            }
            Text("„Duplikat“ und „Kein Interesse“ zählen im Tracker nicht als Antwort der Firma.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Abbrechen", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Absage speichern") {
                    model.setStatus(ids: ids, .absage, reason: reason)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - "Stelle" menu + navigation shortcuts

struct JobCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Stelle") {
            let ids = model.actionJobIDs
            Menu("Status setzen") {
                // Same order as the Kanban columns: ⌥⌘1 Neu … ⌥⌘7 Zu weit.
                ForEach(Array(Tracker.columns.enumerated()), id: \.element) { i, s in
                    Button(s.label) {
                        if s == .absage { model.reasonSheetJobIDs = ids } else { model.setStatus(ids: ids, s) }
                    }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: [.command, .option])
                }
            }
            .disabled(ids.isEmpty)
            Button("Als beworben markieren") { model.setStatus(ids: ids, .beworben) }
                .keyboardShortcut("b", modifiers: [.command, .shift])
                .disabled(ids.isEmpty)
            Button("Bewerbung öffnen") {
                if let id = ids.first, let job = model.job(id), let link = JobLinks.applyLink(for: job) {
                    NSWorkspace.shared.open(link)
                }
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(ids.count != 1)
            Divider()
            Button("Gesprächstermin …") { model.interviewSheetJobID = ids.first }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(ids.count != 1)
            Button("Notiz …") { model.noteSheetJobID = ids.first }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(ids.count != 1)
            Button("Nachfassen – E-Mail-Entwurf öffnen") {
                if let id = ids.first, let job = model.job(id) { model.openFollowUpDraft(job) }
            }
            .keyboardShortcut("f", modifiers: [.command, .shift])
            .disabled(ids.count != 1)
            Divider()
            Button("Zu weit") { model.setStatus(ids: ids, .zuWeit) }
                .disabled(ids.isEmpty)
            Button("Duplikat ausblenden") { model.markDuplicate(ids: ids) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(ids.isEmpty)
        }
        CommandMenu("Gehe zu") {
            ForEach(Array(Self.targets.enumerated()), id: \.offset) { i, t in
                Button(t.0) { model.sidebarSelection = t.1 }
                    .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
            }
        }
    }

    static let targets: [(String, SidebarItem)] = [
        ("Heute zu tun", .today), ("Neu", .recent), ("Automatisch", .automatic), ("Manuell", .manual),
        ("Tracker", .tracker), ("Postausgang", .outbox), ("Alle Stellen", .jobs),
    ]
}
