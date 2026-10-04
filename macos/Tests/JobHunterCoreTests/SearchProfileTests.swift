import Foundation
import Testing
@testable import JobHunterCore

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

// Fixtures recorded from the local backend (search_profile, suggestions, search_preview);
// cv_profile is synthetic (no real profile data in the repo).
@Suite("Suchprofil – Decoding & Encoding")
struct SearchProfileModelTests {
    @Test func decodePayload() throws {
        let p = try APIClient.decode(SearchProfilePayload.self, from: fixture("search_profile"), using: APIClient.plainDecoder)
        #expect(p.profile.queries.first == "Support Engineer")
        #expect(p.profile.radiusKm == 30 && p.profile.remoteOk && p.profile.minSalary == 44000)
        #expect(p.profile.keywordWeights["Nextcloud"] == 4)
        #expect(p.base == p.profile && p.overridden.isEmpty)
        let ids = p.sources.map(\.id)
        #expect(ids.contains("arbeitsagentur") && ids.contains("ats") && ids.contains("remotive"))
        let ba = try #require(p.sources.first { $0.id == "arbeitsagentur" })
        #expect(ba.enabled && ba.intRange("max_pages") == 1...5 && ba.hasOption("remote_search"))
        let remotive = try #require(p.sources.first { $0.id == "remotive" })
        #expect(!remotive.enabled && remotive.choices("category").contains("customer-support"))
        let adzuna = try #require(p.sources.first { $0.id == "adzuna" })
        #expect(!adzuna.configured && adzuna.reason?.contains("ADZUNA") == true)
        #expect(p.atsExamples.contains { $0.token == "sumup" && $0.ats == "greenhouse" })
        #expect(p.atsTypes["smartrecruiters"] == "SmartRecruiters")
    }

    @Test func keywordKeysAreNotConverted() throws {
        let json = Data(#"{"queries":["a"],"location":"B","radius_km":1,"remote_ok":false,"days_back":3,"min_salary":0,"target_titles":[],"excluded_title_keywords":[],"excluded_keywords":[],"keyword_weights":{"second_level":2,"Microsoft 365":1},"keyword_saturation":15,"extra_locations":[]}"#.utf8)
        let p = try APIClient.decode(SearchProfileData.self, from: json, using: APIClient.plainDecoder)
        #expect(p.keywordWeights["second_level"] == 2 && p.keywordWeights["Microsoft 365"] == 1)
    }

    @Test func decodePreviewSuggestionsCV() throws {
        let prev = try APIClient.decode(SearchPreview.self, from: fixture("search_preview"), using: APIClient.plainDecoder)
        let q = try #require(prev.queries.first)
        #expect(q.query == "Support Engineer" && (q.arbeitsagentur?.local ?? 0) > 0)
        #expect(q.samples?.isEmpty == false && q.feeds["remotive"] != nil)
        #expect(prev.sources.contains { $0.id == "ats" && ($0.fetched ?? 0) > 0 })
        let s = try APIClient.decode(ProfileSuggestions.self, from: fixture("suggestions"), using: APIClient.plainDecoder)
        #expect(!s.queries.isEmpty && s.queries.allSatisfy { $0.kind == "query" && !$0.reason.isEmpty })
        #expect(s.likedJobs == 4)
        let cv = try APIClient.decode(CVProfileData.self, from: fixture("cv_profile"), using: APIClient.plainDecoder)
        #expect(cv.keywords == 2 && cv.backup?.hasPrefix("cv_profile.backup-") == true && cv.rescoreStarted == true)
    }

    @Test func updateEncoding() throws {
        var p = SearchProfileData(queries: ["Cloud Support"], keywordWeights: ["Linux": 2])
        p.radiusKm = 50
        let change = SearchProfileUpdate.SourceChange(
            enabled: true, options: SourceOptions(companies: [ATSCompany(ats: "greenhouse", token: "sumup", name: "SumUp")]))
        let u = SearchProfileUpdate(profile: p, sources: ["ats": change, "remotive": .init(enabled: false, options: SourceOptions())],
                                    runNow: true)
        let obj = try #require(JSONSerialization.jsonObject(with: try APIClient.encoder.encode(u)) as? [String: Any])
        #expect(obj["run_now"] as? Bool == true && obj["rescore"] as? Bool == true)
        let prof = try #require(obj["profile"] as? [String: Any])
        #expect(prof["radius_km"] as? Int == 50 && prof["queries"] as? [String] == ["Cloud Support"])
        #expect((prof["keyword_weights"] as? [String: Double])?["Linux"] == 2)
        let src = try #require(obj["sources"] as? [String: [String: Any]])
        #expect(src["remotive"]?.keys.sorted() == ["enabled"])             // nil options are not sent
        let companies = try #require(src["ats"]?["companies"] as? [[String: Any]])
        #expect(companies.first?["token"] as? String == "sumup" && src["ats"]?["enabled"] as? Bool == true)
        // preview body: no run_now / rescore
        let prev = try #require(JSONSerialization.jsonObject(with: try APIClient.encoder.encode(u.previewBody)) as? [String: Any])
        #expect(Set(prev.keys) == ["profile", "sources"])
        // no sources changed → key omitted
        let only = try #require(JSONSerialization.jsonObject(with: try APIClient.encoder.encode(
            SearchProfileUpdate(profile: p, sources: [:]))) as? [String: Any])
        #expect(only["sources"] == nil)
    }

    @Test func validationAndChips() {
        var p = SearchProfileData(queries: ["  "], location: "")
        #expect(p.validationErrors().count == 2)
        p.queries = (1...31).map { "q\($0)" }
        p.location = "Berlin"
        #expect(p.validationErrors() == ["Höchstens 30 Suchbegriffe."])
        p.queries = ["Support"]; p.radiusKm = 300; p.keywordWeights = ["x": 12]
        #expect(p.validationErrors().count == 2)
        var list = ["Support Engineer"]
        #expect(!addUnique("support  engineer", to: &list))
        #expect(addUnique("  Cloud   Support ", to: &list) && list == ["Support Engineer", "Cloud Support"])
        #expect(!addUnique("   ", to: &list))
    }
}

private func lastJSON() throws -> [String: Any] {
    let data = try #require(StubProtocol.lastBody)
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

extension RequestTests {
    @Test func searchProfileRequests() async throws {
        let payload = try fixture("search_profile")
        let preview = try fixture("search_preview")
        let cv = try fixture("cv_profile")
        StubProtocol.handler = { req in
            let path = req.url!.path()
            if path.hasSuffix("/preview") { return .init(status: 200, body: preview, error: nil) }
            if path.hasSuffix("/cv-profile") { return .init(status: 200, body: cv, error: nil) }
            return .init(status: 200, body: payload, error: nil)
        }
        _ = try await client.searchProfile()
        #expect(StubProtocol.lastRequest?.httpMethod == "GET")
        #expect(StubProtocol.lastRequest?.url?.path() == "/jh/api/v1/search-profile")

        let u = SearchProfileUpdate(profile: SearchProfileData(queries: ["A"]), runNow: true)
        let saved = try await client.saveSearchProfile(u)
        #expect(saved.profile.queries.count == 6)
        #expect(StubProtocol.lastRequest?.httpMethod == "PUT")
        #expect(StubProtocol.lastRequest?.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try lastJSON()
        #expect(body["run_now"] as? Bool == true)

        _ = try await client.previewSearchProfile(u)
        #expect(StubProtocol.lastRequest?.httpMethod == "POST")
        #expect(StubProtocol.lastRequest?.url?.path() == "/jh/api/v1/search-profile/preview")

        _ = try await client.resetSearchProfile()
        #expect(StubProtocol.lastRequest?.url?.path() == "/jh/api/v1/search-profile/reset")
        let reset = try JSONSerialization.jsonObject(with: try #require(StubProtocol.lastBody)) as? [String: String]
        #expect(reset == ["what": "all"])

        let c = try await client.saveCVProfile(text: "# Neu")
        #expect(c.backup != nil && StubProtocol.lastRequest?.httpMethod == "PUT")
        let cvBody = try lastJSON()
        #expect(cvBody["text"] as? String == "# Neu" && cvBody["rescore"] as? Bool == true)
    }

    @Test func searchProfileErrors() async throws {
        StubProtocol.handler = { _ in .init(status: 422, body: Data(#"{"detail":"queries: mindestens ein Suchbegriff nötig","errors":{"queries":"mindestens ein Suchbegriff nötig"}}"#.utf8), error: nil) }
        await #expect(throws: APIError.server(status: 422, detail: "queries: mindestens ein Suchbegriff nötig")) {
            try await client.saveSearchProfile(SearchProfileUpdate(profile: SearchProfileData()))
        }
        StubProtocol.handler = { _ in .init(status: 429, body: Data(#"{"detail":"Eine Vorschau läuft bereits – bitte kurz warten."}"#.utf8), error: nil) }
        await #expect(throws: APIError.server(status: 429, detail: "Eine Vorschau läuft bereits – bitte kurz warten.")) {
            try await client.previewSearchProfile(SearchProfileUpdate(profile: nil))
        }
        StubProtocol.handler = { _ in .init(status: 404, body: Data(#"{"detail":"Not Found"}"#.utf8), error: nil) }
        await #expect(throws: APIError.notFound) { try await client.searchProfile() }
    }
}
