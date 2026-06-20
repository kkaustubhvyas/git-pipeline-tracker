import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var monitor: PipelineMonitor
    @Environment(\.openSettings) private var openSettings

    private var maxScrollHeight: CGFloat {
        (NSScreen.main?.frame.height ?? 800) * 0.7 - 92
    }

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider().overlay(Theme.hairline)
            mainContent
            Divider().overlay(Theme.hairline)
            footerBar
        }
        .frame(width: Theme.panelWidth)
        .background(Theme.surface)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Theme.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Theme.accent.opacity(0.16))
                    .frame(width: 26, height: 26)
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.accent)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("Pipeline Tracker")
                    .font(Theme.display(14, .semibold))
                statusSummary
            }

            Spacer()

            if monitor.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.55)
                    .frame(width: 16, height: 16)
            }

            sortMenu
            iconButton("arrow.clockwise", help: "Refresh now") { monitor.refresh() }
                .disabled(monitor.isRefreshing)
        }
        .padding(.horizontal, Theme.md)
        .padding(.vertical, Theme.sm + 2)
    }

    @ViewBuilder
    private var statusSummary: some View {
        HStack(spacing: 5) {
            if let status = monitor.overallStatus {
                Circle().fill(status.color).frame(width: 6, height: 6)
                Text(headlineText(for: status))
                    .font(Theme.mono(10))
                    .foregroundStyle(.secondary)
            } else {
                Text(monitor.accounts.isEmpty ? "no accounts" : "all quiet")
                    .font(Theme.mono(10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func headlineText(for status: PipelineStatus) -> String {
        let running = monitor.runningCount
        if running > 0 { return "\(running) running" }
        switch status {
        case .failed: return "needs attention"
        case .success: return "all passing"
        default: return status.displayName.lowercased()
        }
    }

    private var sortMenu: some View {
        Menu {
            ForEach(PipelineSortOrder.allCases, id: \.rawValue) { order in
                Button {
                    monitor.sortOrder = order
                } label: {
                    Label(order.displayName, systemImage: order.systemImage)
                    if monitor.sortOrder == order { Image(systemName: "checkmark") }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Sort finished pipelines")
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if monitor.accounts.isEmpty {
            emptyState
        } else {
            accountList
        }
    }

    private var accountList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(monitor.accounts) { account in
                    AccountSection(account: account)
                        .environmentObject(monitor)
                    if account.id != monitor.accounts.last?.id {
                        Divider().overlay(Theme.hairline)
                            .padding(.vertical, Theme.xs)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.height
            } action: { newHeight in
                if newHeight > 0 { contentHeight = newHeight }
            }
        }
        .frame(height: contentHeight == 0 ? maxScrollHeight : min(contentHeight, maxScrollHeight))
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: Theme.md) {
            if let lastRefresh = monitor.lastRefresh {
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                    Text("\(lastRefresh, style: .relative) ago")
                        .font(Theme.mono(10))
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer()
            Button("Settings") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                .buttonStyle(.plain)
                .font(Theme.display(11, .medium))
                .foregroundStyle(.secondary)
            Text("·").foregroundStyle(.quaternary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(Theme.display(11, .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.md)
        .padding(.vertical, Theme.sm)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.md) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.1)).frame(width: 56, height: 56)
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            .padding(.top, Theme.xl)
            VStack(spacing: 4) {
                Text("No accounts yet")
                    .font(Theme.display(15, .semibold))
                Text("Connect GitLab or GitHub to start\nwatching your pipelines.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button {
                openSettings(); NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text("Add Account")
                    .font(Theme.display(12, .semibold))
                    .padding(.horizontal, Theme.md)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            .padding(.bottom, Theme.xl)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Account section

struct AccountSection: View {
    @EnvironmentObject var monitor: PipelineMonitor
    @Environment(\.openSettings) private var openSettings
    let account: Account

    @State private var isCollapsed = false

    private var allFiltered: [Pipeline] {
        (monitor.pipelines[account.id] ?? []).filter { p in
            account.filter(for: p.projectId).matches(ref: p.ref)
        }
    }

    private var running: [Pipeline] {
        allFiltered.filter { $0.status.isActive }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private var finished: [Pipeline] {
        allFiltered.filter { !$0.status.isActive }
            .sorted { a, b in
                switch monitor.sortOrder {
                case .timeStarted:  return a.createdAt > b.createdAt
                case .timeFinished: return a.updatedAt > b.updatedAt
                }
            }
    }

    private var error: String? { monitor.accountErrors[account.id] }
    private var isTokenError: Bool { error?.contains("expired") == true || error?.contains("invalid") == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountHeader
            if !isCollapsed {
                if let error {
                    errorBanner(error)
                } else if account.watchedProjectIds.isEmpty {
                    hint("No projects selected — configure in Settings", icon: "folder.badge.questionmark")
                } else if running.isEmpty && finished.isEmpty {
                    hint("No recent pipelines", icon: "moon.zzz")
                } else {
                    if !running.isEmpty {
                        groupLabel("Running", count: running.count, accent: true)
                        pipelineRows(running)
                    }
                    if !finished.isEmpty {
                        groupLabel("Recent", count: nil, accent: false)
                        pipelineRows(finished)
                        showMoreButton
                    }
                }
            }
        }
        .padding(.bottom, Theme.xs)
    }

    @ViewBuilder
    private func pipelineRows(_ items: [Pipeline]) -> some View {
        ForEach(items) { pipeline in
            PipelineRowView(pipeline: pipeline,
                            jobSummary: pipeline.status.isActive ? monitor.jobSummaries[pipeline.id] : nil)
                .environmentObject(monitor)
        }
    }

    @ViewBuilder
    private var showMoreButton: some View {
        if monitor.canLoadMore(account) {
            Button {
                monitor.loadMore(for: account)
            } label: {
                HStack(spacing: 5) {
                    if monitor.loadingMore.contains(account.id) {
                        ProgressView().controlSize(.small).scaleEffect(0.6).frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.down.circle").font(.system(size: 10))
                    }
                    Text(monitor.loadingMore.contains(account.id) ? "Loading…" : "Load more")
                        .font(Theme.display(11, .medium))
                }
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, Theme.md)
                .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .disabled(monitor.loadingMore.contains(account.id))
        }
    }

    private func groupLabel(_ text: String, count: Int?, accent: Bool) -> some View {
        HStack(spacing: 5) {
            Eyebrow(text: text, color: accent ? Theme.accent : .secondary)
            if accent {
                Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    .modifier(PulseModifier())
            }
            if let count {
                Text("\(count)")
                    .font(Theme.mono(9.5, .medium))
                    .foregroundStyle(accent ? Theme.accent : .secondary)
            }
        }
        .padding(.horizontal, Theme.md)
        .padding(.top, Theme.sm)
        .padding(.bottom, Theme.xs)
    }

    private var accountHeader: some View {
        HStack(spacing: Theme.sm) {
            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)

            ProviderLogoView(provider: account.provider, size: 15)
                .foregroundStyle(isTokenError ? .red : .secondary)

            Text(account.name)
                .font(Theme.display(12.5, .semibold))
                .foregroundStyle(isTokenError ? .red : .primary)

            if isTokenError {
                Image(systemName: "key.slash").font(.caption2).foregroundStyle(.red)
            }

            Spacer()

            if !running.isEmpty {
                HStack(spacing: 4) {
                    Circle().fill(Theme.accent).frame(width: 5, height: 5)
                    Text("\(running.count)")
                        .font(Theme.mono(10, .semibold))
                        .foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.accent.opacity(0.12))
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, Theme.md)
        .padding(.top, Theme.md)
        .padding(.bottom, Theme.xs)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: Theme.sm) {
            Image(systemName: isTokenError ? "key.slash" : "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
            Spacer()
            if isTokenError {
                Button("Fix") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                    .font(Theme.display(10, .semibold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(.red)
            }
        }
        .padding(.horizontal, Theme.md)
        .padding(.vertical, Theme.sm)
        .background(Color.red.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
        .padding(.horizontal, Theme.sm)
        .padding(.vertical, Theme.xs)
    }

    private func hint(_ text: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.tertiary)
            Text(text).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Theme.md)
        .padding(.vertical, Theme.sm)
    }
}

// MARK: - Pipeline row

struct PipelineRowView: View {
    @EnvironmentObject var monitor: PipelineMonitor
    let pipeline: Pipeline
    var jobSummary: PipelineJobSummary? = nil
    @State private var isHovered = false

    private var isExpanded: Bool { monitor.expandedPipelines.contains(pipeline.id) }
    private var isRetrying: Bool { monitor.retrying.contains(pipeline.id) }

    var body: some View {
        VStack(spacing: 0) {
            mainRow
            if isExpanded {
                stepsPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(isHovered && !isExpanded ? Theme.surfaceHover : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous))
        .padding(.horizontal, Theme.sm)
        .onHover { isHovered = $0 }
    }

    private var mainRow: some View {
        HStack(spacing: Theme.sm + 2) {
            PipelineStatusIcon(status: pipeline.status).frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pipeline.workflowName.isEmpty ? pipeline.ref : pipeline.workflowName)
                        .font(Theme.display(12.5, .medium))
                        .lineLimit(1)
                    Text("#\(pipeline.id)")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(.tertiary)
                }
                subline
            }

            Spacer(minLength: Theme.xs)

            Text(timeLabel)
                .font(Theme.mono(9.5))
                .foregroundStyle(.tertiary)

            // Expand affordance — purely indicative; the whole row toggles.
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 14)

            trailingControls
        }
        .padding(.horizontal, Theme.sm)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { monitor.toggleExpanded(pipeline) }
        }
    }

    private var subline: some View {
        HStack(spacing: Theme.xs) {
            if !pipeline.projectName.isEmpty && !pipeline.projectName.hasPrefix("Project ") {
                Text(pipeline.projectName)
                    .font(Theme.mono(9))
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.surfaceRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if !pipeline.workflowName.isEmpty {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
                    Text(pipeline.ref).font(Theme.mono(9))
                }
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Text(pipeline.status.displayName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(pipeline.status.color)
            if let summary = jobSummary, !summary.label.isEmpty {
                Text(summary.label)
                    .font(Theme.mono(9))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var trailingControls: some View {
        // Open the full pipeline in the browser.
        Button(action: openInBrowser) {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open pipeline in browser")

        // Re-run menu — available once the pipeline has finished (success, failed, canceled…).
        if !pipeline.status.isActive {
            Menu {
                Button {
                    monitor.rerun(pipeline, mode: .all)
                } label: {
                    Label("Re-run all jobs", systemImage: "arrow.triangle.2.circlepath")
                }
                if pipeline.status.isRetryable {
                    Button {
                        monitor.rerun(pipeline, mode: .failed)
                    } label: {
                        Label("Re-run failed jobs", systemImage: "arrow.clockwise")
                    }
                }
            } label: {
                if isRetrying {
                    ProgressView().controlSize(.small).scaleEffect(0.5).frame(width: 20, height: 20)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(pipeline.status.isRetryable ? Theme.accent : .secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(isRetrying)
            .help("Re-run pipeline")
        }
    }

    // MARK: Steps panel

    private var stepsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            let list = monitor.steps[pipeline.id]
            if monitor.loadingSteps.contains(pipeline.id) && (list?.isEmpty ?? true) {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).scaleEffect(0.6)
                    Text("Loading steps…").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .padding(.vertical, Theme.sm)
                .padding(.leading, 30)
            } else if let list, list.isEmpty {
                Text("No steps reported")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .padding(.vertical, Theme.sm).padding(.leading, 30)
            } else if let list {
                ForEach(groupedByStage(list), id: \.0) { stage, steps in
                    if let stage {
                        Text(stage.uppercased())
                            .font(Theme.display(8.5, .bold))
                            .tracking(0.6)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 30).padding(.top, 6).padding(.bottom, 2)
                    }
                    ForEach(steps) { step in
                        StepRow(step: step, pipeline: pipeline).environmentObject(monitor)
                    }
                }
            }
        }
        .padding(.bottom, Theme.sm)
        .padding(.top, 2)
        .background(Theme.surfaceRaised.opacity(0.6))
    }

    /// Group GitLab steps by stage; GitHub steps (nil stage) stay in one group.
    private func groupedByStage(_ steps: [PipelineStep]) -> [(String?, [PipelineStep])] {
        if steps.allSatisfy({ $0.stage == nil }) { return [(nil, steps)] }
        var order: [String] = []
        var map: [String: [PipelineStep]] = [:]
        for s in steps {
            let key = s.stage ?? "—"
            if map[key] == nil { order.append(key) }
            map[key, default: []].append(s)
        }
        return order.map { ($0, map[$0]!) }
    }

    private func openInBrowser() {
        guard let url = URL(string: pipeline.webUrl) else { return }
        NSWorkspace.shared.open(url)
    }

    private var timeLabel: String {
        if pipeline.status.isActive {
            let elapsed = Int(-pipeline.updatedAt.timeIntervalSinceNow)
            if elapsed < 60 { return "\(elapsed)s" }
            if elapsed < 3600 { return "\(elapsed / 60)m" }
            return "\(elapsed / 3600)h"
        }
        let ago = Int(-pipeline.updatedAt.timeIntervalSinceNow)
        if ago < 60 { return "just now" }
        if ago < 3600 { return "\(ago / 60)m ago" }
        if ago < 86400 { return "\(ago / 3600)h ago" }
        let fmt = DateFormatter()
        fmt.dateStyle = .short; fmt.timeStyle = .none
        return fmt.string(from: pipeline.updatedAt)
    }
}

// MARK: - Step row

struct StepRow: View {
    @EnvironmentObject var monitor: PipelineMonitor
    let step: PipelineStep
    let pipeline: Pipeline
    @State private var isHovered = false

    private var isRerunning: Bool { monitor.rerunningSteps.contains(step.id) }
    private var canRerun: Bool { !step.status.isActive }

    var body: some View {
        HStack(spacing: Theme.sm) {
            Image(systemName: step.status.systemImage)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(step.status.color)
                .frame(width: 14)
            Text(step.name)
                .font(.system(size: 11))
                .foregroundStyle(step.isOptional ? .secondary : .primary)
                .lineLimit(1)
            if step.isOptional {
                Text("optional")
                    .font(Theme.mono(8))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4).padding(.vertical, 0.5)
                    .background(Theme.surfaceRaised)
                    .clipShape(Capsule())
            }
            Spacer()
            Text(step.status.displayName)
                .font(Theme.mono(9))
                .foregroundStyle(step.status.color.opacity(0.85))

            // Re-run this single step.
            if canRerun {
                Button { monitor.rerunStep(step, in: pipeline) } label: {
                    if isRerunning {
                        ProgressView().controlSize(.small).scaleEffect(0.45).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(isHovered ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                            .frame(width: 16, height: 16)
                            .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .disabled(isRerunning)
                .help("Re-run this step")
            }

            if step.webURL != nil {
                Button {
                    if let s = step.webURL, let url = URL(string: s) { NSWorkspace.shared.open(url) }
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(isHovered ? .secondary : .tertiary)
                        .frame(width: 14, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open step")
            }
        }
        .padding(.leading, 30).padding(.trailing, Theme.md)
        .padding(.vertical, 3.5)
        .contentShape(Rectangle())
        .background(isHovered ? Theme.surfaceHover : .clear)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Pulse modifier (running indicator)

struct PulseModifier: ViewModifier {
    @State private var on = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.35 : 0.9)
            .opacity(on ? 0.4 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

// MARK: - Provider logo

struct ProviderLogoView: View {
    let provider: Provider
    let size: CGFloat

    var body: some View {
        if NSImage(named: provider.logoImageName) != nil {
            Image(provider.logoImageName)
                .resizable().scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: provider.systemImage)
                .font(.system(size: size * 0.75, weight: .medium))
        }
    }
}

// MARK: - Status icon

struct PipelineStatusIcon: View {
    let status: PipelineStatus
    @State private var animating = false

    var body: some View {
        ZStack {
            if status == .running {
                Circle()
                    .stroke(status.color.opacity(0.25), lineWidth: 1.5)
                    .frame(width: 18, height: 18)
                    .scaleEffect(animating ? 1.8 : 1.0)
                    .opacity(animating ? 0 : 0.8)
                    .animation(.easeOut(duration: 1.2).repeatForever(autoreverses: false), value: animating)
            }
            Image(systemName: status.systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(status.color)
                .symbolEffect(.rotate, isActive: status == .running)
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}
