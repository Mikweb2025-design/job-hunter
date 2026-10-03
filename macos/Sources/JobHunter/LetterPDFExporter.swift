import AppKit
import JobHunterCore
import WebKit

/// Renders a `LetterDocument` (HTML, A4) to a one-page PDF with WebKit – offline, no server.
@MainActor
final class LetterPDFExporter: NSObject, WKNavigationDelegate {
    enum ExportError: LocalizedError {
        case render(String)
        case noLetter

        var errorDescription: String? {
            switch self {
            case .render(let msg): "PDF konnte nicht erstellt werden: \(msg)"
            case .noLetter: "Kein Anschreiben vorhanden – zuerst schreiben oder mit KI erstellen."
            }
        }
    }

    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?

    /// PDF data of `doc` (A4, 1 page).
    func pdfData(for doc: LetterDocument) async throws -> Data {
        let size = LetterPDF.cssPageSize
        let web = WKWebView(frame: CGRect(origin: .zero, size: size))
        web.navigationDelegate = self
        webView = web
        defer { webView = nil }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            loaded = cont
            web.loadHTMLString(doc.html, baseURL: nil)
        }
        // Let the fit-to-page script and layout settle.
        _ = try? await web.evaluateJavaScript("document.getElementById('page').scrollHeight")
        let config = WKPDFConfiguration()
        config.rect = CGRect(origin: .zero, size: size)
        let raw: Data = try await withCheckedThrowingContinuation { cont in
            web.createPDF(configuration: config) { result in
                switch result {
                case .success(let data): cont.resume(returning: data)
                case .failure(let error): cont.resume(throwing: ExportError.render(error.localizedDescription))
                }
            }
        }
        guard let a4 = LetterPDF.scaleFirstPageToA4(raw) else { throw ExportError.render("Skalierung auf A4") }
        return a4
    }

    /// Writes the PDF into `folder` (created if needed) as `doc.filename`; returns the file URL.
    func save(_ doc: LetterDocument, folder: String) async throws -> URL {
        guard !doc.body.isEmpty else { throw ExportError.noLetter }
        let dir = URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: doc.filename)
        try await pdfData(for: doc).write(to: url, options: .atomic)
        return url
    }

    /// Temporary copy for "Vorschau" (opened in Preview).
    func preview(_ doc: LetterDocument) async throws -> URL {
        guard !doc.body.isEmpty else { throw ExportError.noLetter }
        let dir = FileManager.default.temporaryDirectory.appending(path: "JobHunter-Vorschau", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: doc.filename)
        try await pdfData(for: doc).write(to: url, options: .atomic)
        return url
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            loaded?.resume()
            loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            loaded?.resume(throwing: ExportError.render(error.localizedDescription))
            loaded = nil
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            loaded?.resume(throwing: ExportError.render(error.localizedDescription))
            loaded = nil
        }
    }
}
