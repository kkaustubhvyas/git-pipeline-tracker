import Foundation

final class GitHubService: PipelineProvider {
    let apiURL: String
    private let token: String
    private let decoder: JSONDecoder
    private let session: URLSession

    init(token: String, baseURL: String = "https://github.com", session: URLSession? = nil) {
        self.token = token
        let base = baseURL.trimmingCharacters(in: .init(charactersIn: "/"))
        // github.com → api.github.com; GHE → base/api/v3
        if base == "https://github.com" || base == "http://github.com" {
            self.apiURL = "https://api.github.com"
        } else {
            self.apiURL = "\(base)/api/v3"
        }

        let dec = JSONDecoder()
        let isoFull = ISO8601DateFormatter()
        isoFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoShort = ISO8601DateFormatter()
        dec.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let d = isoFull.date(from: s) { return d }
            if let d = isoShort.date(from: s) { return d }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Cannot parse date: \(s)")
        }
        self.decoder = dec

        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 15
            self.session = URLSession(configuration: cfg)
        }
    }

    // MARK: - PipelineProvider

    func fetchAllProjects() async throws -> [GitLabProject] {
        var all: [GitLabRepo] = []
        var page = 1
        while true {
            let url = "\(apiURL)/user/repos?per_page=100&page=\(page)&sort=updated&affiliation=owner,collaborator,organization_member"
            let batch: [GitLabRepo] = try await fetch(from: url)
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        return all.map(\.asProject)
    }

    func fetchPipelines(for project: GitLabProject, page: Int = 1, perPage: Int = 20) async throws -> [Pipeline] {
        let url = "\(apiURL)/repos/\(project.pathWithNamespace)/actions/runs?per_page=\(perPage)&page=\(page)"
        let response: GitHubRunsResponse = try await fetch(from: url)
        return response.workflowRuns.map { $0.asPipeline(projectId: project.id, projectName: project.name) }
    }

    func fetchSteps(for pipeline: Pipeline, project: GitLabProject) async throws -> [PipelineStep] {
        let url = "\(apiURL)/repos/\(project.pathWithNamespace)/actions/runs/\(pipeline.id)/jobs?per_page=100"
        let response: GitHubJobsResponse = try await fetch(from: url)
        return response.jobs.map { $0.asStep }
    }

    func rerunFailed(pipeline: Pipeline, project: GitLabProject) async throws {
        // Re-run only failed jobs in the workflow run. Requires `repo` scope (actions: write).
        try await post(to: "\(apiURL)/repos/\(project.pathWithNamespace)/actions/runs/\(pipeline.id)/rerun-failed-jobs")
    }

    func rerunAll(pipeline: Pipeline, project: GitLabProject) async throws {
        // Re-run the entire workflow (all jobs, including passed ones).
        try await post(to: "\(apiURL)/repos/\(project.pathWithNamespace)/actions/runs/\(pipeline.id)/rerun")
    }

    func rerunStep(stepId: Int, pipeline: Pipeline, project: GitLabProject) async throws {
        // GitHub only permits re-running a single *failed* job; succeeded jobs return an error.
        try await post(to: "\(apiURL)/repos/\(project.pathWithNamespace)/actions/jobs/\(stepId)/rerun")
    }

    // MARK: - Private

    private func fetch<T: Decodable>(from urlString: String) async throws -> T {
        guard !token.isEmpty else { throw GitLabError.invalidToken }
        guard let url = URL(string: urlString) else { throw GitLabError.invalidToken }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: req) }
        catch { throw GitLabError.networkError(error) }

        guard let http = response as? HTTPURLResponse else {
            throw GitLabError.networkError(URLError(.badServerResponse))
        }

        switch http.statusCode {
        case 200...299:
            do { return try decoder.decode(T.self, from: data) }
            catch { throw GitLabError.decodingError(error) }
        case 401, 403:
            throw GitLabError.unauthorized
        case 429:
            throw GitLabError.rateLimited
        default:
            throw GitLabError.networkError(URLError(.badServerResponse))
        }
    }

    private func post(to urlString: String) async throws {
        guard !token.isEmpty else { throw GitLabError.invalidToken }
        guard let url = URL(string: urlString) else { throw GitLabError.invalidToken }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")

        let (_, response): (Data, URLResponse)
        do { (_, response) = try await session.data(for: req) }
        catch { throw GitLabError.networkError(error) }

        guard let http = response as? HTTPURLResponse else {
            throw GitLabError.networkError(URLError(.badServerResponse))
        }
        switch http.statusCode {
        case 200...299: return
        case 401, 403:  throw GitLabError.unauthorized
        case 429:       throw GitLabError.rateLimited
        default:        throw GitLabError.networkError(URLError(.badServerResponse))
        }
    }
}

// MARK: - GitHub API types (private)

private struct GitLabRepo: Decodable {
    let id: Int
    let name: String
    let fullName: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case fullName = "full_name"
    }

    var asProject: GitLabProject {
        GitLabProject(id: id, name: name, nameWithNamespace: fullName, pathWithNamespace: fullName)
    }
}

private struct GitHubJobsResponse: Decodable {
    let jobs: [GitHubJob]
}

private struct GitHubJob: Decodable {
    let id: Int
    let name: String
    let status: String
    let conclusion: String?
    let htmlUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case htmlUrl = "html_url"
    }

    /// Map GitHub job status+conclusion → unified PipelineStatus (same logic as workflow runs).
    var pipelineStatus: PipelineStatus {
        switch status {
        case "queued":      return .pending
        case "in_progress": return .running
        case "waiting":     return .waitingForResource
        case "completed":
            switch conclusion {
            case "success", "neutral": return .success
            case "failure", "timed_out": return .failed
            case "cancelled":   return .canceled
            case "skipped":     return .skipped
            case "action_required": return .manual
            default:            return .success
            }
        default: return .created
        }
    }

    var asStep: PipelineStep {
        PipelineStep(id: id, name: name, status: pipelineStatus,
                     stage: nil, webURL: htmlUrl, isOptional: conclusion == "skipped")
    }
}

private struct GitHubRunsResponse: Decodable {
    let workflowRuns: [GitHubWorkflowRun]

    enum CodingKeys: String, CodingKey {
        case workflowRuns = "workflow_runs"
    }
}

private struct GitHubWorkflowRun: Decodable {
    let id: Int
    let name: String?
    let status: String
    let conclusion: String?
    let headBranch: String
    let headSha: String
    let htmlUrl: String
    let createdAt: Date
    let updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, status, conclusion
        case headBranch = "head_branch"
        case headSha = "head_sha"
        case htmlUrl = "html_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    var pipelineStatus: PipelineStatus {
        switch status {
        case "queued":       return .pending
        case "in_progress":  return .running
        case "waiting":      return .waitingForResource
        case "completed":
            switch conclusion {
            case "success", "neutral": return .success
            case "failure", "timed_out": return .failed
            case "cancelled":  return .canceled
            case "skipped":    return .skipped
            case "action_required": return .manual
            default:           return .success
            }
        default: return .created
        }
    }

    func asPipeline(projectId: Int, projectName: String) -> Pipeline {
        var p = Pipeline(
            id: id, status: pipelineStatus,
            ref: headBranch.isEmpty ? "(default)" : headBranch,
            sha: headSha, webUrl: htmlUrl,
            createdAt: createdAt, updatedAt: updatedAt
        )
        p.projectId = projectId
        p.projectName = projectName
        p.workflowName = name ?? ""
        return p
    }
}
