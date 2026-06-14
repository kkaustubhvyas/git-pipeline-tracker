import Foundation

// MARK: - Shared protocol

protocol PipelineProvider {
    func fetchAllProjects() async throws -> [GitLabProject]
    func fetchPipelines(for project: GitLabProject) async throws -> [Pipeline]
    func fetchJobSummary(for pipeline: Pipeline, project: GitLabProject) async throws -> PipelineJobSummary
}

// MARK: -

enum GitLabError: LocalizedError {
    case invalidToken
    case unauthorized
    case rateLimited
    case networkError(Error)
    case decodingError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidToken: return "Invalid or missing token"
        case .unauthorized: return "Unauthorized — token expired or missing read_api scope"
        case .rateLimited: return "Rate limited by GitLab API"
        case .networkError(let e): return "Network error: \(e.localizedDescription)"
        case .decodingError(let e): return "Decode error: \(e.localizedDescription)"
        }
    }
}

final class GitLabService: PipelineProvider {
    private let baseURL: String
    private(set) var token: String
    private let decoder: JSONDecoder
    private let session: URLSession

    init(token: String, baseURL: String = "https://gitlab.com", session: URLSession? = nil) {
        self.token = token
        self.baseURL = "\(baseURL.trimmingCharacters(in: .init(charactersIn: "/")))/api/v4"

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

    func fetchAllProjects() async throws -> [GitLabProject] {
        var all: [GitLabProject] = []
        var page = 1
        while true {
            let batch: [GitLabProject] = try await fetch(
                from: "\(baseURL)/projects?membership=true&per_page=100&page=\(page)&order_by=last_activity_at&sort=desc"
            )
            all.append(contentsOf: batch)
            if batch.count < 100 { break }
            page += 1
        }
        return all
    }

    func fetchPipelines(for projectId: Int, perPage: Int = 20) async throws -> [Pipeline] {
        return try await fetch(
            from: "\(baseURL)/projects/\(projectId)/pipelines?per_page=\(perPage)&order_by=updated_at&sort=desc"
        )
    }

    func fetchPipelines(for project: GitLabProject) async throws -> [Pipeline] {
        try await fetchPipelines(for: project.id)
    }

    func fetchJobs(pipelineId: Int, projectId: Int) async throws -> [PipelineJob] {
        return try await fetch(from: "\(baseURL)/projects/\(projectId)/pipelines/\(pipelineId)/jobs?per_page=100")
    }

    func fetchJobSummary(for pipeline: Pipeline, project: GitLabProject) async throws -> PipelineJobSummary {
        let jobs = try await fetchJobs(pipelineId: pipeline.id, projectId: project.id)
        let required = jobs.filter { !$0.allowFailure }
        let notStarted: Set<PipelineStatus> = [.created, .waitingForResource, .preparing, .pending]
        let started = required.filter { !notStarted.contains($0.status) }.count
        return PipelineJobSummary(started: started, total: required.count)
    }

    // MARK: - Private

    private func fetch<T: Decodable>(from urlString: String) async throws -> T {
        guard !token.isEmpty else { throw GitLabError.invalidToken }
        guard let url = URL(string: urlString) else { throw GitLabError.invalidToken }

        var req = URLRequest(url: url)
        req.setValue(token, forHTTPHeaderField: "PRIVATE-TOKEN")

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw GitLabError.networkError(error)
        }

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
}
