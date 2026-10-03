import AppKit
import JobHunterCore
import UserNotifications

/// Local user notifications for new high-score jobs. Clicking one opens the job in the app.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    var onOpenJob: ((Int) -> Void)?

    /// UNUserNotificationCenter requires a bundled app (not a bare `swift run` binary).
    var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app" }

    func setUp() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        do {
            return try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func notify(newJobs jobs: [JobSummary], threshold: Int) async {
        guard isAvailable, !jobs.isEmpty else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }

        if jobs.count > 3 {
            let content = UNMutableNotificationContent()
            content.title = "\(jobs.count) neue passende Stellen"
            content.body = jobs.prefix(3).map { "\($0.score) · \($0.title)" }.joined(separator: "\n")
                + (jobs.count > 3 ? "\n…" : "")
            content.sound = .default
            content.userInfo = ["jobID": jobs[0].id]
            content.threadIdentifier = "new-jobs"
            try? await center.add(UNNotificationRequest(identifier: "batch-\(jobs[0].id)-\(jobs.count)",
                                                        content: content, trigger: nil))
            return
        }
        for job in jobs {
            let content = UNMutableNotificationContent()
            content.title = "Neue Stelle · Score \(job.score)"
            content.subtitle = job.title
            content.body = job.companyAndLocation
            content.sound = .default
            content.userInfo = ["jobID": job.id]
            content.threadIdentifier = "new-jobs"
            try? await center.add(UNNotificationRequest(identifier: "job-\(job.id)", content: content, trigger: nil))
        }
    }

    /// One notification per application that really went out (always, independent of the
    /// "new jobs" toggle: a real send must never go unnoticed).
    func notifySent(jobID: Int, title: String, to: String) async {
        guard isAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined { _ = await requestAuthorization() }
        let content = UNMutableNotificationContent()
        content.title = "✉ Bewerbung gesendet"
        content.subtitle = title
        content.body = "an \(to) über Apple Mail"
        content.sound = .default
        content.userInfo = ["jobID": jobID]
        content.threadIdentifier = "sent"
        try? await center.add(UNNotificationRequest(identifier: "sent-\(jobID)", content: content, trigger: nil))
    }

    func notifySendProblem(_ message: String) async {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = "Bewerbung nicht gesendet"
        content.body = message
        content.threadIdentifier = "sent"
        try? await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "send-problem-\(message.hashValue)", content: content, trigger: nil))
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let jobID = response.notification.request.content.userInfo["jobID"] as? Int
        await MainActor.run {
            NSApp.activate()
            if let jobID { self.onOpenJob?(jobID) }
        }
    }
}
