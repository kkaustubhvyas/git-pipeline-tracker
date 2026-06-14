import XCTest
@testable import PipelineTracker

final class GitLabServiceTests: XCTestCase {

    private var service: GitLabService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        service = GitLabService(token: "test-token", session: MockURLProtocol.makeSession())
    }

    // MARK: - fetchAllProjects

    func test_fetchAllProjects_singlePage() async throws {
        MockURLProtocol.stub(json: """
        [{"id":1,"name":"Alpha","name_with_namespace":"Group / Alpha","path_with_namespace":"group/alpha"},
         {"id":2,"name":"Beta","name_with_namespace":"Group / Beta","path_with_namespace":"group/beta"}]
        """)
        let projects = try await service.fetchAllProjects()
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].id, 1)
        XCTAssertEqual(projects[0].name, "Alpha")
        XCTAssertEqual(projects[1].pathWithNamespace, "group/beta")
    }

    func test_fetchAllProjects_paginatesUntilShortPage() async throws {
        var page = 0
        MockURLProtocol.requestHandler = { _ in
            page += 1
            let body: String
            if page == 1 {
                let items = (1...99).map { i in
                    "{\"id\":\(i),\"name\":\"P\",\"name_with_namespace\":\"G/P\",\"path_with_namespace\":\"g/p\"}"
                }.joined(separator: ",")
                body = "[\(items)]"
            } else {
                body = "[]"
            }
            let resp = HTTPURLResponse(url: URL(string: "https://gitlab.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data(body.utf8))
        }
        let projects = try await service.fetchAllProjects()
        XCTAssertEqual(projects.count, 99)
    }

    // MARK: - fetchPipelines

    func test_fetchPipelines_success() async throws {
        MockURLProtocol.stub(json: """
        [{"id":101,"status":"running","ref":"main","sha":"abc123","web_url":"https://gitlab.com/p/1",
          "created_at":"2024-06-01T10:00:00Z","updated_at":"2024-06-01T10:05:00Z"}]
        """)
        let project = GitLabProject(id: 42, name: "Alpha", nameWithNamespace: "G/Alpha", pathWithNamespace: "g/alpha")
        let pipelines = try await service.fetchPipelines(for: project)
        XCTAssertEqual(pipelines.count, 1)
        XCTAssertEqual(pipelines[0].id, 101)
        XCTAssertEqual(pipelines[0].status, .running)
        XCTAssertEqual(pipelines[0].ref, "main")
    }

    // MARK: - Error handling

    func test_emptyToken_throwsInvalidToken() async {
        let svc = GitLabService(token: "", session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.fetchAllProjects()
            XCTFail("Expected error")
        } catch GitLabError.invalidToken {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test_401_throwsUnauthorized() async {
        MockURLProtocol.stub(statusCode: 401, json: "{}")
        do {
            _ = try await service.fetchAllProjects()
            XCTFail("Expected error")
        } catch GitLabError.unauthorized {
            // expected
        } catch {
            XCTFail("Unexpected: \(error)")
        }
    }

    func test_403_throwsUnauthorized() async {
        MockURLProtocol.stub(statusCode: 403, json: "{}")
        do {
            _ = try await service.fetchAllProjects()
            XCTFail("Expected error")
        } catch GitLabError.unauthorized { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_429_throwsRateLimited() async {
        MockURLProtocol.stub(statusCode: 429, json: "{}")
        do {
            _ = try await service.fetchAllProjects()
            XCTFail("Expected error")
        } catch GitLabError.rateLimited { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_500_throwsNetworkError() async {
        MockURLProtocol.stub(statusCode: 500, json: "{}")
        do {
            _ = try await service.fetchAllProjects()
            XCTFail("Expected error")
        } catch GitLabError.networkError { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_networkFailure_throwsNetworkError() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await service.fetchAllProjects()
            XCTFail("Expected error")
        } catch GitLabError.networkError { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_malformedJSON_throwsDecodingError() async {
        MockURLProtocol.stub(json: "NOT JSON")
        do {
            _ = try await service.fetchAllProjects()
            XCTFail("Expected error")
        } catch GitLabError.decodingError { } catch { XCTFail("Unexpected: \(error)") }
    }

    // MARK: - Date decoding

    func test_pipelineDate_withFractionalSeconds() async throws {
        MockURLProtocol.stub(json: """
        [{"id":1,"status":"success","ref":"main","sha":"abc","web_url":"https://x.com",
          "created_at":"2024-06-01T10:00:00.123Z","updated_at":"2024-06-01T10:01:00.456Z"}]
        """)
        let project = GitLabProject(id: 1, name: "P", nameWithNamespace: "G/P", pathWithNamespace: "g/p")
        let pipelines = try await service.fetchPipelines(for: project)
        XCTAssertEqual(pipelines.count, 1)
        XCTAssertNotNil(pipelines[0].createdAt)
    }

    func test_pipelineDate_withoutFractionalSeconds() async throws {
        MockURLProtocol.stub(json: """
        [{"id":2,"status":"failed","ref":"dev","sha":"def","web_url":"https://x.com",
          "created_at":"2024-06-01T10:00:00Z","updated_at":"2024-06-01T10:02:00Z"}]
        """)
        let project = GitLabProject(id: 1, name: "P", nameWithNamespace: "G/P", pathWithNamespace: "g/p")
        let pipelines = try await service.fetchPipelines(for: project)
        XCTAssertEqual(pipelines[0].status, .failed)
    }

    // MARK: - fetchJobSummary

    func test_fetchJobSummary_countsStartedJobs() async throws {
        // 1 done + 1 running + 1 pending = 2 started out of 3
        MockURLProtocol.stub(json: """
        [{"id":1,"name":"build","status":"success","stage":"build","web_url":"https://x.com","allow_failure":false},
         {"id":2,"name":"test","status":"running","stage":"test","web_url":"https://x.com","allow_failure":false},
         {"id":3,"name":"deploy","status":"pending","stage":"deploy","web_url":"https://x.com","allow_failure":false}]
        """)
        let pipeline = Pipeline(id: 10, status: .running, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "P", nameWithNamespace: "G/P", pathWithNamespace: "g/p")
        let summary = try await service.fetchJobSummary(for: pipeline, project: project)
        XCTAssertEqual(summary.started, 2)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.label, "2/3")
    }

    func test_fetchJobSummary_runningJobCountsAsStarted() async throws {
        // 2 done + 1 running = all 3 started → shows 3/3
        MockURLProtocol.stub(json: """
        [{"id":1,"name":"build","status":"success","stage":"build","web_url":"https://x.com","allow_failure":false},
         {"id":2,"name":"test","status":"success","stage":"test","web_url":"https://x.com","allow_failure":false},
         {"id":3,"name":"deploy","status":"running","stage":"deploy","web_url":"https://x.com","allow_failure":false}]
        """)
        let pipeline = Pipeline(id: 10, status: .running, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "P", nameWithNamespace: "G/P", pathWithNamespace: "g/p")
        let summary = try await service.fetchJobSummary(for: pipeline, project: project)
        XCTAssertEqual(summary.started, 3)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.label, "3/3")
    }

    func test_fetchJobSummary_excludesAllowFailureJobs() async throws {
        MockURLProtocol.stub(json: """
        [{"id":1,"name":"build","status":"success","stage":"build","web_url":"https://x.com","allow_failure":false},
         {"id":2,"name":"lint","status":"failed","stage":"test","web_url":"https://x.com","allow_failure":true},
         {"id":3,"name":"deploy","status":"pending","stage":"deploy","web_url":"https://x.com","allow_failure":false}]
        """)
        let pipeline = Pipeline(id: 10, status: .running, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "P", nameWithNamespace: "G/P", pathWithNamespace: "g/p")
        let summary = try await service.fetchJobSummary(for: pipeline, project: project)
        XCTAssertEqual(summary.started, 1)
        XCTAssertEqual(summary.total, 2)
        XCTAssertEqual(summary.label, "1/2")
    }

    // MARK: - GitLabError descriptions

    func test_errorDescriptions_nonNil() {
        let errors: [GitLabError] = [
            .invalidToken, .unauthorized, .rateLimited,
            .networkError(URLError(.notConnectedToInternet)),
            .decodingError(NSError(domain: "test", code: 0))
        ]
        for e in errors {
            XCTAssertNotNil(e.errorDescription, "\(e) should have a description")
        }
    }
}
