import SwiftUI

@main
struct PipelineTrackerApp: App {
    @StateObject private var monitor = PipelineMonitor()
    init() { _ = NotificationManager.shared }  // initializes delegate early

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(monitor)
        } label: {
            MenuBarLabel(status: monitor.overallStatus, isRefreshing: monitor.isRefreshing, runningCount: monitor.runningCount)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(monitor)
        }
    }
}

struct MenuBarLabel: View {
    let status: PipelineStatus?
    let isRefreshing: Bool
    let runningCount: Int

    var body: some View {
        HStack(spacing: 3) {
            statusIcon
            if runningCount > 0 {
                Text("\(runningCount)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)
            }
        }
        .frame(minWidth: 20)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if isRefreshing {
            Image(systemName: "arrow.triangle.2.circlepath")
                .symbolEffect(.rotate, isActive: true)
                .foregroundStyle(.primary)
        } else if let status {
            Image(systemName: status.systemImage)
                .foregroundStyle(iconColor(for: status))
                .symbolEffect(.pulse, isActive: status == .running)
        } else {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .foregroundStyle(.secondary)
        }
    }

    private func iconColor(for status: PipelineStatus) -> Color {
        switch status {
        case .failed: return .red
        case .running: return .blue
        case .success: return .green
        case .pending, .preparing: return .orange
        default: return Color(nsColor: .labelColor)
        }
    }
}
