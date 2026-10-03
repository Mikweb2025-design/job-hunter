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
