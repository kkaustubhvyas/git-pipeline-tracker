import Foundation
import SwiftUI

// MARK: - Provider

enum Provider: String, Codable, CaseIterable {
    case gitlab
    case github

    var displayName: String {
        switch self {
        case .gitlab: return "GitLab"
        case .github: return "GitHub"
        }
    }

    var systemImage: String {
        switch self {
        case .gitlab: return "chevron.left.forwardslash.chevron.right"
        case .github: return "cat"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .gitlab: return "https://gitlab.com"
        case .github: return "https://github.com"
        }
    }

    var tokenPlaceholder: String {
        switch self {
        case .gitlab: return "glpat-xxxxxxxxxxxxxxxxxxxx"
        case .github: return "ghp_xxxxxxxxxxxxxxxxxxxx"
        }
    }

    var logoImageName: String {
        switch self {
        case .gitlab: return "gitlab-logo"
        case .github: return "github-logo"
        }
    }

    var tokenScopeHint: String {
        switch self {
        case .gitlab: return "Required scope: **read_api**"
        case .github: return "Required scope: **repo** (or **public_repo** for public only)"
        }
    }
}

// MARK: - Project filter

struct ProjectFilter: Codable, Equatable, Hashable {
    /// Branch/ref glob patterns. Empty = show all. Supports `*` wildcard.
    var refPatterns: [String] = []

    var isEmpty: Bool { refPatterns.isEmpty }

    func matches(ref: String) -> Bool {
        guard !refPatterns.isEmpty else { return true }
        return refPatterns.contains { globMatch(pattern: $0, string: ref) }
    }

    private func globMatch(pattern: String, string: String) -> Bool {
        if pattern == "*" { return true }
        guard pattern.contains("*") else { return pattern == string }
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        var rest = string[...]
        for (i, part) in parts.enumerated() {
            guard !part.isEmpty else { continue }
            if i == 0 {
                guard rest.hasPrefix(part) else { return false }
                rest = rest.dropFirst(part.count)
            } else if i == parts.count - 1 {
                return rest.hasSuffix(part)
            } else {
                guard let r = rest.range(of: part) else { return false }
                rest = rest[r.upperBound...]
            }
        }
        return true
    }
}

// MARK: - Account

struct Account: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var name: String
    var provider: Provider
    /// Base URL of the instance (e.g. https://gitlab.com, https://github.com).
    var baseURL: String
    var watchedProjectIds: Set<Int>
    /// Keyed by "\(projectId)". Missing key = no filter (show all).
    var projectFilters: [String: ProjectFilter]

    init(id: UUID = UUID(), name: String, provider: Provider = .gitlab,
         baseURL: String? = nil, watchedProjectIds: Set<Int> = [],
         projectFilters: [String: ProjectFilter] = [:]) {
        self.id = id
        self.name = name
        self.provider = provider
        self.baseURL = baseURL ?? provider.defaultBaseURL
        self.watchedProjectIds = watchedProjectIds
        self.projectFilters = projectFilters
    }

    // Resilient decode: new fields absent in older stored data → sensible defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        provider = try c.decodeIfPresent(Provider.self, forKey: .provider) ?? .gitlab
        // Support old key name "gitlabURL"
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL)
            ?? c.decodeIfPresent(String.self, forKey: .gitlabURL)
            ?? provider.defaultBaseURL
        watchedProjectIds = try c.decode(Set<Int>.self, forKey: .watchedProjectIds)
        projectFilters = try c.decodeIfPresent([String: ProjectFilter].self, forKey: .projectFilters) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(provider, forKey: .provider)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(watchedProjectIds, forKey: .watchedProjectIds)
        try c.encode(projectFilters, forKey: .projectFilters)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, provider, baseURL, gitlabURL, watchedProjectIds, projectFilters
    }

    func filter(for projectId: Int) -> ProjectFilter {
        projectFilters["\(projectId)"] ?? ProjectFilter()
    }
}

// MARK: - Pipeline Status

enum PipelineStatus: String, Codable, Equatable {
    case created
    case waitingForResource = "waiting_for_resource"
    case preparing
    case pending
    case running
    case success
    case failed
    case canceled
    case skipped
    case manual
    case scheduled

    var displayName: String {
        switch self {
        case .created: return "Created"
        case .waitingForResource: return "Waiting"
        case .preparing: return "Preparing"
        case .pending: return "Pending"
        case .running: return "Running"
        case .success: return "Success"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        case .skipped: return "Skipped"
        case .manual: return "Manual"
        case .scheduled: return "Scheduled"
        }
    }

    var systemImage: String {
        switch self {
        case .created, .waitingForResource, .preparing, .scheduled: return "clock"
        case .pending: return "hourglass"
        case .running: return "arrow.triangle.2.circlepath"
        case .success: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .canceled: return "slash.circle.fill"
        case .skipped: return "forward.fill"
        case .manual: return "hand.tap.fill"
        }
    }

    var color: Color {
        switch self {
        case .created, .waitingForResource, .preparing, .scheduled: return .gray
        case .pending: return .orange
        case .running: return .blue
        case .success: return .green
        case .failed: return .red
        case .canceled: return .orange
        case .skipped: return Color(nsColor: .secondaryLabelColor)
        case .manual: return .purple
        }
    }

    var isActive: Bool {
        switch self {
        case .created, .waitingForResource, .preparing, .pending, .running: return true
        default: return false
        }
    }
}

// MARK: - GitLabProject

struct GitLabProject: Identifiable, Codable, Hashable {
    let id: Int
    let name: String
    let nameWithNamespace: String
    let pathWithNamespace: String

    enum CodingKeys: String, CodingKey {
        case id, name
        case nameWithNamespace = "name_with_namespace"
        case pathWithNamespace = "path_with_namespace"
    }
}

// MARK: - Pipeline

struct Pipeline: Identifiable, Codable, Equatable {
    let id: Int
    let status: PipelineStatus
    let ref: String
    let sha: String
    let webUrl: String
    let createdAt: Date
    let updatedAt: Date

    /// Set after fetch — not from API response.
    var projectId: Int = 0
    var projectName: String = ""
    var accountId: UUID = UUID()

    enum CodingKeys: String, CodingKey {
        case id, status, ref, sha
        case webUrl = "web_url"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    static func == (lhs: Pipeline, rhs: Pipeline) -> Bool {
        lhs.id == rhs.id && lhs.status == rhs.status
    }
}

// MARK: - Job summary

struct PipelineJobSummary {
    let started: Int
    let total: Int

    var isComplete: Bool { total > 0 && started == total }
    var label: String { total > 0 ? "\(started)/\(total)" : "" }
}

// MARK: - Sort order

enum PipelineSortOrder: String, CaseIterable {
    case timeStarted  = "time_started"
    case timeFinished = "time_finished"

    var displayName: String {
        switch self {
        case .timeStarted:  return "Time Started"
        case .timeFinished: return "Time Finished"
        }
    }

    var systemImage: String {
        switch self {
        case .timeStarted:  return "play.circle"
        case .timeFinished: return "checkmark.circle"
        }
    }
}

// MARK: - PipelineJob

struct PipelineJob: Identifiable, Codable {
    let id: Int
    let name: String
    let status: PipelineStatus
    let stage: String
    let webUrl: String
    let allowFailure: Bool

    enum CodingKeys: String, CodingKey {
        case id, name, status, stage
        case webUrl = "web_url"
        case allowFailure = "allow_failure"
    }
}
