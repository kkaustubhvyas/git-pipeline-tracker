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
        XCTAssertEqual(pipelines[0].workflowName, "CI")
        XCTAssertEqual(pipelines[0].projectName, "my-repo")
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
          {"id":1,"name":"a","status":"completed","conclusion":"success"},
          {"id":2,"name":"b","status":"completed","conclusion":"success"},
          {"id":3,"name":"c","status":"in_progress","conclusion":null}
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
          {"id":1,"name":"a","status":"completed","conclusion":"success"},
          {"id":2,"name":"b","status":"in_progress","conclusion":null},
          {"id":3,"name":"c","status":"queued","conclusion":null}
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
          {"id":1,"name":"a","status":"completed","conclusion":"success"},
          {"id":2,"name":"b","status":"completed","conclusion":"success"},
          {"id":3,"name":"c","status":"completed","conclusion":"skipped"}
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
        {"jobs":[{"id":1,"name":"a","status":"completed","conclusion":"success"},{"id":2,"name":"b","status":"completed","conclusion":"success"}]}
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

    // MARK: - fetchSteps

    func test_fetchSteps_mapsJobsWithStatusAndConclusion() async throws {
        MockURLProtocol.stub(json: """
        {"jobs":[
          {"id":1,"name":"build","status":"completed","conclusion":"success","html_url":"https://x.com/1"},
          {"id":2,"name":"deploy","status":"in_progress","conclusion":null,"html_url":"https://x.com/2"},
          {"id":3,"name":"optional-check","status":"completed","conclusion":"skipped","html_url":"https://x.com/3"}
        ]}
        """)
        let pipeline = Pipeline(id: 9, status: .running, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        let steps = try await service.fetchSteps(for: pipeline, project: project)
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0].status, .success)
        XCTAssertNil(steps[0].stage)               // GitHub has no stage grouping
        XCTAssertEqual(steps[1].status, .running)
        XCTAssertTrue(steps[2].isOptional)         // skipped → optional
        XCTAssertEqual(steps[2].status, .skipped)
    }

    // MARK: - re-run

    func test_rerunFailed_postsToRerunFailedJobs() async throws {
        var capturedURL: URL?
        var capturedMethod: String?
        MockURLProtocol.requestHandler = { req in
            capturedURL = req.url
            capturedMethod = req.httpMethod
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let pipeline = Pipeline(id: 55, status: .failed, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "octo/repo")
        try await service.rerunFailed(pipeline: pipeline, project: project)
        XCTAssertEqual(capturedMethod, "POST")
        XCTAssertTrue(capturedURL?.absoluteString.hasSuffix("/repos/octo/repo/actions/runs/55/rerun-failed-jobs") ?? false)
    }

    func test_rerunAll_postsToRerun() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { req in
            capturedURL = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let pipeline = Pipeline(id: 55, status: .success, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "octo/repo")
        try await service.rerunAll(pipeline: pipeline, project: project)
        XCTAssertTrue(capturedURL?.absoluteString.hasSuffix("/repos/octo/repo/actions/runs/55/rerun") ?? false)
    }

    func test_rerunStep_postsToJobRerun() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { req in
            capturedURL = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!
            return (resp, Data())
        }
        let pipeline = Pipeline(id: 55, status: .failed, ref: "main", sha: "abc",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "octo/repo")
        try await service.rerunStep(stepId: 88, pipeline: pipeline, project: project)
        XCTAssertTrue(capturedURL?.absoluteString.hasSuffix("/repos/octo/repo/actions/jobs/88/rerun") ?? false)
    }

    func test_rerun_unauthorized_throws() async {
        MockURLProtocol.stub(statusCode: 403, json: "{}")
        let pipeline = Pipeline(id: 1, status: .failed, ref: "m", sha: "s",
                                webUrl: "https://x.com", createdAt: Date(), updatedAt: Date())
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        do { try await service.rerunFailed(pipeline: pipeline, project: project); XCTFail("Expected error") }
        catch GitLabError.unauthorized { } catch { XCTFail("Unexpected: \(error)") }
    }

    func test_paginatedFetch_includesPageParam() async throws {
        var capturedURL: URL?
        MockURLProtocol.requestHandler = { req in
            capturedURL = req.url
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, Data("{\"workflow_runs\":[]}".utf8))
        }
        let project = GitLabProject(id: 1, name: "r", nameWithNamespace: "o/r", pathWithNamespace: "o/r")
        _ = try await service.fetchPipelines(for: project, page: 3, perPage: 25)
        let s = capturedURL?.absoluteString ?? ""
        XCTAssertTrue(s.contains("page=3"))
        XCTAssertTrue(s.contains("per_page=25"))
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
