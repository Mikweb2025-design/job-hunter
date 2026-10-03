import CoreGraphics
import Foundation

// MARK: - Applicant (sender block)

/// Sender of the cover letter. Same fields as `applicant:` in the server's config.yaml
/// (`GET /api/v1/send-settings` → `applicant`). Public contact data only, no secrets.
public struct Applicant: Codable, Sendable, Hashable {
    public var name: String
    public var street: String
    public var city: String
    public var email: String
    public var phone: String
    public var linkedin: String
    public var enclosures: [String]

    public init(name: String, street: String = "", city: String, email: String, phone: String,
                linkedin: String, enclosures: [String] = ["Lebenslauf"]) {
        self.name = name
        self.street = street
        self.city = city
        self.email = email
        self.phone = phone
        self.linkedin = linkedin
        self.enclosures = enclosures
    }

    public static let standard = Applicant(
        name: "Daniele Michelin", city: "Berlin", email: "info@daniele-michelin.com",
        phone: "+49 160 7804710", linkedin: "linkedin.com/in/daniele-michelin-02863143b")

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Applicant.standard
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        street = try c.decodeIfPresent(String.self, forKey: .street) ?? ""
        city = try c.decodeIfPresent(String.self, forKey: .city) ?? d.city
        email = try c.decodeIfPresent(String.self, forKey: .email) ?? d.email
        phone = try c.decodeIfPresent(String.self, forKey: .phone) ?? d.phone
        linkedin = try c.decodeIfPresent(String.self, forKey: .linkedin) ?? d.linkedin
        enclosures = try c.decodeIfPresent([String].self, forKey: .enclosures) ?? d.enclosures
    }

    /// Street / city lines (empty ones dropped).
    public var addressLines: [String] { [street, city].filter { !$0.isEmpty } }
    public var contactItems: [String] { [email, phone, linkedin].filter { !$0.isEmpty } }
}

// MARK: - Formatting helpers (same rules as jobhunter/letter_doc.py)

public enum LetterFormatting {
    public static let defaultSalutation = "Sehr geehrte Damen und Herren,"
    public static let closing = "Mit freundlichen Grüßen"

    private static let gender = try! NSRegularExpression(
        pattern: "[\\(\\[\\{]?\\s*(?:(?<![a-z])[mwfdxi]\\s*/\\s*[mwfdxi](?:\\s*/\\s*[mwfdxi])?(?:\\s*/\\s*[mwfdxi])?(?![a-z])"
            + "|all\\s+genders?|alle\\s+geschlechter|(?<![a-z])gn\\*?(?![a-z])|m\\*w\\*d)\\s*[\\)\\]\\}]?",
        options: [.caseInsensitive])
    private static let name = "[A-ZÄÖÜ][a-zäöüß]+(?:-[A-ZÄÖÜ][a-zäöüß]+)?"
    private static let contact = try! NSRegularExpression(
        pattern: "(?:Ansprechpartner(?:in)?|Ansprechperson|Kontaktperson)\\b[^\\n:]{0,40}?[:\\-–]?\\s*"
            + "(Frau|Herrn?)\\s+((?:(?:Dr|Prof)\\.\\s*)*)(\(name))(?:[ \\t]+(\(name)))?(?![\\wäöüß])")
    private static let anotherPerson = try! NSRegularExpression(pattern: "\\b(?:Frau|Herrn?)\\s+[A-ZÄÖÜ]")
    private static let notNames: Set<String> = [
        "Damen", "Herren", "Kollegin", "Kollege", "Bewerber", "Bewerberin", "Ansprechpartner",
        "Ansprechpartnerin", "Personal", "Recruiting", "Team", "Frau", "Herr", "Herrn", "Oder", "Und"]

    private static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func trim(_ s: String, _ chars: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: chars).union(.whitespaces))
    }

    /// Title without "(m/w/d)" and without a leading "<Company>: " prefix.
    public static func letterTitle(_ title: String, company: String?) -> String {
        let ns = title as NSString
        var t = gender.stringByReplacingMatches(in: title, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        t = trim(collapse(t), "-–|,:")
        let comp = (company ?? "").trimmingCharacters(in: .whitespaces)
        if !comp.isEmpty, t.lowercased().hasPrefix(comp.lowercased()) {
            let rest = t.dropFirst(comp.count).drop(while: { $0 == " " })
            if let first = rest.first, ":-–|".contains(first) {
                t = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces)
            }
        }
        t = t.replacingOccurrences(of: "\\(\\s*\\)", with: "", options: .regularExpression)
        return trim(collapse(t), "-–|,:")
    }

    /// "Sehr geehrte Frau X," / "Sehr geehrter Herr X," only if the posting clearly names exactly
    /// one contact person ("Ansprechpartnerin: Frau Anna Schmidt"); otherwise the default.
    public static func salutation(for description: String) -> String {
        let ns = description as NSString
        var people = Set<String>()
        for m in contact.matches(in: description, range: NSRange(location: 0, length: ns.length)) {
            let end = m.range.location + m.range.length
            let window = NSRange(location: end, length: min(60, ns.length - end))
            if anotherPerson.firstMatch(in: description, range: window) != nil { return defaultSalutation }
            func group(_ i: Int) -> String? {
                let r = m.range(at: i)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            let isWoman = group(1) == "Frau"
            let first = group(3) ?? ""
            let last = group(4) ?? first
            if notNames.contains(last) || (group(4) != nil && notNames.contains(first)) { continue }
            let titles = (group(2) ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let full = titles.isEmpty ? last : "\(titles) \(last)"
            people.insert((isWoman ? "F|" : "M|") + full)
        }
        guard people.count == 1, let p = people.first else { return defaultSalutation }
        let who = String(p.dropFirst(2))
        return p.hasPrefix("F|") ? "Sehr geehrte Frau \(who)," : "Sehr geehrter Herr \(who),"
    }

    /// Letters/digits (incl. umlauts), "." and "-" stay; everything else becomes "_".
    public static func sanitizeFilenamePart(_ text: String, maxLength: Int = 60) -> String {
        var out = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_" { out.append(ch) } else { out.append("_") }
        }
        out = out.replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
        out = String(out.prefix(maxLength)).trimmingCharacters(in: CharacterSet(charactersIn: "_.-"))
        return out.isEmpty ? "Unbekannt" : out
    }

    static let berlin = TimeZone(identifier: "Europe/Berlin") ?? .current

    static func format(_ date: Date, _ pattern: String) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.timeZone = berlin
        f.dateFormat = pattern
        return f.string(from: date)
    }

    public static func pdfFilename(company: String?, date: Date) -> String {
        "Anschreiben_\(sanitizeFilenamePart(company ?? ""))_\(format(date, "yyyy-MM-dd")).pdf"
    }
}

// MARK: - Document

/// The full cover letter (DIN-5008-like), same fields and layout as the server's print page/PDF
/// (`/jobs/{id}/anschreiben`, `GET /api/v1/jobs/{id}/letter-document`).
public struct LetterDocument: Sendable, Hashable {
    public var sender: Applicant
    public var recipientLines: [String]
    public var date: String
    public var placeDate: String
    public var subject: String
    public var salutation: String
    public var body: [String]
    public var closing: String
    public var signature: String
    public var enclosures: [String]
    public var filename: String
    public var hasPlaceholder: Bool

    public static func build(title: String, company: String?, location: String?, description: String,
                             letter: String, applicant: Applicant, date: Date = .now) -> LetterDocument {
        let comp = (company ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let loc = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let t = LetterFormatting.letterTitle(title, company: comp)
        let day = LetterFormatting.format(date, "dd.MM.yyyy")
        return LetterDocument(
            sender: applicant,
            recipientLines: [comp, loc].filter { !$0.isEmpty },
            date: day,
            placeDate: applicant.city.isEmpty ? day : "\(applicant.city), \(day)",
            subject: t.isEmpty ? "Bewerbung" : "Bewerbung als \(t)",
            salutation: LetterFormatting.salutation(for: description),
            body: LetterOutputCleaner.paragraphs(letter),
            closing: LetterFormatting.closing,
            signature: applicant.name,
            enclosures: applicant.enclosures,
            filename: LetterFormatting.pdfFilename(company: comp, date: date),
            hasPlaceholder: letter.range(of: "\\[[^\\]\\n]{0,200}\\]|\\.\\.\\.\\]|\\[\\.\\.\\.", options: .regularExpression) != nil)
    }

    public static func build(job: JobDetail, letter: String? = nil, applicant: Applicant, date: Date = .now) -> LetterDocument {
        build(title: job.summary.title, company: job.summary.company, location: job.summary.location,
              description: job.description, letter: letter ?? job.letter, applicant: applicant, date: date)
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Self-contained A4 page (210 × 297 mm, Arial, accent #1E5F66 like the CV). A small script
    /// shrinks the body font in steps until everything fits on one page.
    public var html: String {
        let senderLine = (sender.addressLines + sender.contactItems).map(Self.esc).joined(separator: "  ·  ")
        let backLine = ([sender.name] + sender.addressLines).map(Self.esc).joined(separator: ", ")
        let recipient = recipientLines.map { "<div>\(Self.esc($0))</div>" }.joined()
        let paras = body.map { "<p>\(Self.esc($0))</p>" }.joined(separator: "\n")
        let encl = enclosures.isEmpty ? "" : "<p class=\"encl\">Anlage: \(Self.esc(enclosures.joined(separator: ", ")))</p>"
        return """
        <!doctype html>
        <html lang="de"><head><meta charset="utf-8"><title>\(Self.esc(String(filename.dropLast(4))))</title>
        <style>
          @page { size: A4; margin: 0; }
          * { box-sizing: border-box; }
          html, body { margin: 0; padding: 0; background: #fff; color: #222; }
          body { font-family: Arial, "Liberation Sans", Helvetica, sans-serif; }
          .page { width: 210mm; height: 297mm; overflow: hidden; position: relative; background: #fff;
                  padding: 16mm 20mm 15mm 25mm; font-size: var(--fs, 11pt); line-height: 1.4; }
          .name { font-size: 20pt; font-weight: bold; color: #1E5F66; line-height: 1.2; }
          .contact { font-size: 9pt; color: #555; margin-top: 1mm; padding-bottom: 2.5mm; border-bottom: 0.6mm solid #1E5F66; }
          .address { position: absolute; top: 45mm; left: 25mm; width: 85mm; font-size: 11pt; }
          .backline { font-size: 7.5pt; color: #555; margin-bottom: 1.5mm; }
          .date { position: absolute; top: 88mm; right: 20mm; font-size: 11pt; }
          .content { margin-top: 67mm; }
          .subject { font-weight: bold; font-size: 12pt; margin: 0 0 6mm; }
          .content p { margin: 0 0 0.7em; }
          .sign { margin-top: 2.2em !important; }
          .encl { margin-top: 1.2em !important; font-size: 0.86em; color: #555; }
        </style></head>
        <body><main class="page" id="page">
          <div class="name">\(Self.esc(sender.name))</div>
          <div class="contact">\(senderLine)</div>
          <div class="address"><div class="backline">\(backLine)</div>\(recipient)</div>
          <div class="date">\(Self.esc(placeDate))</div>
          <div class="content" id="content">
            <p class="subject">\(Self.esc(subject))</p>
            <p>\(Self.esc(salutation))</p>
        \(paras)
            <p>\(Self.esc(closing))</p>
            <p class="sign">\(Self.esc(signature))</p>
            \(encl)
          </div>
        </main>
        <script>
          (function () {
            var page = document.getElementById('page');
            var sizes = [11, 10.5, 10, 9.5, 9];
            for (var i = 0; i < sizes.length; i++) {
              page.style.setProperty('--fs', sizes[i] + 'pt');
              if (page.scrollHeight <= page.clientHeight + 1) break;
            }
          })();
        </script>
        </body></html>
        """
    }
}

// MARK: - PDF helpers

public enum LetterPDF {
    /// A4 in PostScript points.
    public static let a4 = CGRect(x: 0, y: 0, width: 595.2756, height: 841.8898)
    /// 210 × 297 mm in CSS pixels (96 dpi) – the size WebKit renders the page at.
    public static let cssPageSize = CGSize(width: 793.7, height: 1122.5)

    /// Rescales the first page of `data` to an A4 page (vector content is kept).
    /// WKWebView.createPDF renders 1 CSS px = 1 pt, so the 210 mm page comes out 1/0.75 too large.
    public static func scaleFirstPageToA4(_ data: Data) -> Data? {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider),
              let page = doc.page(at: 1) else { return nil }
        let src = page.getBoxRect(.mediaBox)
        let out = NSMutableData()
        var box = a4
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, [kCGPDFContextCreator: "JobHunter"] as CFDictionary)
        else { return nil }
        ctx.beginPDFPage(nil)
        let scale = min(a4.width / src.width, a4.height / src.height)
        ctx.translateBy(x: 0, y: a4.height - src.height * scale)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -src.origin.x, y: -src.origin.y)
        ctx.drawPDFPage(page)
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }

    public static func pageCount(_ data: Data) -> Int {
        guard let provider = CGDataProvider(data: data as CFData), let doc = CGPDFDocument(provider) else { return 0 }
        return doc.numberOfPages
    }
}
