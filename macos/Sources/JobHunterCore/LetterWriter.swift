import Foundation

// MARK: - Prompt

/// German 4-sentence cover-letter prompt, same rules as the backend (`jobhunter/llm.py`).
public enum LetterPrompt {
    public static let maxPostingChars = 15_000
    public static let defaultCVProfilePath = NSHomeDirectory() + "/job-hunter/data/cv_profile.md"
    public static let originLabel = "KI (opencode)"

    public static let rules = """
    Du hilfst einem erfahrenen Support Engineer bei der Jobsuche in Deutschland und schreibst einen kurzen Anschreiben-Entwurf für die Stellenanzeige unten.

    Regeln für das Anschreiben (Deutsch, genau 4 Sätze, kein Gruß, keine Anrede). Schreibe in der ICH-FORM aus Sicht des Bewerbers (ich, mein, mir); das Unternehmen wird höflich mit „Sie“ angesprochen. Sprich NIE den Bewerber selbst mit „Sie“ oder „Ihre“ an:
    1. Satz: das relevanteste konkrete Ergebnis aus dem Profil, passend zur Stelle.
    2. Satz: warum genau dieses Unternehmen/diese Stelle – mit einem konkreten Bezug aus dem Anzeigentext.
    3. Satz: was ich in den ersten 90 Tagen konkret tun würde.
    4. Satz: eine schlichte Bitte um ein Gespräch.
    Keine Buzzwords (z.B. "leidenschaftlich", "dynamisch", "Synergien", "Mehrwert schaffen").
    Erfinde NIEMALS Zahlen, Firmen, Zertifikate oder Ergebnisse. Verwende Zahlen nur, wenn sie wörtlich im Profil stehen.
    Keine Platzhalter in eckigen Klammern. Benutze keine Werkzeuge und lies keine Dateien – alles Nötige steht unten.

    Gib ausschließlich den Text des Anschreibens aus: genau 4 Sätze als ein Absatz, ohne Überschrift, ohne Anführungszeichen, ohne Erklärung davor oder danach.
    """

    /// Removes HTML comments (editor hints in cv_profile.md) and surrounding whitespace.
    public static func cleanProfile(_ markdown: String) -> String {
        markdown.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func build(cvProfile: String, job: JobDetail, minSalary: Int = 44_000) -> String {
        let s = job.summary
        let desc = String(job.description.prefix(maxPostingChars))
        var salary = "unbekannt"
        if s.salaryMin != nil || s.salaryMax != nil {
            salary = "\(s.salaryMin.map { String(Int($0)) } ?? "?") – \(s.salaryMax.map { String(Int($0)) } ?? "?") EUR/Jahr"
        }
        return """
        \(rules)

        <profil>
        \(cleanProfile(cvProfile))
        </profil>

        <wuensche>Mindestgehalt \(minSalary) EUR/Jahr; Berlin oder remote.</wuensche>

        <stelle>
        Titel: \(s.title)
        Unternehmen: \(s.company ?? "unbekannt")
        Ort: \(s.location ?? "unbekannt")
        Remote möglich: \(s.remote ? "ja" : "unbekannt")
        Gehalt: \(salary)

        \(desc)
        </stelle>
        """
    }
}

// MARK: - Output cleaning / validation

public enum LetterRejection: LocalizedError, Equatable, Sendable {
    case empty
    case tooShort(Int)
    case placeholder
    case inventedNumbers([String])
    case wrongPerspective

    public var errorDescription: String? {
        switch self {
        case .empty: "Die KI hat keinen Text geliefert."
        case .tooShort(let n): "Antwort zu kurz (\(n) Zeichen) – kein brauchbares Anschreiben."
        case .placeholder: "Antwort enthält noch Platzhalter „[ … ]“ – verworfen."
        case .wrongPerspective: "Anschreiben nicht in der Ich-Form (spricht den Bewerber mit „Sie“ an) – verworfen."
        case .inventedNumbers(let n): "Antwort enthält Zahlen, die weder im Profil noch in der Anzeige stehen (\(n.joined(separator: ", "))) – verworfen."
        }
    }
}

public enum LetterOutputCleaner {
    public static let minLength = 180

    /// ANSI CSI/OSC escape sequences and stray control characters.
    public static func stripANSI(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\[[0-?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[@-Z\\\\-_]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\u{00}-\u{08}\u{0B}\u{0C}\u{0E}-\u{1F}\u{7F}]", with: "", options: .regularExpression)
    }

    /// `opencode run --format json` prints one JSON event per line; the answer is in the
    /// `text` parts. Returns nil if the output is not in that format.
    public static func textFromJSONEvents(_ raw: String) -> String? {
        var texts: [String] = []
        var sawEvent = false
        for line in raw.split(whereSeparator: \.isNewline) {
            guard line.first == "{", let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["type"] as? String else { continue }
            sawEvent = true
            if type == "text", let part = obj["part"] as? [String: Any], let text = part["text"] as? String {
                texts.append(text)
            }
        }
        guard sawEvent else { return nil }
        // Several text parts (e.g. a remark before a tool call): the final one is the answer.
        return texts.last(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) ?? ""
    }

    private static let noiseLine = try! NSRegularExpression(
        pattern: "^\\s*(> \\S+ · .*|[│┃|]\\s.*|[⚙✓✔✗•▶■□◆◇⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏].*|```.*|#+\\s.*|(Anschreiben|Entwurf|Hier (ist|sind)|Gerne|Here is)[^.!?]*:\\s*)$",
        options: [.caseInsensitive])
    private static let salutation = try! NSRegularExpression(
        pattern: "^\\s*(sehr geehrte|liebe[rs]?\\b|hallo\\b|guten tag|dear\\b)[^\\n]*$", options: [.caseInsensitive])
    private static let closing = try! NSRegularExpression(
        pattern: "^\\s*(mit )?(freundlichen|besten|herzlichen|viele) grü(ß|ss)en?.*$|^\\s*(kind|best) regards.*$",
        options: [.caseInsensitive])

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Extracts the letter from raw CLI output and validates it.
    /// - Parameter sources: profile + posting text; numbers in the letter must occur there.
    public static func clean(_ raw: String, sources: [String] = []) throws -> String {
        let text = textFromJSONEvents(raw) ?? raw
        var lines = stripANSI(text).components(separatedBy: .newlines)
        lines = lines.filter { !matches(noiseLine, $0) }
        // Drop a salutation at the start and everything from a closing formula on.
        while let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
              matches(salutation, first) {
            lines.removeFirst(lines.firstIndex(of: first)! + 1)
        }
        if let i = lines.firstIndex(where: { matches(closing, $0) }) { lines = Array(lines[..<i]) }

        var letter = lines.map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        letter = letter.replacingOccurrences(of: "**", with: "")
        let quotes: [(Character, Character)] = [("\"", "\""), ("„", "“"), ("«", "»"), ("“", "”"), ("'", "'")]
        for (open, close) in quotes where letter.count > 2 && letter.first == open && letter.last == close {
            letter = String(letter.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !letter.isEmpty else { throw LetterRejection.empty }
        if letter.contains("[") || letter.contains("]") { throw LetterRejection.placeholder }
        if letter.count < minLength { throw LetterRejection.tooShort(letter.count) }
        if !Self.isFirstPerson(letter) { throw LetterRejection.wrongPerspective }
        if !sources.isEmpty {
            let invented = inventedNumbers(in: letter, sources: sources)
            if !invented.isEmpty { throw LetterRejection.inventedNumbers(invented) }
        }
        return letter
    }

    /// First person (ich/mein …) and never addressing the applicant as „Sie“ (seen with opencode/big-pickle).
    public static func isFirstPerson(_ letter: String) -> Bool {
        let ich = letter.range(of: #"\b(ich|mein|meine|meinen|meiner|meinem|mir|mich)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
        let wrong = letter.range(of: #"\b(haben Sie bereits|Ihre bisherige|Ihrer bisherigen|Ihre Erfahrung|würden Sie sich|Ihre Eignung)"#, options: [.regularExpression, .caseInsensitive]) != nil
        return ich && !wrong
    }

    /// Numbers in `letter` that appear in none of the sources ("90" – the 90 days – is allowed).
    public static func inventedNumbers(in letter: String, sources: [String]) -> [String] {
        let known = Set(sources.flatMap(numbers(in:))).union(["90"])
        var seen: [String] = []
        for n in numbers(in: letter) where !known.contains(n) && !seen.contains(n) { seen.append(n) }
        return seen
    }

    /// Digit groups, normalized: "15.000" / "15 000" / "15000" → "15000"; years stay as is.
    static func numbers(in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\d{1,3}(?:[.\u{00A0} ]\\d{3})+|\\d+") else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in
            Range(m.range, in: text).map { String(text[$0]).filter(\.isNumber) }
        }
    }
}

// MARK: - opencode CLI

public enum OpencodeError: LocalizedError, Equatable, Sendable {
    case notInstalled(String)
    case timeout(Int)
    case failed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled(let path): "opencode nicht gefunden: \(path)"
        case .timeout(let s): "opencode hat nach \(s) s nicht geantwortet – abgebrochen."
        case .failed(let code, let err): "opencode Fehler (Exit \(code))" + (err.isEmpty ? "" : ": \(err)")
        }
    }
}

/// Runs `opencode run -m <model> --format json "<prompt>"` with a timeout.
public struct OpencodeRunner: Sendable {
    public static let defaultExecutable = NSHomeDirectory() + "/.opencode/bin/opencode"
    public static let defaultModel = "opencode/big-pickle"
    public static let fallbackModels = [
        "opencode/big-pickle",
        "ollama/maternion/spark-x2.5:4b-q4_K_M",
    ]

    public var executable: String
    public var timeout: TimeInterval
    /// Empty working directory, so the agent has no project files to wander through.
    public var workingDirectory: URL

    public init(executable: String = OpencodeRunner.defaultExecutable, timeout: TimeInterval = 120,
                workingDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "JobHunter-opencode")) {
        self.executable = (executable as NSString).expandingTildeInPath
        self.timeout = timeout
        self.workingDirectory = workingDirectory
    }

    public var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: executable) }

    public func writeLetter(model: String, prompt: String) async throws -> String {
        try await run(["run", "-m", model, "--format", "json", prompt]).stdout
    }

    public func models() async throws -> [String] {
        Self.parseModels(try await run(["models"], timeout: 30).stdout)
    }

    /// `opencode models` prints one `provider/model` per line (plus possible noise).
    public static func parseModels(_ output: String) -> [String] {
        var seen = Set<String>()
        return LetterOutputCleaner.stripANSI(output).split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") && $0.contains("/") }
            .filter { seen.insert($0).inserted }
    }

    public struct Output: Sendable {
        public var stdout: String
        public var stderr: String
        public var status: Int32
    }

    func run(_ arguments: [String], timeout: TimeInterval? = nil) async throws -> Output {
        guard isInstalled else { throw OpencodeError.notInstalled(executable) }
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let limit = timeout ?? self.timeout

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", (executable as NSString).deletingLastPathComponent]
        env["PATH"] = (extra + [env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        // Note: NO_COLOR / TERM=dumb make `opencode run` hang (seen with v1.18.34) – don't set them;
        // ANSI codes are stripped by LetterOutputCleaner anyway.
        process.environment = env
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice

        let outBuf = Buffer(), errBuf = Buffer()
        out.fileHandleForReading.readabilityHandler = { h in outBuf.append(h.availableData) }
        err.fileHandleForReading.readabilityHandler = { h in errBuf.append(h.availableData) }

        let timedOut = Flag()
        let status: Int32 = try await withCheckedThrowingContinuation { cont in
            process.terminationHandler = { p in cont.resume(returning: p.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                cont.resume(throwing: OpencodeError.failed(-1, error.localizedDescription))
                return
            }
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + limit) {
                guard process.isRunning else { return }
                timedOut.set()
                process.terminate()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        outBuf.append(out.fileHandleForReading.readDataToEndOfFile())
        errBuf.append(err.fileHandleForReading.readDataToEndOfFile())
        let stdout = outBuf.string, stderr = errBuf.string
        if timedOut.isSet { throw OpencodeError.timeout(Int(limit)) }
        guard status == 0 else {
            let msg = LetterOutputCleaner.stripANSI(stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            throw OpencodeError.failed(status, String(msg.suffix(400)))
        }
        return Output(stdout: stdout, stderr: stderr, status: status)
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.withLock { data.append(d) } }
        var string: String { lock.withLock { String(decoding: data, as: UTF8.self) } }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.withLock { value = true } }
        var isSet: Bool { lock.withLock { value } }
    }
}
