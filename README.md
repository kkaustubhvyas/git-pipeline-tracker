# Pipeline Tracker

A native macOS menu bar app for monitoring GitLab and GitHub CI/CD pipelines in real time.

## Features

- Real-time pipeline status in the menu bar icon with running count badge
- Support for GitLab (gitlab.com + self-hosted) and GitHub (github.com + GitHub Enterprise)
- Multi-account support with per-account project selection
- Branch/ref filtering per project using glob patterns (main, deploy/*, release/**)
- Configurable polling interval (1 second – 1 hour, default 10 seconds)
- Native macOS notifications for pipeline start, completion, failure, and token expiry
- Pipelines grouped by account; running pipelines always shown at top in a distinct section
- Finished pipelines sortable by Time Started or Time Finished (descending)
- Collapsible account groups
- Configurable page size (max pipelines shown before "Show more")
- Secure token storage via macOS Keychain
- Persisted projects list and watched-project selection

## Requirements

- macOS 15.0 (Sequoia) or later
- Xcode 16.0 or later
- GitLab personal access token with `read_api` scope, OR GitHub personal access token with `repo` scope

## Building & Running

### Prerequisites

Install Xcode Command Line Tools:

```bash
xcode-select --install
```

### Quick Start

```bash
git clone <repo-url>
cd pipeline-tracker
make run        # build and launch
```

### Makefile Targets

| Command | Description |
|---------|-------------|
| `make build` | Compile the app (ad-hoc signed) |
| `make run` | Build and launch via Finder |
| `make launch` | Launch previously-built binary |
| `make dev` | Build and run in terminal (shows live logs) |
| `make test` | Run unit tests |
| `make logs` | Stream app logs from system log |
| `make clean` | Clean DerivedData |

## Configuration

### Adding an Account

1. Click the menu bar icon → **Settings**
2. In the **Accounts** tab, click **Add Account**
3. Select the provider (GitLab or GitHub)
4. Enter a display name, personal access token, and instance URL (for self-hosted instances)
5. Click **Add Account**

### Token Scopes

| Provider | Required scope |
|----------|---------------|
| GitLab | `read_api` |
| GitHub | `repo` (or `public_repo` for public repositories only) |

Tokens are stored in the macOS Keychain and never written to disk.

### Selecting Projects

1. In Settings → Accounts → select an account → **Projects** tab
2. Click **Load Projects** to fetch your repositories
3. Toggle the projects you want to monitor
4. Optionally expand a project to add branch filters (e.g. `main`, `deploy/*`, `release/**`)

### Branch Filters

Patterns use shell-style glob matching with `*` as wildcard:

| Pattern | Matches |
|---------|---------|
| `main` | Exactly `main` |
| `deploy/*` | `deploy/prod`, `deploy/staging` |
| `release/*-stable` | `release/v1-stable`, `release/v2.0-stable` |
| `*` | Any branch |

Leave the filter list empty to show all branches.

### General Settings

- **Polling Interval** — how often to call the API (1s – 1h). Lower intervals increase API usage.
- **Pipelines Per Account** — page size before "Show more" appears (5 – 100).
- **Notifications** — shows current permission status with a test button and a direct link to System Settings if denied.

## Architecture

```
PipelineTrackerApp.swift    — @main entry point, MenuBarExtra + Settings scene
├── PipelineMonitor.swift   — @MainActor ObservableObject, polling timer, state
├── Models.swift            — Provider, Account, Pipeline, PipelineStatus, ProjectFilter
├── GitLabService.swift     — GitLab REST API v4 client (PipelineProvider)
├── GitHubService.swift     — GitHub Actions REST API client (PipelineProvider)
├── KeychainService.swift   — Secure token storage via Security framework
├── NotificationManager.swift — UNUserNotificationCenter wrapper + delegate
├── MenuContentView.swift   — Menu bar popover UI
└── SettingsView.swift      — Settings window (Accounts + General tabs)
```

### Key Design Decisions

**Protocol-based providers** — `PipelineProvider` protocol lets `PipelineMonitor` treat GitLab and GitHub identically. Adding a new provider (Bitbucket, CircleCI) requires only a new conforming type.

**Keychain over UserDefaults** — tokens are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, meaning they survive app restarts but not device migration without explicit export.

**Resilient Codable migration** — `Account` uses `decodeIfPresent` with defaults for every optional field, so old stored JSON (missing `provider`, `projectFilters`, legacy `gitlabURL` key) never causes a decode failure.

**Parallel polling** — `performRefresh()` uses `withTaskGroup` to poll all accounts simultaneously.

**Ad-hoc signing** — required for `UNUserNotificationCenter` in sandboxed apps without an Apple Developer certificate.

## Notifications

The app sends macOS notifications for:

- Pipeline Started — new pipeline ID detected
- Pipeline Succeeded
- Pipeline Failed
- Pipeline Canceled
- Pipeline Skipped
- Token Expired — once per account until resolved

Notifications respect branch filters: if a project is configured to show only `deploy/*` branches, no notification fires for `feature/*` pipelines.

## Development

### Running Tests

```bash
make test
```

Tests cover all business logic in `Models`, `GitLabService`, `GitHubService`, `KeychainService`, and `PipelineMonitor`. Network calls are intercepted via `MockURLProtocol`. SwiftUI views are not covered by unit tests.

### Project Structure

```
PipelineTracker/           — Main app source
PipelineTrackerTests/      — XCTest unit tests
PipelineTracker.xcodeproj/ — Xcode project
Makefile                   — Build and run shortcuts
```

## License

MIT
