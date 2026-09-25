import Foundation
import Combine
import SwiftUI

@MainActor
final class PipelineMonitor: ObservableObject {
    @Published var accounts: [Account] = []
    @Published var projects: [UUID: [GitLabProject]] = [:]
    @Published var pipelines: [UUID: [Pipeline]] = [:]
    @Published var accountErrors: [UUID: String] = [:]
    @Published var loadingProjectsFor: Set<UUID> = []
    @Published var isRefreshing = false
    @Published var lastRefresh: Date?
    @Published var jobSummaries: [Int: PipelineJobSummary] = [:]

    // Expandable steps
    @Published var expandedPipelines: Set<Int> = []
    @Published var steps: [Int: [PipelineStep]] = [:]
    @Published var loadingSteps: Set<Int> = []

    // Retry / re-run
    @Published var retrying: Set<Int> = []        // pipeline ids being re-run
    @Published var rerunningSteps: Set<Int> = []  // step (job) ids being re-run

    // Server-side pagination — pages currently loaded per account, and whether more exist.
    @Published var pageCounts: [UUID: Int] = [:]
    @Published var hasMore: [UUID: Bool] = [:]
    @Published var loadingMore: Set<UUID> = []

    @Published var sortOrder: PipelineSortOrder = .timeStarted {
        didSet { UserDefaults.standard.set(sortOrder.rawValue, forKey: "sort_order") }
    }
    @Published var pageSize: Int = 20 {
        didSet {
            let clamped = max(5, min(100, pageSize))
            guard clamped == pageSize else { pageSize = clamped; return }
            UserDefaults.standard.set(pageSize, forKey: "page_size")
        }
    }
    @Published var pollingInterval: Double = 10 {
        didSet {
            let clamped = max(1, min(3600, pollingInterval))
            guard clamped == pollingInterval else {
                pollingInterval = clamped   // triggers didSet once more with valid value
                return
            }
            UserDefaults.standard.set(pollingInterval, forKey: "polling_interval")
            restartTimer()
        }
    }

    // Auth failure backoff: after the initial failure + `maxAuthRetries` retries,
    // the account is paused and excluded from periodic refresh until the token
    // is updated or a manual refresh is triggered.
    @Published var pausedAccounts: Set<UUID> = []
    private var authFailureCounts: [UUID: Int] = [:]
    private let maxAuthRetries = 2

    private var services: [UUID: any PipelineProvider] = [:]
    private var knownStatuses: [Int: PipelineStatus] = [:]
    private var knownPipelineIds: Set<Int> = []
    /// When each (account, project) was first fetched successfully. Notifications are
    /// suppressed until a baseline exists, so a failed first poll (e.g. no network at
    /// login) doesn't make every pipeline look "new" on the next successful one.
    private var baselines: [String: Date] = [:]
    private var pollingTimer: Timer?

    init() {
        loadPersistedAccounts()
        loadPersistedProjects()
        rebuildServices()
        let saved = UserDefaults.standard.double(forKey: "polling_interval")
        pollingInterval = saved > 0 ? max(1, min(3600, saved)) : 10
        let savedSort = UserDefaults.standard.string(forKey: "sort_order") ?? ""
        sortOrder = PipelineSortOrder(rawValue: savedSort) ?? .timeStarted
        let savedPage = UserDefaults.standard.integer(forKey: "page_size")
        pageSize = savedPage > 0 ? max(5, min(100, savedPage)) : 20
        NotificationManager.shared.requestPermission()
        startPolling()
    }

    // MARK: - Account CRUD

    func addAccount(name: String, token: String, provider: Provider, baseURL: String) {
        let account = Account(name: name, provider: provider, baseURL: baseURL)
        accounts.append(account)
        do { try KeychainService.shared.saveToken(token, for: account.id) }
        catch { print("Keychain save error: \(error)") }
        services[account.id] = makeService(token: token, account: account)
        persistAccounts()
    }

    func updateAccount(_ updated: Account, newToken: String? = nil) {
        guard let idx = accounts.firstIndex(where: { $0.id == updated.id }) else { return }
        accounts[idx] = updated
        if let token = newToken {
            do { try KeychainService.shared.saveToken(token, for: updated.id) }
            catch { print("Keychain save error: \(error)") }
            services[updated.id] = makeService(token: token, account: updated)
            accountErrors.removeValue(forKey: updated.id)
            authFailureCounts.removeValue(forKey: updated.id)
            pausedAccounts.remove(updated.id)
        }
        persistAccounts()
    }

    func deleteAccount(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        KeychainService.shared.deleteToken(for: account.id)
        services.removeValue(forKey: account.id)
        projects.removeValue(forKey: account.id)
        pipelines.removeValue(forKey: account.id)
        accountErrors.removeValue(forKey: account.id)
        authFailureCounts.removeValue(forKey: account.id)
        pausedAccounts.remove(account.id)
        persistAccounts()
        persistProjects()
    }

    func tokenFor(_ account: Account) -> String {
        KeychainService.shared.loadToken(for: account.id) ?? ""
    }

    // MARK: - Persistence

    private func persistAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: "accounts_v2")
    }

    private func loadPersistedAccounts() {
        guard let data = UserDefaults.standard.data(forKey: "accounts_v2"),
              let decoded = try? JSONDecoder().decode([Account].self, from: data) else { return }
        accounts = decoded
    }

    private func persistProjects() {
        // Store as [accountId: [GitLabProject]]
        let keyed = Dictionary(uniqueKeysWithValues: projects.map { (k, v) in (k.uuidString, v) })
        guard let data = try? JSONEncoder().encode(keyed) else { return }
        UserDefaults.standard.set(data, forKey: "cached_projects_v1")
    }

    private func loadPersistedProjects() {
        guard let data = UserDefaults.standard.data(forKey: "cached_projects_v1"),
              let keyed = try? JSONDecoder().decode([String: [GitLabProject]].self, from: data) else { return }
        projects = Dictionary(uniqueKeysWithValues: keyed.compactMap { (k, v) in
            guard let uuid = UUID(uuidString: k) else { return nil }
            return (uuid, v)
        })
    }

    private func rebuildServices() {
        for account in accounts {
            let token = KeychainService.shared.loadToken(for: account.id) ?? ""
            services[account.id] = makeService(token: token, account: account)
        }
    }

    private func makeService(token: String, account: Account) -> any PipelineProvider {
        switch account.provider {
        case .gitlab: return GitLabService(token: token, baseURL: account.baseURL)
        case .github: return GitHubService(token: token, baseURL: account.baseURL)
        }
    }

    // MARK: - Polling

    func startPolling() {
        refresh()
        scheduleTimer()
    }

    func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }

    private func scheduleTimer() {
        pollingTimer?.invalidate()
        pollingTimer = Timer.scheduledTimer(withTimeInterval: pollingInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func restartTimer() {
        scheduleTimer()
    }

    func refresh(manual: Bool = false) {
        guard !accounts.isEmpty else { return }
        if manual {
            // Manual refresh retries paused accounts from a clean slate.
            pausedAccounts.removeAll()
            authFailureCounts.removeAll()
        }
        Task { await performRefresh() }
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                guard !account.watchedProjectIds.isEmpty else { continue }
                guard !pausedAccounts.contains(account.id) else { continue }
                // Auto-load projects if cache is empty
                if projects[account.id]?.isEmpty ?? true {
                    group.addTask { [weak self] in await self?.loadProjects(for: account) }
                }
                group.addTask { [weak self] in await self?.refreshAccount(account) }
            }
        }

        lastRefresh = Date()
    }

    private func refreshAccount(_ account: Account) async {
        guard let service = services[account.id] else { return }

        // Pages currently loaded for this account (grows via "Show more"). Default 1.
        let pages = max(1, pageCounts[account.id] ?? 1)
        var collected: [Pipeline] = []
        var anyProjectHasMore = false

        for projectId in account.watchedProjectIds {
            guard let project = projects[account.id]?.first(where: { $0.id == projectId }) else { continue }
            do {
                var projectPipelines: [Pipeline] = []
                for page in 1...pages {
                    let pageBatch = try await service.fetchPipelines(for: project, page: page, perPage: pageSize)
                    projectPipelines.append(contentsOf: pageBatch)
                    // A full page implies there may be more beyond what's loaded.
                    if page == pages && pageBatch.count == pageSize { anyProjectHasMore = true }
                    if pageBatch.count < pageSize { break }
                }

                var batch = projectPipelines
                for i in batch.indices {
                    batch[i].projectId = projectId
                    batch[i].projectName = batch[i].projectName.isEmpty ? project.name : batch[i].projectName
                    batch[i].accountId = account.id
                }
                let baselineKey = "\(account.id.uuidString)-\(projectId)"
                if let baseline = baselines[baselineKey] {
                    for p in batch {
                        let passesFilter = account.filter(for: p.projectId).matches(ref: p.ref)
                        if let prev = knownStatuses[p.id] {
                            if prev != p.status && passesFilter {
                                NotificationManager.shared.notifyPipelineChange(pipeline: p, accountName: account.name)
                            }
                        } else if !knownPipelineIds.contains(p.id) && passesFilter
                                    // Older pipelines surfacing via "Show more" / larger page size aren't new.
                                    && p.createdAt >= baseline.addingTimeInterval(-60) {
                            NotificationManager.shared.notifyNewPipeline(pipeline: p, accountName: account.name)
                        }
                    }
                } else {
                    baselines[baselineKey] = Date()
                }
                for p in batch {
                    knownStatuses[p.id] = p.status
                    knownPipelineIds.insert(p.id)
                }
                collected.append(contentsOf: batch)
            } catch GitLabError.unauthorized {
                handleUnauthorized(account)
                return
            } catch {
                // Don't overwrite an auth error with a transient network error
                if accountErrors[account.id] == nil {
                    accountErrors[account.id] = error.localizedDescription
                }
            }
        }

        hasMore[account.id] = anyProjectHasMore

        if let error = accountErrors[account.id], isTokenError(error) {
            // Keep the auth error visible (it may have come from loadProjects).
        } else {
            accountErrors.removeValue(forKey: account.id)
            authFailureCounts.removeValue(forKey: account.id)
            pausedAccounts.remove(account.id)
        }
        pipelines[account.id] = collected.sorted { $0.updatedAt > $1.updatedAt }

        // Remove stale summaries for pipelines that are no longer active
        let activeIds = Set(collected.filter { $0.status.isActive }.map { $0.id })
        for id in jobSummaries.keys where !activeIds.contains(id) {
            jobSummaries.removeValue(forKey: id)
        }

        // Keep expanded step lists fresh on each poll.
        for p in collected where expandedPipelines.contains(p.id) {
            loadSteps(for: p)
        }

        // Fetch job summaries for active pipelines in parallel
        let activePipelines = collected.filter { $0.status.isActive }
        if !activePipelines.isEmpty, let service = services[account.id] {
            let accountProjects = projects[account.id] ?? []
            var summaries: [Int: PipelineJobSummary] = [:]
            await withTaskGroup(of: (Int, PipelineJobSummary?).self) { group in
                for p in activePipelines {
                    guard let project = accountProjects.first(where: { $0.id == p.projectId }) else { continue }
                    group.addTask {
                        let summary = try? await service.fetchJobSummary(for: p, project: project)
                        return (p.id, summary)
                    }
                }
                for await (id, summary) in group {
                    if let summary { summaries[id] = summary }
                }
            }
            jobSummaries.merge(summaries) { _, new in new }
        }
    }

    func loadProjects(for account: Account) async {
        guard let service = services[account.id] else { return }
        loadingProjectsFor.insert(account.id)
        defer { loadingProjectsFor.remove(account.id) }
        do {
            projects[account.id] = try await service.fetchAllProjects()
            accountErrors.removeValue(forKey: account.id)
            persistProjects()
        } catch GitLabError.unauthorized {
            handleUnauthorized(account)
        } catch {
            accountErrors[account.id] = error.localizedDescription
        }
    }

    // MARK: - Auth failure backoff

    /// Notify once on the first auth failure; after `maxAuthRetries` further
    /// failed polls, pause periodic refresh for the account (one final
    /// notification) instead of spamming on every poll cycle.
    private func handleUnauthorized(_ account: Account) {
        let failures = (authFailureCounts[account.id] ?? 0) + 1
        authFailureCounts[account.id] = failures

        if failures > maxAuthRetries {
            pausedAccounts.insert(account.id)
            accountErrors[account.id] = "Token expired — auto-refresh paused"
            NotificationManager.shared.notifyAccountPaused(accountName: account.name)
        } else {
            accountErrors[account.id] = "Token expired or invalid"
            if failures == 1 {
                NotificationManager.shared.notifyTokenExpired(accountName: account.name)
            }
        }
    }

    private func isTokenError(_ message: String) -> Bool {
        message == "Token expired or invalid" || message == "Token expired — auto-refresh paused"
    }

    // MARK: - Pagination

    func loadMore(for account: Account) {
        guard !loadingMore.contains(account.id) else { return }
        loadingMore.insert(account.id)
        pageCounts[account.id] = max(1, pageCounts[account.id] ?? 1) + 1
        Task {
            await refreshAccount(account)
            loadingMore.remove(account.id)
        }
    }

    func canLoadMore(_ account: Account) -> Bool { hasMore[account.id] ?? false }

    // MARK: - Steps (expandable)

    func toggleExpanded(_ pipeline: Pipeline) {
        if expandedPipelines.contains(pipeline.id) {
            expandedPipelines.remove(pipeline.id)
        } else {
            expandedPipelines.insert(pipeline.id)
            // Always refetch on expand so steps are current; keep any cached copy visible meanwhile.
            loadSteps(for: pipeline)
        }
    }

    func loadSteps(for pipeline: Pipeline) {
        guard let account = accounts.first(where: { $0.id == pipeline.accountId }),
              let service = services[account.id],
              let project = projects[account.id]?.first(where: { $0.id == pipeline.projectId })
        else { return }
        guard !loadingSteps.contains(pipeline.id) else { return }
        loadingSteps.insert(pipeline.id)
        Task {
            defer { loadingSteps.remove(pipeline.id) }
            if let result = try? await service.fetchSteps(for: pipeline, project: project) {
                steps[pipeline.id] = result
            }
        }
    }

    // MARK: - Retry / re-run

    enum RerunMode { case failed, all }

    func rerun(_ pipeline: Pipeline, mode: RerunMode) {
        guard let account = accounts.first(where: { $0.id == pipeline.accountId }),
              let service = services[account.id],
              let project = projects[account.id]?.first(where: { $0.id == pipeline.projectId })
        else { return }
        guard !retrying.contains(pipeline.id) else { return }
        retrying.insert(pipeline.id)
        Task {
            defer { retrying.remove(pipeline.id) }
            do {
                switch mode {
                case .failed: try await service.rerunFailed(pipeline: pipeline, project: project)
                case .all:    try await service.rerunAll(pipeline: pipeline, project: project)
                }
                // Give the provider a moment to register, then refresh.
                try? await Task.sleep(nanoseconds: 800_000_000)
                await refreshAccount(account)
                if expandedPipelines.contains(pipeline.id) { loadSteps(for: pipeline) }
            } catch GitLabError.unauthorized {
                accountErrors[account.id] = "Re-run needs write scope (GitLab: api, GitHub: repo)"
            } catch {
                accountErrors[account.id] = "Re-run failed: \(error.localizedDescription)"
            }
        }
    }

    func rerunStep(_ step: PipelineStep, in pipeline: Pipeline) {
        guard let account = accounts.first(where: { $0.id == pipeline.accountId }),
              let service = services[account.id],
              let project = projects[account.id]?.first(where: { $0.id == pipeline.projectId })
        else { return }
        guard !rerunningSteps.contains(step.id) else { return }
        rerunningSteps.insert(step.id)
        Task {
            defer { rerunningSteps.remove(step.id) }
            do {
                try await service.rerunStep(stepId: step.id, pipeline: pipeline, project: project)
                try? await Task.sleep(nanoseconds: 800_000_000)
                loadSteps(for: pipeline)
                await refreshAccount(account)
            } catch GitLabError.unauthorized {
                accountErrors[account.id] = "Re-run needs write scope (GitLab: api, GitHub: repo)"
            } catch {
                accountErrors[account.id] = "Step re-run failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Derived

    var overallStatus: PipelineStatus? {
        let all = accounts.flatMap { pipelines[$0.id] ?? [] }
        if all.isEmpty { return nil }
        if all.contains(where: { $0.status == .failed }) { return .failed }
        if all.contains(where: { $0.status == .running }) { return .running }
        if all.contains(where: { $0.status == .pending }) { return .pending }
        if all.allSatisfy({ $0.status == .success }) { return .success }
        return nil
    }

    var hasErrors: Bool { !accountErrors.isEmpty }

    var runningCount: Int {
        accounts.flatMap { pipelines[$0.id] ?? [] }.filter { $0.status.isActive }.count
    }
}
