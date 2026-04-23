import CoreGraphics
import XCTest
@testable import HermitFlow

final class ArchitectureLogicTests: XCTestCase {
    private let dotMatrixAnimationDefaultsKey = "HermitFlow.dotMatrixAnimationEnabled"

    func testVersionCompareHandlesTagsMissingPatchAndPreReleaseSuffixes() {
        XCTAssertEqual(GitHubReleaseUpdateChecker.compareVersions("v1.2.10", "1.2.9"), .orderedDescending)
        XCTAssertEqual(GitHubReleaseUpdateChecker.compareVersions("1.2", "1.2.0"), .orderedSame)
        XCTAssertEqual(GitHubReleaseUpdateChecker.compareVersions("1.2.0-beta", "1.2.1"), .orderedAscending)
    }

    @MainActor
    func testDotMatrixAnimationPreferenceDefaultsPersistsAndRestores() {
        let defaults = UserDefaults.standard
        let originalValue = defaults.object(forKey: dotMatrixAnimationDefaultsKey)
        defaults.removeObject(forKey: dotMatrixAnimationDefaultsKey)
        defer {
            if let originalValue {
                defaults.set(originalValue, forKey: dotMatrixAnimationDefaultsKey)
            } else {
                defaults.removeObject(forKey: dotMatrixAnimationDefaultsKey)
            }
        }

        let defaultStore = PresentationStore()
        XCTAssertFalse(defaultStore.dotMatrixAnimationEnabled)

        defaultStore.setDotMatrixAnimationEnabled(true)
        XCTAssertTrue(defaultStore.dotMatrixAnimationEnabled)
        XCTAssertTrue(defaults.bool(forKey: dotMatrixAnimationDefaultsKey))

        let restoredStore = PresentationStore()
        XCTAssertTrue(restoredStore.dotMatrixAnimationEnabled)
    }

    @MainActor
    func testScreenPlacementCenteredFrameCalculationUsesTopInset() {
        let coordinator = ScreenPlacementCoordinator()

        let frame = coordinator.centeredFrame(
            in: CGRect(x: 100, y: 50, width: 1440, height: 900),
            windowSize: CGSize(width: 360, height: 80),
            topInset: 12
        )

        XCTAssertEqual(frame.origin.x, 640)
        XCTAssertEqual(frame.origin.y, 858)
        XCTAssertEqual(frame.size.width, 360)
        XCTAssertEqual(frame.size.height, 80)
    }

    @MainActor
    func testScreenPlacementTopInsetPreservesCompactCameraHousingRules() {
        let coordinator = ScreenPlacementCoordinator()

        XCTAssertEqual(coordinator.topInset(isExpanded: false, hasCameraHousing: false), 0)
        XCTAssertEqual(coordinator.topInset(isExpanded: false, hasCameraHousing: true), -2)
        XCTAssertEqual(coordinator.topInset(isExpanded: true, hasCameraHousing: false), 0)
        XCTAssertEqual(coordinator.topInset(isExpanded: true, hasCameraHousing: true), -1)
    }

    func testApprovalMergerSelectsNewestRequest() {
        let older = makeApproval(id: "older", createdAt: Date(timeIntervalSince1970: 10), source: .codex)
        let newer = makeApproval(id: "newer", createdAt: Date(timeIntervalSince1970: 20), source: .claude)

        XCTAssertEqual(ApprovalRequestMerger.merge(older, newer)?.id, "newer")
        XCTAssertEqual(ApprovalRequestMerger.merge(newer, nil)?.id, "newer")
        XCTAssertNil(ApprovalRequestMerger.merge(nil, nil))
    }

    func testPollingBackoffPolicyUsesActiveAndIdleIntervals() {
        let policy = PollingBackoffPolicy()
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(policy.activityInterval(isActive: true, lastChangedAt: nil, now: now), 5)
        XCTAssertEqual(policy.activityInterval(isActive: false, lastChangedAt: Date(timeIntervalSince1970: 80), now: now), 5)
        XCTAssertEqual(policy.activityInterval(isActive: false, lastChangedAt: Date(timeIntervalSince1970: 60), now: now), 15)
    }

    func testPollingBackoffPolicyKeepsApprovalResponsiveWhenPending() {
        let policy = PollingBackoffPolicy()
        let now = Date(timeIntervalSince1970: 100)

        XCTAssertEqual(
            policy.approvalInterval(
                isActive: false,
                hasPendingApproval: true,
                lastChangedAt: Date(timeIntervalSince1970: 10),
                now: now
            ),
            5
        )
        XCTAssertEqual(
            policy.approvalInterval(
                isActive: false,
                hasPendingApproval: false,
                lastChangedAt: Date(timeIntervalSince1970: 10),
                now: now
            ),
            15
        )
        XCTAssertEqual(
            policy.approvalInterval(
                isActive: true,
                hasPendingApproval: false,
                lastChangedAt: Date(timeIntervalSince1970: 10),
                now: now
            ),
            15
        )
    }

    func testUsageRefreshPolicyUsesProviderIntervalsAndFailureBackoff() {
        let policy = UsageRefreshPolicy(minimumInterval: 60, failureBackoffInterval: 300)
        let now = Date(timeIntervalSince1970: 1_000)

        XCTAssertTrue(policy.shouldRefresh(lastRefreshAt: nil, backoffUntil: nil, now: now))
        XCTAssertFalse(
            policy.shouldRefresh(
                lastRefreshAt: Date(timeIntervalSince1970: 970),
                backoffUntil: nil,
                now: now
            )
        )
        XCTAssertTrue(
            policy.shouldRefresh(
                lastRefreshAt: Date(timeIntervalSince1970: 900),
                backoffUntil: nil,
                now: now
            )
        )
        XCTAssertFalse(
            policy.shouldRefresh(
                lastRefreshAt: Date(timeIntervalSince1970: 900),
                backoffUntil: Date(timeIntervalSince1970: 1_100),
                force: true,
                now: now
            )
        )
        XCTAssertEqual(
            policy.backoffUntil(snapshotWasMissing: true, now: now),
            Date(timeIntervalSince1970: 1_300)
        )
        XCTAssertNil(policy.backoffUntil(snapshotWasMissing: false, now: now))
    }

    func testFileContentCacheInvalidatesRecentTextWhenFileSizeChanges() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HermitFlowTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: directoryURL)
        }

        let fileURL = directoryURL.appendingPathComponent("history.jsonl")
        try "one\n".write(to: fileURL, atomically: true, encoding: .utf8)

        let cache = FileContentCache()
        XCTAssertEqual(cache.recentText(at: fileURL, maxBytes: 1024), "one\n")

        try "one\ntwo\n".write(to: fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(cache.recentText(at: fileURL, maxBytes: 1024), "one\ntwo\n")
    }

    func testLocalCodexDerivedCacheInvalidatesConversationSummaryWhenSignatureChanges() {
        let cache = LocalCodexDerivedCacheProbe()
        let url = URL(fileURLWithPath: "/tmp/hermitflow-tests/session.jsonl")
        let originalSignature = FileContentSignature(size: 100, modifiedAt: Date(timeIntervalSince1970: 1_000))
        let changedSignature = FileContentSignature(size: 101, modifiedAt: Date(timeIntervalSince1970: 1_000))

        cache.storeConversationSummary("cached title", for: url, signature: originalSignature)

        XCTAssertEqual(cache.cachedConversationSummary(for: url, signature: originalSignature)!, "cached title")
        XCTAssertNil(cache.cachedConversationSummary(for: url, signature: changedSignature))
    }

    func testLocalCodexDerivedCacheExpiresShellSnapshotURLAfterTTL() {
        let cache = LocalCodexDerivedCacheProbe()
        let url = URL(fileURLWithPath: "/tmp/hermitflow-tests/thread.sh")
        let now = Date(timeIntervalSince1970: 1_000)

        cache.storeShellSnapshotURL(url, for: "thread", now: now)

        XCTAssertEqual(cache.cachedShellSnapshotURL(for: "thread", now: now.addingTimeInterval(4))!, url)
        XCTAssertNil(cache.cachedShellSnapshotURL(for: "thread", now: now.addingTimeInterval(6)))
    }

    func testActivityMergerOrdersSessionsAndMergesStatusErrorsApprovalAndUsage() {
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        let codexApproval = makeApproval(id: "codex", createdAt: older, source: .codex)
        let claudeApproval = makeApproval(id: "claude", createdAt: newer, source: .claude)

        let codexSnapshot = ActivitySourceSnapshot(
            sessions: [
                makeSession(id: "codex-idle", origin: .codex, state: .idle, updatedAt: older)
            ],
            statusMessage: "Watching Codex activity",
            lastUpdatedAt: older,
            errorMessage: "Codex error",
            approvalRequest: codexApproval,
            usageSnapshots: [
                ProviderUsageSnapshot(
                    origin: .codex,
                    shortWindowRemaining: 0.2,
                    longWindowRemaining: 0.4,
                    updatedAt: older
                )
            ]
        )
        let claudeSnapshot = ActivitySourceSnapshot(
            sessions: [
                makeSession(id: "claude-running", origin: .claude, state: .running, updatedAt: newer)
            ],
            statusMessage: "Watching Claude activity",
            lastUpdatedAt: newer,
            errorMessage: "Claude error",
            approvalRequest: claudeApproval,
            usageSnapshots: [
                ProviderUsageSnapshot(
                    origin: .codex,
                    shortWindowRemaining: 0.7,
                    longWindowRemaining: 0.8,
                    updatedAt: newer
                ),
                ProviderUsageSnapshot(
                    origin: .claude,
                    shortWindowRemaining: 0.3,
                    longWindowRemaining: 0.6,
                    updatedAt: newer
                )
            ]
        )

        let merged = ActivitySnapshotMerger.merge(codexSnapshot, claudeSnapshot)

        XCTAssertEqual(merged.sessions.map(\.id), ["claude-running", "codex-idle"])
        XCTAssertEqual(merged.statusMessage, "Watching Codex + Claude Code activity")
        XCTAssertEqual(merged.lastUpdatedAt, newer)
        XCTAssertEqual(merged.errorMessage, "Codex error · Claude error")
        XCTAssertEqual(merged.approvalRequest?.id, "claude")
        XCTAssertEqual(Set(merged.usageSnapshots.map(\.origin)), [.codex, .claude])
        XCTAssertEqual(merged.usageSnapshots.first(where: { $0.origin == .codex })?.shortWindowRemaining, 0.7)
    }

    private func makeApproval(id: String, createdAt: Date, source: SessionOrigin) -> ApprovalRequest {
        ApprovalRequest(
            id: id,
            contextTitle: nil,
            commandSummary: "Run command",
            commandText: "echo test",
            rationale: nil,
            focusTarget: nil,
            createdAt: createdAt,
            source: source,
            resolutionKind: .localHTTPHook
        )
    }

    private func makeSession(
        id: String,
        origin: SessionOrigin,
        state: IslandCodexActivityState,
        updatedAt: Date
    ) -> AgentSessionSnapshot {
        AgentSessionSnapshot(
            id: id,
            origin: origin,
            title: id,
            detail: "detail",
            activityState: state,
            runningDetail: nil,
            updatedAt: updatedAt,
            cwd: nil,
            focusTarget: nil,
            freshness: .live
        )
    }
}
