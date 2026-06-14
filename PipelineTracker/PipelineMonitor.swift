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

    private var services: [UUID: any PipelineProvider] = [:]
    private var knownStatuses: [Int: PipelineStatus] = [:]
    private var knownPipelineIds: Set<Int> = []
    private var isFirstLoad = true
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

    func refresh() {
        guard !accounts.isEmpty else { return }
        Task { await performRefresh() }
    }

    private func performRefresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                guard !account.watchedProjectIds.isEmpty else { continue }
                // Auto-load projects if cache is empty
                if projects[account.id]?.isEmpty ?? true {
                    group.addTask { [weak self] in await self?.loadProjects(for: account) }
                }
                group.addTask { [weak self] in await self?.refreshAccount(account) }
            }
        }

        isFirstLoad = false
        lastRefresh = Date()
    }

    private func refreshAccount(_ account: Account) async {
        guard let service = services[account.id] else { return }

        var collected: [Pipeline] = []

        for projectId in account.watchedProjectIds {
            guard let project = projects[account.id]?.first(where: { $0.id == projectId }) else { continue }
            do {
                var batch = try await service.fetchPipelines(for: project)
                for i in batch.indices {
                    batch[i].projectId = projectId
                    batch[i].projectName = batch[i].projectName.isEmpty ? project.name : batch[i].projectName
                    batch[i].accountId = account.id
                }
                if !isFirstLoad {
                    for p in batch {
                        let passesFilter = account.filter(for: p.projectId).matches(ref: p.ref)
                        if let prev = knownStatuses[p.id] {
                            if prev != p.status && passesFilter {
                                NotificationManager.shared.notifyPipelineChange(pipeline: p, accountName: account.name)
                            }
                        } else if !knownPipelineIds.contains(p.id) && passesFilter {
                            NotificationManager.shared.notifyNewPipeline(pipeline: p, accountName: account.name)
                        }
                    }
                }
                for p in batch {
                    knownStatuses[p.id] = p.status
                    knownPipelineIds.insert(p.id)
                }
                collected.append(contentsOf: batch)
            } catch GitLabError.unauthorized {
                accountErrors[account.id] = "Token expired or invalid"
                NotificationManager.shared.notifyTokenExpired(accountName: account.name)
                return
            } catch {
                // Don't overwrite an auth error with a transient network error
                if accountErrors[account.id] == nil {
                    accountErrors[account.id] = error.localizedDescription
                }
            }
        }

        if isFirstLoad {
            for p in collected { knownPipelineIds.insert(p.id) }
        }
        if accountErrors[account.id] != "Token expired or invalid" {
            accountErrors.removeValue(forKey: account.id)
        }
        pipelines[account.id] = collected.sorted { $0.updatedAt > $1.updatedAt }

        // Remove stale summaries for pipelines that are no longer active
        let activeIds = Set(collected.filter { $0.status.isActive }.map { $0.id })
        for id in jobSummaries.keys where !activeIds.contains(id) {
            jobSummaries.removeValue(forKey: id)
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
            accountErrors[account.id] = "Token expired or invalid"
            NotificationManager.shared.notifyTokenExpired(accountName: account.name)
        } catch {
            accountErrors[account.id] = error.localizedDescription
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
