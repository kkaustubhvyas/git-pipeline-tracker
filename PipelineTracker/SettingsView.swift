import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var monitor: PipelineMonitor
    @State private var selectedAccountId: UUID?
    @State private var showingAddAccount = false

    var body: some View {
        TabView {
            HSplitView {
                accountSidebar
                if let id = selectedAccountId, let account = monitor.accounts.first(where: { $0.id == id }) {
                    AccountDetailView(account: account)
                        .environmentObject(monitor)
                        .id(id)
                } else {
                    noSelectionPlaceholder
                }
            }
            .tabItem { Label("Accounts", systemImage: "person.2") }

            GeneralSettingsView()
                .environmentObject(monitor)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(minWidth: 720, idealWidth: 780, maxWidth: .infinity, minHeight: 460, idealHeight: 500, maxHeight: .infinity)
        .sheet(isPresented: $showingAddAccount) {
            AddAccountSheet(onAdd: { name, token, provider, url in
                monitor.addAccount(name: name, token: token, provider: provider, baseURL: url)
                selectedAccountId = monitor.accounts.last?.id
            })
        }
        .onAppear {
            if selectedAccountId == nil { selectedAccountId = monitor.accounts.first?.id }
        }
    }

    private var accountSidebar: some View {
        VStack(spacing: 0) {
            List(selection: $selectedAccountId) {
                ForEach(monitor.accounts) { account in
                    AccountSidebarRow(account: account)
                        .environmentObject(monitor)
                        .tag(account.id)
                }
                .onDelete { idx in
                    idx.map { monitor.accounts[$0] }.forEach { monitor.deleteAccount($0) }
                    if !monitor.accounts.contains(where: { $0.id == selectedAccountId }) {
                        selectedAccountId = monitor.accounts.first?.id
                    }
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Button { showingAddAccount = true } label: {
                    Label("Add Account", systemImage: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(8)
                Spacer()
            }
        }
        .frame(width: 180)
    }

    private var noSelectionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("No account selected")
                .font(.headline)
            Button("Add Account") { showingAddAccount = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar row

struct AccountSidebarRow: View {
    @EnvironmentObject var monitor: PipelineMonitor
    let account: Account

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: monitor.accountErrors[account.id] != nil ? "exclamationmark.circle.fill" : account.provider.systemImage)
                .foregroundStyle(monitor.accountErrors[account.id] != nil ? .red : .blue)
            VStack(alignment: .leading, spacing: 1) {
                Text(account.name).font(.callout)
                HStack(spacing: 4) {
                    Text(account.provider.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(Color.blue.opacity(0.1))
                        .foregroundStyle(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Text(hostName(from: account.baseURL))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if monitor.accountErrors[account.id] != nil {
                Image(systemName: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 2)
    }

    private func hostName(from url: String) -> String {
        URL(string: url)?.host ?? url
    }

}

// MARK: - Account detail

struct AccountDetailView: View {
    @EnvironmentObject var monitor: PipelineMonitor
    let account: Account

    @State private var nameDraft = ""
    @State private var tokenDraft = ""
    @State private var urlDraft = ""
    @State private var searchText: String = ""
    @State private var tokenSaved = false
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $selectedTab) {
                Label("Credentials", systemImage: "key").tag(0)
                Label("Projects", systemImage: "folder").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            Group {
                if selectedTab == 0 { credentialsTab }
                else { projectsTab }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            nameDraft = account.name
            tokenDraft = monitor.tokenFor(account)
            urlDraft = account.baseURL
        }
    }

    // MARK: Credentials tab

    private var credentialsTab: some View {
        Form {
            Section("Account Name") {
                HStack {
                    TextField("e.g. Work, Personal", text: $nameDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        var updated = account
                        updated.name = nameDraft
                        monitor.updateAccount(updated)
                    }
                    .disabled(nameDraft == account.name || nameDraft.isEmpty)
                }
            }

            Section("\(account.provider.displayName) Token") {
                SecureField(account.provider.tokenPlaceholder, text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                if let error = monitor.accountErrors[account.id] {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                        Text(error).foregroundStyle(.red)
                    }
                    .font(.caption)
                }

                HStack {
                    Button("Update Token") {
                        monitor.updateAccount(account, newToken: tokenDraft)
                        tokenSaved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { tokenSaved = false }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(tokenDraft.isEmpty)

                    if tokenSaved {
                        Label("Saved", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green).font(.callout)
                    }

                    Spacer()

                    Button {
                        Task { await monitor.loadProjects(for: account) }
                    } label: {
                        HStack(spacing: 4) {
                            if monitor.loadingProjectsFor.contains(account.id) {
                                ProgressView().scaleEffect(0.7)
                            }
                            Text(monitor.loadingProjectsFor.contains(account.id) ? "Loading…" : "Load Projects")
                        }
                    }
                    .disabled(tokenDraft.isEmpty || monitor.loadingProjectsFor.contains(account.id))
                }

                Text(.init(account.provider.tokenScopeHint))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Instance URL") {
                HStack {
                    TextField(account.provider.defaultBaseURL, text: $urlDraft)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        var updated = account
                        updated.baseURL = urlDraft
                        monitor.updateAccount(updated)
                    }
                    .disabled(urlDraft == account.baseURL || urlDraft.isEmpty)
                }
                Text("Change only for self-hosted \(account.provider.displayName) instances.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Delete Account", role: .destructive) {
                    monitor.deleteAccount(account)
                }
            }
        }
        .padding()
    }

    // MARK: Projects tab

    private var projectsTab: some View {
        let allProjects = monitor.projects[account.id] ?? []
        let filtered = searchText.isEmpty ? allProjects : allProjects.filter {
            $0.name.localizedCaseInsensitiveContains(searchText) ||
            $0.nameWithNamespace.localizedCaseInsensitiveContains(searchText)
        }

        return VStack(spacing: 0) {
            if allProjects.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark")
                        .font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("No projects loaded")
                    Button("Load Projects") {
                        Task { await monitor.loadProjects(for: account) }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(monitor.loadingProjectsFor.contains(account.id))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(allProjects.count) projects…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                    Text("\(account.watchedProjectIds.count) watching")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                List(filtered) { project in
                    ProjectToggleRow(account: account, project: project)
                        .environmentObject(monitor)
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Project toggle row

private struct ProjectToggleRow: View {
    @EnvironmentObject var monitor: PipelineMonitor
    let account: Account
    let project: GitLabProject
    @State private var isExpanded = false
    @State private var patternDraft = ""

    var isWatched: Bool { account.watchedProjectIds.contains(project.id) }
    var currentFilter: ProjectFilter { account.filter(for: project.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { isWatched },
                    set: { on in
                        var updated = account
                        if on { updated.watchedProjectIds.insert(project.id) }
                        else {
                            updated.watchedProjectIds.remove(project.id)
                            isExpanded = false
                        }
                        monitor.updateAccount(updated)
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(project.name)
                            .font(.callout)
                            .fontWeight(isWatched ? .semibold : .regular)
                        HStack(spacing: 4) {
                            Text(project.nameWithNamespace)
                                .font(.caption).foregroundStyle(.secondary)
                            if !currentFilter.isEmpty {
                                Text("\(currentFilter.refPatterns.count) filter\(currentFilter.refPatterns.count == 1 ? "" : "s")")
                                    .font(.caption2)
                                    .padding(.horizontal, 4).padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.12))
                                    .foregroundStyle(.blue)
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                            }
                        }
                    }
                }

                Spacer()

                if isWatched {
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "line.3.horizontal.decrease.circle")
                            .font(.caption)
                            .foregroundStyle(currentFilter.isEmpty ? Color.secondary : Color.blue)
                    }
                    .buttonStyle(.plain)
                    .help("Branch filters")
                }
            }

            if isWatched && isExpanded {
                branchFilterSection
                    .padding(.leading, 24)
                    .padding(.top, 6)
                    .padding(.bottom, 4)
            }
        }
        .padding(.vertical, 3)
    }

    private var branchFilterSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Show only branches matching:")
                .font(.caption).foregroundStyle(.secondary)

            if currentFilter.isEmpty {
                Text("All branches shown  ·  Add patterns to restrict")
                    .font(.caption2).foregroundStyle(.tertiary).italic()
            } else {
                patternChips
            }

            HStack(spacing: 6) {
                TextField("e.g. main, deploy/*, release/**", text: $patternDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.caption, design: .monospaced))
                    .onSubmit { addPattern() }
                Button("Add", action: addPattern)
                    .controlSize(.small)
                    .disabled(patternDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            Text("Supports * wildcard.  Examples: `main`  `deploy/*`  `release/**`")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(8)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var patternChips: some View {
        FlowLayout(spacing: 4) {
            ForEach(currentFilter.refPatterns, id: \.self) { pattern in
                HStack(spacing: 3) {
                    Text(pattern)
                        .font(.system(.caption2, design: .monospaced))
                    Button {
                        var updated = account
                        updated.projectFilters["\(project.id)", default: ProjectFilter()]
                            .refPatterns.removeAll { $0 == pattern }
                        if updated.projectFilters["\(project.id)"]?.refPatterns.isEmpty == true {
                            updated.projectFilters.removeValue(forKey: "\(project.id)")
                        }
                        monitor.updateAccount(updated)
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.blue.opacity(0.12))
                .foregroundStyle(.blue)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    private func addPattern() {
        let raw = patternDraft.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        // Support comma-separated input
        let patterns = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var updated = account
        for p in patterns {
            if !(updated.projectFilters["\(project.id)"]?.refPatterns.contains(p) ?? false) {
                updated.projectFilters["\(project.id)", default: ProjectFilter()].refPatterns.append(p)
            }
        }
        monitor.updateAccount(updated)
        patternDraft = ""
    }
}

// MARK: - Flow layout for chips

struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        let height = rows.map { $0.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0 }
            .reduce(0) { $0 + $1 + spacing } - spacing
        return CGSize(width: proposal.width ?? 0, height: max(height, 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = computeRows(proposal: proposal, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            let rowHeight = row.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            for view in row {
                let size = view.sizeThatFits(.unspecified)
                view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }

    private func computeRows(proposal: ProposedViewSize, subviews: Subviews) -> [[LayoutSubview]] {
        var rows: [[LayoutSubview]] = [[]]
        var x: CGFloat = 0
        let maxWidth = proposal.width ?? .infinity
        for view in subviews {
            let w = view.sizeThatFits(.unspecified).width
            if x + w > maxWidth && !rows[rows.endIndex - 1].isEmpty {
                rows.append([])
                x = 0
            }
            rows[rows.endIndex - 1].append(view)
            x += w + spacing
        }
        return rows
    }
}

// MARK: - Number stepper field (manual entry + stepper)

struct NumberStepperField: View {
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step: Int = 1
    var suffix: String = ""

    private var clamped: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(range.upperBound, max(range.lowerBound, $0)) }
        )
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: clamped, format: .number)
                .textFieldStyle(.roundedBorder)
                .font(Theme.mono(12))
                .multilineTextAlignment(.trailing)
                .frame(width: 58)
            if !suffix.isEmpty {
                Text(suffix).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Stepper("", value: clamped, in: range, step: step)
                .labelsHidden()
        }
        .fixedSize()
    }
}

// MARK: - General settings

struct GeneralSettingsView: View {
    @EnvironmentObject var monitor: PipelineMonitor
    @State private var intervalDraft: Double = 10
    @State private var pageSizeDraft: Double = 20
    @State private var intervalSeconds: Int = 10
    @State private var pageSizeInt: Int = 20
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    @State private var testSent = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    private let intervalPresets: [Int] = [5, 10, 30, 60, 300]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.lg) {
                startupCard
                pollingCard
                pageSizeCard
                notificationsCard
            }
            .padding(Theme.xl)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            intervalDraft = monitor.pollingInterval
            intervalSeconds = Int(monitor.pollingInterval)
            pageSizeDraft = Double(monitor.pageSize)
            pageSizeInt = monitor.pageSize
            launchAtLogin = LaunchAtLogin.isEnabled
            NotificationManager.shared.checkAuthStatus { notifStatus = $0 }
        }
    }

    // MARK: Cards

    private func card<Content: View>(_ icon: String, _ title: String, _ subtitle: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.md) {
            HStack(spacing: Theme.sm) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.accent.opacity(0.14)).frame(width: 28, height: 28)
                    Image(systemName: icon).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.display(13, .semibold))
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            content()
        }
        .padding(Theme.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surfaceRaised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }

    private var startupCard: some View {
        card("power", "Startup", "Launch automatically when you log in") {
            Toggle(isOn: $launchAtLogin) {
                Text("Launch at login").font(.system(size: 12))
            }
            .toggleStyle(.switch)
            .tint(Theme.accent)
            .onChange(of: launchAtLogin) { _, enabled in
                let ok = LaunchAtLogin.setEnabled(enabled)
                if !ok || launchAtLogin != LaunchAtLogin.isEnabled {
                    launchAtLogin = LaunchAtLogin.isEnabled
                }
            }
        }
    }

    private var pollingCard: some View {
        card("timer", "Polling interval", "How often pipelines are checked. Lower = more API calls.") {
            VStack(alignment: .leading, spacing: Theme.md) {
                HStack(spacing: Theme.md) {
                    Slider(value: $intervalDraft, in: 1...3600)
                        .onChange(of: intervalDraft) { _, v in
                            let s = Int(v); intervalSeconds = s; monitor.pollingInterval = Double(s)
                        }
                    NumberStepperField(value: $intervalSeconds, range: 1...3600, step: 5, suffix: "sec")
                        .onChange(of: intervalSeconds) { _, v in
                            intervalDraft = Double(v); monitor.pollingInterval = Double(v)
                        }
                }
                HStack(spacing: 6) {
                    ForEach(intervalPresets, id: \.self) { preset in
                        Button(formatInterval(Double(preset))) {
                            intervalSeconds = preset; intervalDraft = Double(preset); monitor.pollingInterval = Double(preset)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(intervalSeconds == preset ? Theme.accent : nil)
                    }
                    Spacer()
                    Text("currently \(formatInterval(Double(intervalSeconds)))")
                        .font(Theme.mono(10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var pageSizeCard: some View {
        card("list.number", "Pipelines per fetch", "Records pulled per page. \"Load more\" fetches the next page.") {
            HStack(spacing: Theme.md) {
                Slider(value: $pageSizeDraft, in: 5...100, step: 1)
                    .onChange(of: pageSizeDraft) { _, v in
                        let n = Int(v); pageSizeInt = n; monitor.pageSize = n
                    }
                NumberStepperField(value: $pageSizeInt, range: 5...100, step: 5, suffix: "rows")
                    .onChange(of: pageSizeInt) { _, v in
                        pageSizeDraft = Double(v); monitor.pageSize = v
                    }
            }
        }
    }

    private var notificationsCard: some View {
        card("bell.badge", "Notifications", "Get notified when a pipeline changes state") {
            VStack(alignment: .leading, spacing: Theme.md) {
                HStack(spacing: Theme.sm) {
                    Image(systemName: notifStatusIcon).foregroundStyle(notifStatusColor)
                    Text(notifStatusLabel).font(.system(size: 12))
                    Spacer()
                    if notifStatus == .denied {
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
                        }
                        .controlSize(.small)
                    } else if notifStatus == .notDetermined {
                        Button("Request Permission") {
                            NotificationManager.shared.requestPermission { _ in
                                NotificationManager.shared.checkAuthStatus { notifStatus = $0 }
                            }
                        }
                        .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.small)
                    }
                }
                if notifStatus == .authorized || notifStatus == .provisional {
                    HStack(spacing: Theme.sm) {
                        Button("Send Test Notification") {
                            NotificationManager.shared.sendTest()
                            testSent = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testSent = false }
                        }
                        .buttonStyle(.bordered).controlSize(.small)
                        if testSent {
                            Label("Sent", systemImage: "checkmark.circle.fill")
                                .font(.caption).foregroundStyle(.green)
                        }
                    }
                    Text("If it doesn't appear, check System Settings › Notifications › Pipeline Tracker.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var notifStatusIcon: String {
        switch notifStatus {
        case .authorized, .provisional: return "bell.fill"
        case .denied: return "bell.slash.fill"
        default: return "bell.badge"
        }
    }

    private var notifStatusColor: Color {
        switch notifStatus {
        case .authorized, .provisional: return .green
        case .denied: return .red
        default: return .orange
        }
    }

    private var notifStatusLabel: String {
        switch notifStatus {
        case .authorized: return "Notifications authorized"
        case .provisional: return "Provisional (quiet delivery)"
        case .denied: return "Notifications denied — enable in System Settings"
        case .notDetermined: return "Permission not yet requested"
        default: return "Unknown status"
        }
    }

    private func formatInterval(_ s: Double) -> String {
        let secs = Int(s)
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 {
            let m = secs / 60, r = secs % 60
            return r == 0 ? "\(m)m" : "\(m)m\(r)s"
        }
        return "1h"
    }
}

// MARK: - Add account sheet

struct AddAccountSheet: View {
    let onAdd: (String, String, Provider, String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var token = ""
    @State private var provider: Provider = .gitlab
    @State private var baseURL = Provider.gitlab.defaultBaseURL

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Account").font(.headline)

            Form {
                Picker("Provider", selection: $provider) {
                    ForEach(Provider.allCases, id: \.self) { p in
                        Label(p.displayName, systemImage: p.systemImage).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: provider) { _, newVal in
                    baseURL = newVal.defaultBaseURL
                }

                TextField("Account name (e.g. Work, Personal)", text: $name)

                SecureField(provider.tokenPlaceholder, text: $token)
                    .font(.system(.body, design: .monospaced))

                LabeledContent("Instance URL") {
                    TextField(provider.defaultBaseURL, text: $baseURL)
                }
            }
            .formStyle(.grouped)

            Text(provider.tokenScopeHint)
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Account") {
                    onAdd(name, token, provider, baseURL)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(name.isEmpty || token.isEmpty || baseURL.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
