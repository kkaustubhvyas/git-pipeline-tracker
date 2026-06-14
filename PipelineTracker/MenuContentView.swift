import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject var monitor: PipelineMonitor
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar
            Divider()
            mainContent
            Divider()
            footerBar
        }
        .frame(width: 400, height: 540)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text("Pipeline Tracker")
                .font(.headline)
            if monitor.hasErrors {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
            Spacer()
            if monitor.isRefreshing {
                ZStack { ProgressView().scaleEffect(0.4) }
                    .frame(width: 10, height: 10)
            }
            Menu {
                ForEach(PipelineSortOrder.allCases, id: \.rawValue) { order in
                    Button {
                        monitor.sortOrder = order
                    } label: {
                        Label(order.displayName, systemImage: order.systemImage)
                        if monitor.sortOrder == order {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 9, weight: .medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Sort order")
            Button { monitor.refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .medium))
            }
            .buttonStyle(.plain)
            .disabled(monitor.isRefreshing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Main content

    @ViewBuilder
    private var mainContent: some View {
        if monitor.accounts.isEmpty {
            emptyState(
                icon: "person.crop.circle.badge.plus",
                title: "No accounts",
                message: "Add a GitLab account in Settings to get started"
            )
        } else {
            accountList
        }
    }

    private var accountList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(monitor.accounts) { account in
                    AccountSection(account: account)
                        .environmentObject(monitor)
                    if account.id != monitor.accounts.last?.id {
                        Divider().padding(.vertical, 4)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            if let lastRefresh = monitor.lastRefresh {
                Text("Updated \(lastRefresh, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("Settings") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                .buttonStyle(.plain)
                .font(.caption)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.red)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .padding(.top, 16)
            Text(title).font(.callout).fontWeight(.medium)
            Text(message)
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
            Button("Open Settings") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                .buttonStyle(.borderedProminent).controlSize(.small)
                .padding(.bottom, 16)
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
    @State private var finishedLimit = 0

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
    private var isTokenError: Bool { error == "Token expired or invalid" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            accountHeader
            if !isCollapsed {
                if let error {
                    errorBanner(error, isTokenError: isTokenError)
                } else if account.watchedProjectIds.isEmpty {
                    noProjectsHint
                } else if running.isEmpty && finished.isEmpty {
                    quietHint
                } else {
                    if !running.isEmpty {
                        pipelineList(label: "Running", items: running, limit: nil)
                    }
                    if !finished.isEmpty {
                        if !running.isEmpty {
                            Divider().padding(.horizontal, 12).padding(.vertical, 2)
                        }
                        pipelineList(label: nil, items: finished, limit: finishedLimit)
                    }
                }
            }
        }
        .onAppear { finishedLimit = monitor.pageSize }
    }

    @ViewBuilder
    private func pipelineList(label: String?, items: [Pipeline], limit: Int?) -> some View {
        let shown = limit.map { Array(items.prefix($0)) } ?? items
        if let label {
            HStack(spacing: 4) {
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.blue)
                    .tracking(0.5)
                Circle().fill(Color.blue).frame(width: 5, height: 5).opacity(0.7)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
        ForEach(shown) { pipeline in
            PipelineRowView(pipeline: pipeline, jobSummary: pipeline.status.isActive ? monitor.jobSummaries[pipeline.id] : nil)
            if pipeline.id != shown.last?.id {
                Divider().padding(.leading, 40)
            }
        }
        if let limit, items.count > limit {
            Button {
                finishedLimit += monitor.pageSize
            } label: {
                Text("Show \(min(monitor.pageSize, items.count - limit)) more  (\(items.count - limit) remaining)")
                    .font(.caption2)
                    .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
        }
    }

    private var accountHeader: some View {
        HStack(spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() }
            } label: {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
            }
            .buttonStyle(.plain)

            ProviderLogoView(provider: account.provider, size: 14)
                .foregroundStyle(isTokenError ? .red : .secondary)
            Text(account.name)
                .font(.caption).fontWeight(.semibold)
                .foregroundStyle(isTokenError ? .red : .secondary)
            if isTokenError {
                Image(systemName: "key.slash")
                    .font(.caption2).foregroundStyle(.red)
            }
            Spacer()
            if !running.isEmpty {
                Text("\(running.count) active")
                    .font(.caption2).foregroundStyle(.blue)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) { isCollapsed.toggle() }
        }
    }

    private func errorBanner(_ message: String, isTokenError: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isTokenError ? "key.slash" : "exclamationmark.triangle")
                .foregroundStyle(.red)
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
            Spacer()
            if isTokenError {
                Button("Fix") { openSettings(); NSApp.activate(ignoringOtherApps: true) }
                    .font(.caption2)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .tint(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.red.opacity(0.08))
    }

    private var noProjectsHint: some View {
        Text("No projects selected — configure in Settings")
            .font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.vertical, 6)
    }

    private var quietHint: some View {
        Text("No recent pipelines")
            .font(.caption).foregroundStyle(.tertiary)
            .padding(.horizontal, 12).padding(.vertical, 6)
    }
}

// MARK: - Pipeline row

struct PipelineRowView: View {
    let pipeline: Pipeline
    var jobSummary: PipelineJobSummary? = nil
    @State private var isHovered = false

    var body: some View {
        Button(action: openInBrowser) {
            HStack(spacing: 10) {
                PipelineStatusIcon(status: pipeline.status)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pipeline.ref)
                            .font(.callout).fontWeight(.medium).lineLimit(1)
                        Text("#\(pipeline.id)")
                            .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                    }
                    HStack(spacing: 4) {
                        if !pipeline.projectName.isEmpty && !pipeline.projectName.hasPrefix("Project ") {
                            Text(pipeline.projectName)
                                .font(.caption2)
                                .padding(.horizontal, 4).padding(.vertical, 1)
                                .background(Color.primary.opacity(0.07))
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(pipeline.status.displayName)
                            .font(.caption)
                            .foregroundStyle(pipeline.status.color)
                        if let summary = jobSummary, !summary.label.isEmpty {
                            Text("(\(summary.label))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                }

                Spacer()

                Text(timeLabel(for: pipeline))
                    .font(.caption2).foregroundStyle(.tertiary).monospacedDigit()

                Image(systemName: "arrow.up.right.square")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .opacity(isHovered ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isHovered ? Color.primary.opacity(0.05) : .clear)
        .onHover { isHovered = $0 }
    }

    private func openInBrowser() {
        guard let url = URL(string: pipeline.webUrl) else { return }
        NSWorkspace.shared.open(url)
    }

    private func timeLabel(for pipeline: Pipeline) -> String {
        // Active pipelines: live relative timer is useful (shows elapsed)
        // Finished pipelines: freeze the label so it doesn't keep ticking
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
        fmt.dateStyle = .short
        fmt.timeStyle = .none
        return fmt.string(from: pipeline.updatedAt)
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
