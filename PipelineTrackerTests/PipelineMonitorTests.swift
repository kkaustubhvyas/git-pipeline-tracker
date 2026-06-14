import XCTest
@testable import PipelineTracker

@MainActor
final class PipelineMonitorTests: XCTestCase {

    private var monitor: PipelineMonitor!

    override func setUp() async throws {
        try await super.setUp()
        monitor = PipelineMonitor()
    }

    override func tearDown() async throws {
        monitor.stopPolling()
        monitor = nil
        try await super.tearDown()
    }

    // MARK: - pollingInterval clamping

    func test_pollingInterval_belowMinimum_clampsTo1() {
        monitor.pollingInterval = 0
        XCTAssertEqual(monitor.pollingInterval, 1)
    }

    func test_pollingInterval_negativeValue_clampsTo1() {
        monitor.pollingInterval = -10
        XCTAssertEqual(monitor.pollingInterval, 1)
    }

    func test_pollingInterval_aboveMaximum_clampsTo3600() {
        monitor.pollingInterval = 9999
        XCTAssertEqual(monitor.pollingInterval, 3600)
    }

    func test_pollingInterval_validValue_unchanged() {
        monitor.pollingInterval = 30
        XCTAssertEqual(monitor.pollingInterval, 30)
    }

    func test_pollingInterval_boundary_1() {
        monitor.pollingInterval = 1
        XCTAssertEqual(monitor.pollingInterval, 1)
    }

    func test_pollingInterval_boundary_3600() {
        monitor.pollingInterval = 3600
        XCTAssertEqual(monitor.pollingInterval, 3600)
    }

    // MARK: - pageSize clamping

    func test_pageSize_belowMinimum_clampsTo5() {
        monitor.pageSize = 0
        XCTAssertEqual(monitor.pageSize, 5)
    }

    func test_pageSize_aboveMaximum_clampsTo100() {
        monitor.pageSize = 999
        XCTAssertEqual(monitor.pageSize, 100)
    }

    func test_pageSize_validValue_unchanged() {
        monitor.pageSize = 20
        XCTAssertEqual(monitor.pageSize, 20)
    }

    // MARK: - sortOrder persistence

    func test_sortOrder_defaultsToTimeStarted() {
        UserDefaults.standard.removeObject(forKey: "sort_order")
        let fresh = PipelineMonitor()
        XCTAssertEqual(fresh.sortOrder, .timeStarted)
        fresh.stopPolling()
    }

    func test_sortOrder_persistsToUserDefaults() {
        monitor.sortOrder = .timeFinished
        XCTAssertEqual(UserDefaults.standard.string(forKey: "sort_order"), "time_finished")
    }

    func test_sortOrder_loadsFromUserDefaults() {
        UserDefaults.standard.set("time_finished", forKey: "sort_order")
        let fresh = PipelineMonitor()
        XCTAssertEqual(fresh.sortOrder, .timeFinished)
        fresh.stopPolling()
        UserDefaults.standard.removeObject(forKey: "sort_order")
    }

    // MARK: - overallStatus

    func test_overallStatus_noAccounts_isNil() {
        monitor.accounts = []
        XCTAssertNil(monitor.overallStatus)
    }

    func test_overallStatus_allSuccess_isSuccess() {
        let account = Account(name: "Test")
        monitor.accounts = [account]
        monitor.pipelines[account.id] = [
            makePipeline(id: 1, status: .success),
            makePipeline(id: 2, status: .success)
        ]
        XCTAssertEqual(monitor.overallStatus, .success)
    }

    func test_overallStatus_oneFailed_isFailed() {
        let account = Account(name: "Test")
        monitor.accounts = [account]
        monitor.pipelines[account.id] = [
            makePipeline(id: 1, status: .success),
            makePipeline(id: 2, status: .failed)
        ]
        XCTAssertEqual(monitor.overallStatus, .failed)
    }

    func test_overallStatus_failedTakesPriorityOverRunning() {
        let account = Account(name: "Test")
        monitor.accounts = [account]
        monitor.pipelines[account.id] = [
            makePipeline(id: 1, status: .running),
            makePipeline(id: 2, status: .failed)
        ]
        XCTAssertEqual(monitor.overallStatus, .failed)
    }

    func test_overallStatus_runningNofailed_isRunning() {
        let account = Account(name: "Test")
        monitor.accounts = [account]
        monitor.pipelines[account.id] = [
            makePipeline(id: 1, status: .success),
            makePipeline(id: 2, status: .running)
        ]
        XCTAssertEqual(monitor.overallStatus, .running)
    }

    func test_overallStatus_pendingNoFailedOrRunning_isPending() {
        let account = Account(name: "Test")
        monitor.accounts = [account]
        monitor.pipelines[account.id] = [makePipeline(id: 1, status: .pending)]
        XCTAssertEqual(monitor.overallStatus, .pending)
    }

    func test_overallStatus_mixedNonSuccess_returnsNil() {
        let account = Account(name: "Test")
        monitor.accounts = [account]
        monitor.pipelines[account.id] = [
            makePipeline(id: 1, status: .skipped),
            makePipeline(id: 2, status: .canceled)
        ]
        XCTAssertNil(monitor.overallStatus)
    }

    // MARK: - runningCount

    func test_runningCount_noAccounts_isZero() {
        monitor.accounts = []
        XCTAssertEqual(monitor.runningCount, 0)
    }

    func test_runningCount_countsActiveStatuses() {
        let a1 = Account(name: "A1"), a2 = Account(name: "A2")
        monitor.accounts = [a1, a2]
        monitor.pipelines[a1.id] = [
            makePipeline(id: 1, status: .running),
            makePipeline(id: 2, status: .pending),
            makePipeline(id: 3, status: .success)
        ]
        monitor.pipelines[a2.id] = [
            makePipeline(id: 4, status: .running),
            makePipeline(id: 5, status: .failed)
        ]
        XCTAssertEqual(monitor.runningCount, 3) // running + pending + running
    }

    func test_runningCount_noActivePipelines_isZero() {
        let account = Account(name: "Test")
        monitor.accounts = [account]
        monitor.pipelines[account.id] = [
            makePipeline(id: 1, status: .success),
            makePipeline(id: 2, status: .failed)
        ]
        XCTAssertEqual(monitor.runningCount, 0)
    }

    // MARK: - hasErrors

    func test_hasErrors_noErrors_isFalse() {
        XCTAssertFalse(monitor.hasErrors)
    }

    func test_hasErrors_withError_isTrue() {
        let account = Account(name: "Test")
        monitor.accounts = [account]
        monitor.accountErrors[account.id] = "Token expired"
        XCTAssertTrue(monitor.hasErrors)
    }

    // MARK: - tokenFor

    func test_tokenFor_missingToken_returnsEmpty() {
        let account = Account(name: "No token")
        XCTAssertEqual(monitor.tokenFor(account), "")
    }

    func test_tokenFor_savedToken_returnsToken() throws {
        let account = Account(name: "Test")
        try KeychainService.shared.saveToken("my-token", for: account.id)
        defer { KeychainService.shared.deleteToken(for: account.id) }
        XCTAssertEqual(monitor.tokenFor(account), "my-token")
    }

    // MARK: - Helpers

    private func makePipeline(id: Int, status: PipelineStatus) -> Pipeline {
        Pipeline(id: id, status: status, ref: "main", sha: "abc",
                 webUrl: "https://example.com", createdAt: Date(), updatedAt: Date())
    }
}
