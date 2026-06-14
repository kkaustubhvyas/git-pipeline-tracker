import XCTest
@testable import PipelineTracker

// MARK: - ProjectFilter

final class ProjectFilterTests: XCTestCase {

    func test_empty_matchesAnyRef() {
        let f = ProjectFilter()
        XCTAssertTrue(f.isEmpty)
        XCTAssertTrue(f.matches(ref: "main"))
        XCTAssertTrue(f.matches(ref: "feature/anything"))
        XCTAssertTrue(f.matches(ref: ""))
    }

    func test_exactPattern_matchesExact() {
        let f = ProjectFilter(refPatterns: ["main"])
        XCTAssertTrue(f.matches(ref: "main"))
        XCTAssertFalse(f.matches(ref: "master"))
        XCTAssertFalse(f.matches(ref: "main-branch"))
    }

    func test_starAlone_matchesAll() {
        let f = ProjectFilter(refPatterns: ["*"])
        XCTAssertTrue(f.matches(ref: "anything"))
        XCTAssertTrue(f.matches(ref: ""))
    }

    func test_prefixGlob() {
        let f = ProjectFilter(refPatterns: ["deploy/*"])
        XCTAssertTrue(f.matches(ref: "deploy/prod"))
        XCTAssertTrue(f.matches(ref: "deploy/staging"))
        XCTAssertFalse(f.matches(ref: "feature/deploy"))
        XCTAssertFalse(f.matches(ref: "main"))
    }

    func test_suffixGlob() {
        let f = ProjectFilter(refPatterns: ["*/hotfix"])
        XCTAssertTrue(f.matches(ref: "release/hotfix"))
        XCTAssertTrue(f.matches(ref: "feature/hotfix"))
        XCTAssertFalse(f.matches(ref: "hotfix/patch"))
    }

    func test_middleGlob() {
        let f = ProjectFilter(refPatterns: ["release/*-stable"])
        XCTAssertTrue(f.matches(ref: "release/v1-stable"))
        XCTAssertTrue(f.matches(ref: "release/v2.0-stable"))
        XCTAssertFalse(f.matches(ref: "release/v1-unstable"))
        XCTAssertFalse(f.matches(ref: "feature/v1-stable"))
    }

    func test_multiplePatterns_anyMatch() {
        let f = ProjectFilter(refPatterns: ["main", "deploy/*"])
        XCTAssertTrue(f.matches(ref: "main"))
        XCTAssertTrue(f.matches(ref: "deploy/prod"))
        XCTAssertFalse(f.matches(ref: "feature/x"))
    }

    func test_nonEmptyFilter_isNotEmpty() {
        let f = ProjectFilter(refPatterns: ["main"])
        XCTAssertFalse(f.isEmpty)
    }

    func test_exactPatternNoWildcard_emptyRef_noMatch() {
        let f = ProjectFilter(refPatterns: ["main"])
        XCTAssertFalse(f.matches(ref: ""))
    }

    func test_codableRoundtrip() throws {
        let original = ProjectFilter(refPatterns: ["main", "deploy/*"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProjectFilter.self, from: data)
        XCTAssertEqual(decoded.refPatterns, original.refPatterns)
    }
}

// MARK: - PipelineStatus

final class PipelineStatusTests: XCTestCase {

    func test_activeStatuses() {
        for s in [PipelineStatus.created, .waitingForResource, .preparing, .pending, .running] {
            XCTAssertTrue(s.isActive, "\(s) should be active")
        }
    }

    func test_inactiveStatuses() {
        for s in [PipelineStatus.success, .failed, .canceled, .skipped, .manual, .scheduled] {
            XCTAssertFalse(s.isActive, "\(s) should not be active")
        }
    }

    func test_allCasesHaveNonEmptyDisplayName() {
        let all: [PipelineStatus] = [.created, .waitingForResource, .preparing, .pending, .running,
                                      .success, .failed, .canceled, .skipped, .manual, .scheduled]
        for s in all { XCTAssertFalse(s.displayName.isEmpty) }
    }

    func test_allCasesHaveNonEmptySystemImage() {
        let all: [PipelineStatus] = [.created, .waitingForResource, .preparing, .pending, .running,
                                      .success, .failed, .canceled, .skipped, .manual, .scheduled]
        for s in all { XCTAssertFalse(s.systemImage.isEmpty) }
    }

    func test_rawValues() {
        XCTAssertEqual(PipelineStatus.waitingForResource.rawValue, "waiting_for_resource")
        XCTAssertEqual(PipelineStatus.success.rawValue, "success")
        XCTAssertEqual(PipelineStatus.running.rawValue, "running")
    }

    func test_decodableFromRawValue() throws {
        let json = #"{"id":1,"status":"running","ref":"main","sha":"abc","web_url":"https://x.com","created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:01:00Z"}"#
        let dec = JSONDecoder()
        let isoShort = ISO8601DateFormatter()
        dec.dateDecodingStrategy = .custom { d in
            let c = try d.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = isoShort.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad date")
        }
        let pipeline = try dec.decode(Pipeline.self, from: Data(json.utf8))
        XCTAssertEqual(pipeline.status, .running)
    }
}

// MARK: - PipelineSortOrder

final class PipelineSortOrderTests: XCTestCase {

    func test_allCasesCount() {
        XCTAssertEqual(PipelineSortOrder.allCases.count, 2)
    }

    func test_rawValues() {
        XCTAssertEqual(PipelineSortOrder.timeStarted.rawValue, "time_started")
        XCTAssertEqual(PipelineSortOrder.timeFinished.rawValue, "time_finished")
    }

    func test_nonEmptyDisplayNames() {
        for o in PipelineSortOrder.allCases { XCTAssertFalse(o.displayName.isEmpty) }
    }

    func test_nonEmptySystemImages() {
        for o in PipelineSortOrder.allCases { XCTAssertFalse(o.systemImage.isEmpty) }
    }

    func test_roundtripRawValue() {
        for o in PipelineSortOrder.allCases {
            XCTAssertEqual(PipelineSortOrder(rawValue: o.rawValue), o)
        }
    }

    func test_unknownRawValue_returnsNil() {
        XCTAssertNil(PipelineSortOrder(rawValue: "unknown"))
    }
}

// MARK: - Provider

final class ProviderTests: XCTestCase {

    func test_allCasesCount() {
        XCTAssertEqual(Provider.allCases.count, 2)
    }

    func test_displayNames() {
        XCTAssertEqual(Provider.gitlab.displayName, "GitLab")
        XCTAssertEqual(Provider.github.displayName, "GitHub")
    }

    func test_defaultBaseURLs() {
        XCTAssertEqual(Provider.gitlab.defaultBaseURL, "https://gitlab.com")
        XCTAssertEqual(Provider.github.defaultBaseURL, "https://github.com")
    }

    func test_logoImageNames() {
        XCTAssertEqual(Provider.gitlab.logoImageName, "gitlab-logo")
        XCTAssertEqual(Provider.github.logoImageName, "github-logo")
    }

    func test_tokenPlaceholders() {
        XCTAssertTrue(Provider.gitlab.tokenPlaceholder.hasPrefix("glpat-"))
        XCTAssertTrue(Provider.github.tokenPlaceholder.hasPrefix("ghp_"))
    }

    func test_tokenScopeHints() {
        XCTAssertTrue(Provider.gitlab.tokenScopeHint.contains("read_api"))
        XCTAssertTrue(Provider.github.tokenScopeHint.contains("repo"))
    }

    func test_codableRoundtrip() throws {
        for p in Provider.allCases {
            let data = try JSONEncoder().encode(p)
            let decoded = try JSONDecoder().decode(Provider.self, from: data)
            XCTAssertEqual(decoded, p)
        }
    }
}

// MARK: - Account Codable

final class AccountCodableTests: XCTestCase {

    func test_encodeDecodeRoundtrip() throws {
        let id = UUID()
        let original = Account(
            id: id, name: "Work GitLab",
            provider: .gitlab, baseURL: "https://gitlab.com",
            watchedProjectIds: [1, 2, 3],
            projectFilters: ["1": ProjectFilter(refPatterns: ["main", "deploy/*"])]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Account.self, from: data)

        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.name, "Work GitLab")
        XCTAssertEqual(decoded.provider, .gitlab)
        XCTAssertEqual(decoded.baseURL, "https://gitlab.com")
        XCTAssertEqual(decoded.watchedProjectIds, [1, 2, 3])
        XCTAssertEqual(decoded.projectFilters["1"]?.refPatterns, ["main", "deploy/*"])
    }

    func test_decodesLegacyGitlabURLKey() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "Legacy",
            "watchedProjectIds": [],
            "gitlabURL": "https://gitlab.mycompany.com"
        }
        """.data(using: .utf8)!
        let account = try JSONDecoder().decode(Account.self, from: json)
        XCTAssertEqual(account.baseURL, "https://gitlab.mycompany.com")
        XCTAssertEqual(account.provider, .gitlab)
    }

    func test_decodesWithMissingOptionalFields_usesDefaults() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "Minimal",
            "watchedProjectIds": [42]
        }
        """.data(using: .utf8)!
        let account = try JSONDecoder().decode(Account.self, from: json)
        XCTAssertEqual(account.provider, .gitlab)
        XCTAssertEqual(account.baseURL, "https://gitlab.com")
        XCTAssertTrue(account.projectFilters.isEmpty)
        XCTAssertEqual(account.watchedProjectIds, [42])
    }

    func test_decodesGitHubProvider() throws {
        let json = """
        {
            "id": "12345678-1234-1234-1234-123456789012",
            "name": "GitHub",
            "provider": "github",
            "baseURL": "https://github.com",
            "watchedProjectIds": []
        }
        """.data(using: .utf8)!
        let account = try JSONDecoder().decode(Account.self, from: json)
        XCTAssertEqual(account.provider, .github)
    }

    func test_filterForKnownProjectId() {
        let filter = ProjectFilter(refPatterns: ["main"])
        let account = Account(name: "Test", projectFilters: ["42": filter])
        XCTAssertEqual(account.filter(for: 42).refPatterns, ["main"])
    }

    func test_filterForUnknownProjectId_returnsEmptyFilter() {
        let account = Account(name: "Test")
        XCTAssertTrue(account.filter(for: 999).isEmpty)
    }

    func test_defaultInit_usesProviderDefaultURL() {
        let account = Account(name: "Test", provider: .github)
        XCTAssertEqual(account.baseURL, "https://github.com")
    }
}
