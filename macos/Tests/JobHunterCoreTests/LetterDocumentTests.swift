import CoreGraphics
import Foundation
import Testing
@testable import JobHunterCore

@Suite("Anschreiben als Dokument / PDF")
struct LetterDocumentTests {
    let day = ISO8601DateFormatter().date(from: "2026-10-03T10:00:00Z")!

    @Test(arguments: [
        ("Ihre Ansprechpartnerin: Frau Anna Schmidt, Recruiting", "Sehr geehrte Frau Schmidt,"),
        ("Ansprechpartner:\nHerr Jörg Müller-Lüdenscheidt\nTel. 030 123", "Sehr geehrter Herr Müller-Lüdenscheidt,"),
        ("Ansprechpartner für Rückfragen: Herr Dr. Özdemir", "Sehr geehrter Herr Dr. Özdemir,"),
        ("Kontaktperson – Frau Weiß", "Sehr geehrte Frau Weiß,"),
        ("Wir sind Ihre Ansprechpartner, die jederzeit erreichbar sind.", LetterFormatting.defaultSalutation),
        ("Ansprechpartner: Frau Anna Schmidt oder Herr Max Meier", LetterFormatting.defaultSalutation),
        ("Bitte wenden Sie sich an Frau Schmidt.", LetterFormatting.defaultSalutation),
        ("Ansprechpartner:innen im Team", LetterFormatting.defaultSalutation),
        ("", LetterFormatting.defaultSalutation),
    ])
    func salutation(text: String, expected: String) {
        #expect(LetterFormatting.salutation(for: text) == expected)
    }

    @Test func titleCleaning() {
        #expect(LetterFormatting.letterTitle("SoftwareOne Deutschland GmbH: Power Platform Support Engineer (gn)",
                                             company: "SoftwareOne Deutschland GmbH") == "Power Platform Support Engineer")
        #expect(LetterFormatting.letterTitle("Support Engineer (m/w/d)", company: "Acme") == "Support Engineer")
        #expect(LetterFormatting.letterTitle("Software Engineer (all genders)", company: nil) == "Software Engineer")
    }

    @Test func filenameSanitizing() {
        #expect(LetterFormatting.pdfFilename(company: "Müller & Söhne GmbH / Berlin", date: day)
                == "Anschreiben_Müller_Söhne_GmbH_Berlin_2026-10-03.pdf")
        #expect(LetterFormatting.pdfFilename(company: "]init[ AG", date: day) == "Anschreiben_init_AG_2026-10-03.pdf")
        #expect(LetterFormatting.pdfFilename(company: nil, date: day) == "Anschreiben_Unbekannt_2026-10-03.pdf")
        #expect(LetterFormatting.sanitizeFilenamePart("a:b\\c?d*e\"f<g>h|i") == "a_b_c_d_e_f_g_h_i")
        #expect(LetterFormatting.sanitizeFilenamePart(String(repeating: "x", count: 200)).count == 60)
    }

    @Test func buildsAllFields() {
        let doc = LetterDocument.build(
            title: "Cloud Support Engineer (m/w/d)", company: "Acme GmbH", location: "10115 Berlin",
            description: "Ansprechpartnerin: Frau Erika Müßig", letter: "Absatz eins.\n\nAbsatz zwei.\nNoch zwei.",
            applicant: .standard, date: day)
        #expect(doc.sender.name == "Daniele Michelin")
        #expect(doc.sender.contactItems == ["info@daniele-michelin.com", "+49 160 7804710",
                                            "linkedin.com/in/daniele-michelin-02863143b"])
        #expect(doc.recipientLines == ["Acme GmbH", "10115 Berlin"])
        #expect(doc.placeDate == "Berlin, 03.10.2026")
        #expect(doc.subject == "Bewerbung als Cloud Support Engineer")
        #expect(doc.salutation == "Sehr geehrte Frau Müßig,")
        #expect(doc.body == ["Absatz eins.", "Absatz zwei. Noch zwei."])
        #expect(doc.closing == "Mit freundlichen Grüßen" && doc.signature == "Daniele Michelin")
        #expect(doc.enclosures == ["Lebenslauf"])
        #expect(doc.filename == "Anschreiben_Acme_GmbH_2026-10-03.pdf")
        #expect(!doc.hasPlaceholder)
        let html = doc.html
        for part in ["Sehr geehrte Frau Müßig,", "Bewerbung als Cloud Support Engineer", "Mit freundlichen Grüßen",
                     "Anlage: Lebenslauf", "#1E5F66", "size: A4", "<p>Absatz zwei. Noch zwei.</p>", "Berlin, 03.10.2026"] {
            #expect(html.contains(part), "missing \(part)")
        }
    }

    @Test func escapesHTMLAndDetectsPlaceholders() {
        let doc = LetterDocument.build(title: "Dev <script>", company: "A & B", location: nil, description: "",
                                       letter: "Text [Firma ergänzen]", applicant: .standard, date: day)
        #expect(doc.html.contains("A &amp; B") && !doc.html.contains("<script>alert"))
        #expect(doc.html.contains("Dev &lt;script&gt;"))
        #expect(doc.hasPlaceholder)
    }

    @Test func applicantDecodesFromServerSettings() throws {
        let json = #"{"name":"Erika Muster","street":"","city":"Köln","email":"e@x.de","phone":"1","linkedin":"l","enclosures":["Lebenslauf","Zeugnisse"]}"#
        let a = try JSONDecoder().decode(Applicant.self, from: Data(json.utf8))
        #expect(a.city == "Köln" && a.enclosures == ["Lebenslauf", "Zeugnisse"])
        let partial = try JSONDecoder().decode(Applicant.self, from: Data(#"{"name":"X"}"#.utf8))
        #expect(partial.email == Applicant.standard.email)
    }

    @Test func scalesPDFPageToA4() throws {
        // A 793.7 × 1122.5 pt page (what WebKit renders for 210 × 297 mm) → A4 in points.
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: LetterPDF.cssPageSize)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0.12, green: 0.37, blue: 0.4, alpha: 1))
        ctx.fill(CGRect(x: 10, y: 10, width: 100, height: 100))
        ctx.endPDFPage()
        ctx.closePDF()
        let a4 = try #require(LetterPDF.scaleFirstPageToA4(data as Data))
        #expect(LetterPDF.pageCount(a4) == 1)
        let page = try #require(CGPDFDocument(CGDataProvider(data: a4 as CFData)!)?.page(at: 1))
        let r = page.getBoxRect(.mediaBox)
        #expect(abs(r.width - 595.28) < 0.1 && abs(r.height - 841.89) < 0.1)
    }
}
