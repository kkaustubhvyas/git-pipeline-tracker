import XCTest
@testable import PipelineTracker

final class GitHubServiceTests: XCTestCase {

    private var service: GitHubService!

    override func setUp() {
        super.setUp()
        MockURLProtocol.requestHandler = nil
        service = GitHubService(token: "ghp_test", session: MockURLProtocol.makeSession())
    }

    // MARK: - API URL resolution

    func test_githubCom_usesApiGithubCom() {
        let svc = GitHubService(token: "t", baseURL: "https://github.com")
        XCTAssertEqual(svc.apiURL, "https://api.github.com")
    }

    func test_githubComHttp_usesApiGithubCom() {
        let svc = GitHubService(token: "t", baseURL: "http://github.com")
        XCTAssertEqual(svc.apiURL, "https://api.github.com")
    }

    func test_githubComTrailingSlash_usesApiGithubCom() {
        let svc = GitHubService(token: "t", baseURL: "https://github.com/")
        XCTAssertEqual(svc.apiURL, "https://api.github.com")
    }

    func test_ghe_usesV3ApiPath() {
        let svc = GitHubService(token: "t", baseURL: "https://ghe.company.com")
        XCTAssertEqual(svc.apiURL, "https://ghe.company.com/api/v3")
    }

    // MARK: - fetchAllProjects

    func test_fetchAllProjects_mapsToGitLabProject() async throws {
        MockURLProtocol.stub(json: """
        [{"id":1,"name":"my-repo","full_name":"octocat/my-repo"},
         {"id":2,"name":"other","full_name":"octocat/other"}]
        """)
        let projects = try await service.fetchAllProjects()
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].name, "my-repo")
        XCTAssertEqual(projects[0].pathWithNamespace, "octocat/my-repo")
        XCTAssertEqual(projects[0].nameWithNamespace, "octocat/my-repo")
        XCTAssertEqual(projects[0].id, 1)
    }

    func test_fetchAllProjects_pagination_stopsOnShortPage() async throws {
        var page = 0
        MockURLProtocol.requestHandler = { _ in
            page += 1
            let count = page == 1 ? 100 : 3
            let items = (1...count).map { i in "{\"id\":\(i),\"name\":\"r\(i)\",\"full_name\":\"o/r\(i)\"}" }.joined(separator: ",")
            let resp = HTTPURLResponse(url: URL(string: "https://api.github.com")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("[\(items)]".utf8))
        }
        let projects = try await service.fetchAllProjects()
        XCTAssertEqual(projects.count, 103)
        XCTAssertEqual(page, 2)
    }

    // MARK: - fetchPipelines (workflow runs)

    func test_fetchPipelines_mapsWorkflowRun() async throws {
        MockURLProtocol.stub(json: """
        {"workflow_runs":[
          {"id":999,"name":"CI","status":"in_progress","conclusion":null,
           "head_branch":"main","head_sha":"abc123","html_url":"https://github.com/o/r/actions/runs/999",
           "created_at":"2024-06-01T10:00:00Z","updated_at":"2024-06-01T10:01:00Z"}
        ]}
        """)
        let project = GitLabProject(id: 1, name: "my-repo", nameWithNamespace: "o/my-repo", pathWithNamespace: "o/my-repo")
        let pipelines = try await service.fetchPipelines(for: project)
        XCTAssertEqual(pipelines.count, 1)
        XCTAssertEqual(pipelines[0].id, 999)
        XCTAssertEqual(pipelines[0].status, .running)
        XCTAssertEqual(pipelines[0].ref, "main")
        XCTAssertEqual(pipelines[0].projectName, "CI")
    }

    // MARK: - Status mapping

    func test_statusMapping_queued() async throws {
        let pipeline = try await fetchSingleRun(status: "queued", conclusion: nil)
        XCTAssertEqual(pipeline.status, .pending)
    }

    func test_statusMapping_inProgress() async throws {
        let pipeline = try await fetchSingleRun(status: "in_progress", conclusion: nil)
        XCTAssertEqual(pipeline.status, .running)
    }

    func test_statusMapping_waiting() async throws {
        let pipeline = try await fetchSingleRun(status: "waiting", conclusion: nil)
        XCTAssertEqual(pipeline.status, .waitingForResource)
    }

    func test_statusMapping_completedSuccess() async throws {
        let pipeline = try await fetchSingleRun(status: "completed", conclusion: "success")
        XCTAssertEqual(pipeline.status, .success)
    }

    func test_statusMapping_completedNeutral() async throws {
        let pipeline = try await fetchSingleRun(status: "completed", conclusion: "neutral")
        XCTAssertEqual(pipeline.status, .success)
    }

    func test_statusMapping_completedFailure() async throws {
        let pipeline = try await fetchSingleRun(status: "completed", conclusion: "failure")
        XCTAssertEqual(pipeline.status, .failed)
    }

    func test_statusMapping_completedTimedOut() async throws {
        let pipeline = try await fetchSingleRun(status: "completed", conclusion: "timed_out")
        XCTAssertEqual(pipeline.status, .failed)
    }

    func test_statusMapping_completedCancelled() async throws {
        let pipeline = try await fetchSingleRun(status: "completed", conclusion: "cancelled")
        XCTAssertEqual(pipeline.status, .canceled)
    }

    func test_statusMapping_completedSkipped() async throws {
        let pipeline = try await fetchSingleRun(status: "completed", conclusion: "skipped")
        XCTAssertEqual(pipeline.status, .skipped)
    }

    func test_statusMapping_completedActionRequired() async throws {
        let pipeline = try await fetchSingleRun(status: "completed", conclusion: "action_required")
        XCTAssertEqual(pipeline.status, .manual)
    }

    func test_statusMapping_completedUnknownConclusion_defaultsSuccess() async throws {
        let pipeline = try await fetchSingleRun(status: "completed", conclusion: "unknown_new")
        XCTAssertEqual(pipeline.status, .success)
    }

    func test_statusMapping_unknownStatus_defaultsCreated() async throws {
        let pipeline = try await fetchSingleRun(status: "brand_new_status", conclusion: nil)
        XCTAssertEqual(pipeline.status, .created)
    }

    func test_emptyHeadBranch_usesDefaultLabel() async throws {
        let pipeline = try await fetchSingleRun(status: "queued", conclusion: nil, headBranch: "")
        XCTAssertEqual(pipeline.ref, "(default)")
    }

    func test_nilWorkflowName_usesProjectName() async throws {
        MockURLProtocol.stub(json: """
        {"workflow_runs":[
          {"id":1,"name":null,"status":"queued","conclusion":null,
           "head_branch":"main","head_sha":"abc","html_url":"https://x.com",
           "created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:00Z"}
        ]}
        """)
        let project = GitLabProject(id: 1, name: "FallbackName", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        let pipelines = try await service.fetchPipelines(for: project)
        XCTAssertEqual(pipelines[0].projectName, "FallbackName")
    }

    // MARK: - fetchJobSummary

    func test_fetchJobSummary_inProgressJobCountsAsStarted() async throws {
        // 2 completed + 1 in_progress = all 3 started → shows 3/3
        MockURLProtocol.stub(json: """
        {"jobs":[
          {"status":"completed","conclusion":"success"},
          {"status":"completed","conclusion":"success"},
          {"status":"in_progress","conclusion":null}
        ]}
        """)
        let pipeline = Pipeline(id: 42, status: .running, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        let summary = try await service.fetchJobSummary(for: pipeline, project: project)
        XCTAssertEqual(summary.started, 3)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.label, "3/3")
        XCTAssertTrue(summary.isComplete)
    }

    func test_fetchJobSummary_queuedJobNotCountedAsStarted() async throws {
        // 1 completed + 1 in_progress + 1 queued = 2 started out of 3
        MockURLProtocol.stub(json: """
        {"jobs":[
          {"status":"completed","conclusion":"success"},
          {"status":"in_progress","conclusion":null},
          {"status":"queued","conclusion":null}
        ]}
        """)
        let pipeline = Pipeline(id: 42, status: .running, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        let summary = try await service.fetchJobSummary(for: pipeline, project: project)
        XCTAssertEqual(summary.started, 2)
        XCTAssertEqual(summary.total, 3)
        XCTAssertEqual(summary.label, "2/3")
        XCTAssertFalse(summary.isComplete)
    }

    func test_fetchJobSummary_excludesSkippedJobs() async throws {
        MockURLProtocol.stub(json: """
        {"jobs":[
          {"status":"completed","conclusion":"success"},
          {"status":"completed","conclusion":"success"},
          {"status":"completed","conclusion":"skipped"}
        ]}
        """)
        let pipeline = Pipeline(id: 1, status: .running, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        let summary = try await service.fetchJobSummary(for: pipeline, project: project)
        XCTAssertEqual(summary.started, 2)
        XCTAssertEqual(summary.total, 2)
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.label, "2/2")
    }

    func test_fetchJobSummary_allComplete() async throws {
        MockURLProtocol.stub(json: """
        {"jobs":[{"status":"completed","conclusion":"success"},{"status":"completed","conclusion":"success"}]}
        """)
        let pipeline = Pipeline(id: 1, status: .running, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        let summary = try await service.fetchJobSummary(for: pipeline, project: project)
        XCTAssertTrue(summary.isComplete)
        XCTAssertEqual(summary.label, "2/2")
    }

    func test_fetchJobSummary_emptyJobs_returnsEmptyLabel() async throws {
        MockURLProtocol.stub(json: """
        {"jobs":[]}
        """)
        let pipeline = Pipeline(id: 1, status: .running, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        let summary = try await service.fetchJobSummary(for: pipeline, project: project)
        XCTAssertEqual(summary.total, 0)
        XCTAssertEqual(summary.label, "")
    }

    // MARK: - Error handling

    func test_emptyToken_throwsInvalidToken() async {
        let svc = GitHubService(token: "", session: MockURLProtocol.makeSession())
        do {
            _ = try await svc.fetchAllProjects()
            XCTFail("Expected error")
        } catch GitLabError.invalidToken { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_401_throwsUnauthorized() async {
        MockURLProtocol.stub(statusCode: 401, json: "{}")
        do { _ = try await service.fetchAllProjects(); XCTFail("Expected error") }
        catch GitLabError.unauthorized { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_403_throwsUnauthorized() async {
        MockURLProtocol.stub(statusCode: 403, json: "{}")
        do { _ = try await service.fetchAllProjects(); XCTFail("Expected error") }
        catch GitLabError.unauthorized { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_429_throwsRateLimited() async {
        MockURLProtocol.stub(statusCode: 429, json: "{}")
        do { _ = try await service.fetchAllProjects(); XCTFail("Expected error") }
        catch GitLabError.rateLimited { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_networkFailure_throwsNetworkError() async {
        MockURLProtocol.requestHandler = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await service.fetchAllProjects(); XCTFail("Expected error") }
        catch GitLabError.networkError { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_malformedJSON_throwsDecodingError() async {
        MockURLProtocol.stub(json: "NOT JSON")
        do { _ = try await service.fetchAllProjects(); XCTFail("Expected error") }
        catch GitLabError.decodingError { } catch { XCTFail("Unexpected: \(error)") }
    }

    // MARK: - Helpers

    private func fetchSingleRun(status: String, conclusion: String?, headBranch: String = "main") async throws -> Pipeline {
        let conclusionJSON = conclusion.map { "\"\($0)\"" } ?? "null"
        MockURLProtocol.stub(json: """
        {"workflow_runs":[
          {"id":1,"name":"CI","status":"\(status)","conclusion":\(conclusionJSON),
           "head_branch":"\(headBranch)","head_sha":"sha","html_url":"https://x.com",
           "created_at":"2024-01-01T00:00:00Z","updated_at":"2024-01-01T00:00:01Z"}
        ]}
        """)
        let project = GitLabProject(id: 1, name: "repo", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        let pipelines = try await service.fetchPipelines(for: project)
        return try XCTUnwrap(pipelines.first)
    }
}
