import Foundation
import JobHunterCore
import Observation

/// User preferences (UserDefaults) + password (Keychain).
///
/// For automation/testing the values can be overridden without touching stored settings:
/// launch arguments `-serverURL <url> -username <user>` (UserDefaults argument domain) and
/// the environment variable `JOBHUNTER_PASSWORD` (never written to the Keychain).
@MainActor
@Observable
final class AppSettings {
    private let defaults: UserDefaults

    var serverURL: String { didSet { defaults.set(serverURL, forKey: Keys.serverURL) } }
    var username: String {
        didSet {
            defaults.set(username, forKey: Keys.username)
            loadPassword()
        }
    }
    var refreshMinutes: Int { didSet { defaults.set(refreshMinutes, forKey: Keys.refreshMinutes) } }
    var notifyThreshold: Int { didSet { defaults.set(notifyThreshold, forKey: Keys.notifyThreshold) } }
    var notificationsEnabled: Bool { didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) } }
    /// "Automatisch senden": only effective when the server runs send.mode=auto and dry_run=false.
    var autoSendEnabled: Bool { didSet { defaults.set(autoSendEnabled, forKey: Keys.autoSendEnabled) } }
    /// CV PDF attached to every e-mail application ("~" allowed).
    var cvPath: String { didSet { defaults.set(cvPath, forKey: Keys.cvPath) } }

    /// KI-Anschreiben via opencode CLI.
    var opencodePath: String { didSet { defaults.set(opencodePath, forKey: Keys.opencodePath) } }
    var letterModel: String { didSet { defaults.set(letterModel, forKey: Keys.letterModel) } }
    var letterTimeout: Int { didSet { defaults.set(letterTimeout, forKey: Keys.letterTimeout) } }
    /// Profile used for sentence 1 (same file the server uses).
    var cvProfilePath: String { didSet { defaults.set(cvProfilePath, forKey: Keys.cvProfilePath) } }
    /// After a refresh, replace template letters ("vorlage") with opencode letters when the server
    /// has no KI or did not manage (sequential, cancellable).
    var autoReplaceTemplates: Bool { didSet { defaults.set(autoReplaceTemplates, forKey: Keys.autoReplaceTemplates) } }

    /// Sender block of the cover-letter PDF (works offline; "Vom Server übernehmen" in the settings).
    var applicantName: String { didSet { defaults.set(applicantName, forKey: Keys.applicantName) } }
    var applicantStreet: String { didSet { defaults.set(applicantStreet, forKey: Keys.applicantStreet) } }
    var applicantCity: String { didSet { defaults.set(applicantCity, forKey: Keys.applicantCity) } }
    var applicantEmail: String { didSet { defaults.set(applicantEmail, forKey: Keys.applicantEmail) } }
    var applicantPhone: String { didSet { defaults.set(applicantPhone, forKey: Keys.applicantPhone) } }
    var applicantLinkedIn: String { didSet { defaults.set(applicantLinkedIn, forKey: Keys.applicantLinkedIn) } }
    /// "Job-Alerts aus Mail importieren": LinkedIn/StepStone/Indeed alert e-mails (read-only).
    var jobAlertsEnabled: Bool { didSet { defaults.set(jobAlertsEnabled, forKey: Keys.jobAlertsEnabled) } }
    /// Mail account (name or address) whose INBOX receives the alerts.
    var jobAlertAccount: String { didSet { defaults.set(jobAlertAccount, forKey: Keys.jobAlertAccount) } }
    var jobAlertDays: Int { didSet { defaults.set(jobAlertDays, forKey: Keys.jobAlertDays) } }
    static let defaultJobAlertAccount = "info@daniele-michelin.com"

    /// Folder for "Als PDF speichern" ("~" allowed).
    var letterPDFFolder: String { didSet { defaults.set(letterPDFFolder, forKey: Keys.letterPDFFolder) } }
    static let defaultLetterPDFFolder = "~/Bewerbung/Anschreiben"

    var applicant: Applicant {
        Applicant(name: applicantName, street: applicantStreet, city: applicantCity, email: applicantEmail,
                  phone: applicantPhone, linkedin: applicantLinkedIn)
    }

    func adopt(_ a: Applicant) {
        applicantName = a.name
        applicantStreet = a.street
        applicantCity = a.city
        applicantEmail = a.email
        applicantPhone = a.phone
        applicantLinkedIn = a.linkedin
    }

    static let defaultCVPath = "~/Bewerbung/Lebenslauf_Daniele_Michelin.pdf"

    private(set) var password: String = ""
    private(set) var passwordFromEnvironment = false

    enum Keys {
        static let serverURL = "serverURL"
        static let username = "username"
        static let refreshMinutes = "refreshMinutes"
        static let notifyThreshold = "notifyThreshold"
        static let notificationsEnabled = "notificationsEnabled"
        static let seenJobIDs = "seenJobIDs"
        static let autoSendEnabled = "autoSendEnabled"
        static let cvPath = "cvPath"
        static let opencodePath = "opencodePath"
        static let letterModel = "letterModel"
        static let letterTimeout = "letterTimeout"
        static let cvProfilePath = "cvProfilePath"
        static let autoReplaceTemplates = "autoReplaceTemplates"
        static let applicantName = "applicantName"
        static let applicantStreet = "applicantStreet"
        static let applicantCity = "applicantCity"
        static let applicantEmail = "applicantEmail"
        static let applicantPhone = "applicantPhone"
        static let applicantLinkedIn = "applicantLinkedIn"
        static let letterPDFFolder = "letterPDFFolder"
        static let jobAlertsEnabled = "jobAlertsEnabled"
        static let jobAlertAccount = "jobAlertAccount"
        static let jobAlertDays = "jobAlertDays"
    }

    let ledger: SendLedger

    init(defaults: UserDefaults = .standard) {
        ledger = UserDefaultsLedger(defaults: defaults)
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.serverURL: "http://localhost:8000",
            Keys.refreshMinutes: 15,
            Keys.notifyThreshold: 70,
            Keys.notificationsEnabled: true,
            Keys.autoSendEnabled: false,
            Keys.cvPath: AppSettings.defaultCVPath,
            Keys.opencodePath: OpencodeRunner.defaultExecutable,
            Keys.letterModel: OpencodeRunner.defaultModel,
            Keys.letterTimeout: 120,
            Keys.cvProfilePath: LetterPrompt.defaultCVProfilePath,
            Keys.autoReplaceTemplates: true,
            Keys.applicantName: Applicant.standard.name,
            Keys.applicantStreet: Applicant.standard.street,
            Keys.applicantCity: Applicant.standard.city,
            Keys.applicantEmail: Applicant.standard.email,
            Keys.applicantPhone: Applicant.standard.phone,
            Keys.applicantLinkedIn: Applicant.standard.linkedin,
            Keys.letterPDFFolder: AppSettings.defaultLetterPDFFolder,
            Keys.jobAlertsEnabled: true,
            Keys.jobAlertAccount: AppSettings.defaultJobAlertAccount,
            Keys.jobAlertDays: 14,
        ])
        serverURL = defaults.string(forKey: Keys.serverURL) ?? ""
        username = defaults.string(forKey: Keys.username) ?? ""
        refreshMinutes = max(1, defaults.integer(forKey: Keys.refreshMinutes))
        notifyThreshold = defaults.integer(forKey: Keys.notifyThreshold)
        notificationsEnabled = defaults.bool(forKey: Keys.notificationsEnabled)
        autoSendEnabled = defaults.bool(forKey: Keys.autoSendEnabled)
        cvPath = defaults.string(forKey: Keys.cvPath) ?? AppSettings.defaultCVPath
        opencodePath = defaults.string(forKey: Keys.opencodePath) ?? OpencodeRunner.defaultExecutable
        letterModel = defaults.string(forKey: Keys.letterModel) ?? OpencodeRunner.defaultModel
        letterTimeout = max(20, defaults.integer(forKey: Keys.letterTimeout))
        cvProfilePath = defaults.string(forKey: Keys.cvProfilePath) ?? LetterPrompt.defaultCVProfilePath
        autoReplaceTemplates = defaults.bool(forKey: Keys.autoReplaceTemplates)
        applicantName = defaults.string(forKey: Keys.applicantName) ?? Applicant.standard.name
        applicantStreet = defaults.string(forKey: Keys.applicantStreet) ?? ""
        applicantCity = defaults.string(forKey: Keys.applicantCity) ?? Applicant.standard.city
        applicantEmail = defaults.string(forKey: Keys.applicantEmail) ?? Applicant.standard.email
        applicantPhone = defaults.string(forKey: Keys.applicantPhone) ?? Applicant.standard.phone
        applicantLinkedIn = defaults.string(forKey: Keys.applicantLinkedIn) ?? Applicant.standard.linkedin
        letterPDFFolder = defaults.string(forKey: Keys.letterPDFFolder) ?? AppSettings.defaultLetterPDFFolder
        jobAlertsEnabled = defaults.bool(forKey: Keys.jobAlertsEnabled)
        jobAlertAccount = defaults.string(forKey: Keys.jobAlertAccount) ?? AppSettings.defaultJobAlertAccount
        jobAlertDays = min(90, max(1, defaults.integer(forKey: Keys.jobAlertDays)))
        loadPassword()
    }

    private func loadPassword() {
        if let env = ProcessInfo.processInfo.environment["JOBHUNTER_PASSWORD"], !env.isEmpty {
            password = env
            passwordFromEnvironment = true
        } else {
            password = username.isEmpty ? "" : (Keychain.password(account: username) ?? "")
            passwordFromEnvironment = false
        }
    }

    func setPassword(_ value: String) throws {
        if !passwordFromEnvironment {
            try Keychain.setPassword(value, account: username)
        }
        password = value
    }

    var serverConfig: ServerConfig? {
        guard let url = ServerConfig.normalizedURL(serverURL), !username.isEmpty, !password.isEmpty else { return nil }
        return ServerConfig(baseURL: url, username: username, password: password)
    }

    /// Ids already shown/notified. `nil` = first launch (seed silently, no notification flood).
    var seenJobIDs: Set<Int>? {
        get { (defaults.array(forKey: Keys.seenJobIDs) as? [Int]).map(Set.init) }
        set { defaults.set(newValue.map { Array($0).sorted() }, forKey: Keys.seenJobIDs) }
    }
}
