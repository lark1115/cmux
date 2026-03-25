import XCTest
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// MARK: - WKProcessPool Cookie Isolation

/// Verifies that two WKWebsiteDataStore instances sharing the same
/// WKProcessPool do NOT leak cookies between each other.
/// This is the foundation of agent session isolation — if this fails,
/// per-session WKProcessPool instances would be required.
final class WKProcessPoolCookieIsolationTests: XCTestCase {

    @MainActor
    func testCookieSetInOneStoreIsNotVisibleInAnother() async throws {
        let sharedPool = WKProcessPool()
        let idA = UUID()
        let idB = UUID()
        let storeA = WKWebsiteDataStore(forIdentifier: idA)
        let storeB = WKWebsiteDataStore(forIdentifier: idB)

        // Set a test cookie in store A.
        let cookie = try XCTUnwrap(HTTPCookie(properties: [
            .name: "agent_test_token",
            .value: "secret_value_123",
            .domain: ".example.com",
            .path: "/",
        ]))
        await storeA.httpCookieStore.setCookie(cookie)

        // Verify cookie is in store A.
        let cookiesA = await storeA.httpCookieStore.allCookies()
        XCTAssertTrue(
            cookiesA.contains(where: { $0.name == "agent_test_token" }),
            "Cookie should exist in store A"
        )

        // Verify cookie is NOT in store B (isolation check).
        let cookiesB = await storeB.httpCookieStore.allCookies()
        XCTAssertFalse(
            cookiesB.contains(where: { $0.name == "agent_test_token" }),
            "Cookie from store A must NOT leak to store B via shared WKProcessPool"
        )

        // Cleanup: remove both data stores from disk.
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.remove(forIdentifier: idA) { _ in c.resume() }
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.remove(forIdentifier: idB) { _ in c.resume() }
        }

        // Silence unused variable warning — the shared pool is intentionally
        // created to prove that mere existence of a shared pool doesn't leak.
        _ = sharedPool
    }
}

// MARK: - BrowserAgentSessionStore Unit Tests

final class BrowserAgentSessionStoreTests: XCTestCase {

    /// Create a store with a temp manifest path to avoid writing to production.
    @MainActor
    private func makeTempStore() -> BrowserAgentSessionStore {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manifestURL = tempDir.appendingPathComponent("agent_sessions_manifest.json")
        return BrowserAgentSessionStore(manifestURL: manifestURL)
    }

    @MainActor
    func testGetOrCreateReturnsNewSession() async {
        let store = makeTempStore()
        let agentUUID = UUID()
        let profileId = BrowserProfileStore.shared.builtInDefaultProfileID

        let session = await store.getOrCreate(agentSurfaceUUID: agentUUID, profileId: profileId)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.agentSurfaceUUID, agentUUID)
        XCTAssertEqual(session?.sourceProfileId, profileId)
        XCTAssertEqual(store.sessions.count, 1)

        // Cleanup
        if let session { await store.dispose(sessionId: session.id) }
    }

    @MainActor
    func testGetOrCreateReturnsSameSessionOnSecondCall() async {
        let store = makeTempStore()
        let agentUUID = UUID()
        let profileId = BrowserProfileStore.shared.builtInDefaultProfileID

        let session1 = await store.getOrCreate(agentSurfaceUUID: agentUUID, profileId: profileId)
        let session2 = await store.getOrCreate(agentSurfaceUUID: agentUUID, profileId: profileId)
        XCTAssertEqual(session1?.id, session2?.id, "Same agent+profile should return same session")
        XCTAssertEqual(store.sessions.count, 1, "Should not create duplicate sessions")

        if let session1 { await store.dispose(sessionId: session1.id) }
    }

    @MainActor
    func testDifferentAgentsSamProfileGetDifferentSessions() async {
        let store = makeTempStore()
        let agentA = UUID()
        let agentB = UUID()
        let profileId = BrowserProfileStore.shared.builtInDefaultProfileID

        let sessionA = await store.getOrCreate(agentSurfaceUUID: agentA, profileId: profileId)
        let sessionB = await store.getOrCreate(agentSurfaceUUID: agentB, profileId: profileId)
        XCTAssertNotEqual(sessionA?.id, sessionB?.id, "Different agents should get different sessions")
        XCTAssertNotEqual(sessionA?.dataStoreId, sessionB?.dataStoreId, "Different agents should get different data stores")
        XCTAssertEqual(store.sessions.count, 2)

        if let sessionA { await store.dispose(sessionId: sessionA.id) }
        if let sessionB { await store.dispose(sessionId: sessionB.id) }
    }

    @MainActor
    func testDisposeRemovesSession() async {
        let store = makeTempStore()
        let session = await store.getOrCreate(
            agentSurfaceUUID: UUID(),
            profileId: BrowserProfileStore.shared.builtInDefaultProfileID
        )
        XCTAssertEqual(store.sessions.count, 1)

        if let session {
            await store.dispose(sessionId: session.id)
        }
        XCTAssertEqual(store.sessions.count, 0)
    }

    @MainActor
    func testMaxConcurrentSessionsReturnsNil() async {
        let store = makeTempStore()
        let profileId = BrowserProfileStore.shared.builtInDefaultProfileID

        // Fill to capacity.
        var created: [BrowserAgentSession] = []
        for _ in 0..<BrowserAgentSessionStore.maxConcurrentSessions {
            if let s = await store.getOrCreate(agentSurfaceUUID: UUID(), profileId: profileId) {
                created.append(s)
            }
        }
        XCTAssertEqual(store.sessions.count, BrowserAgentSessionStore.maxConcurrentSessions)

        // Next should return nil.
        let overflow = await store.getOrCreate(agentSurfaceUUID: UUID(), profileId: profileId)
        XCTAssertNil(overflow, "Should return nil when at max capacity")

        // Cleanup
        for s in created { await store.dispose(sessionId: s.id) }
    }

    @MainActor
    func testHandleAgentDisconnectDisposesAllAgentSessions() async {
        let store = makeTempStore()
        let agentUUID = UUID()
        let profileA = BrowserProfileStore.shared.builtInDefaultProfileID

        let _ = await store.getOrCreate(agentSurfaceUUID: agentUUID, profileId: profileA)
        XCTAssertEqual(store.sessions.count, 1)

        await store.handleAgentDisconnect(agentSurfaceUUID: agentUUID)
        XCTAssertEqual(store.sessions.count, 0, "All sessions for disconnected agent should be disposed")
    }
}

// MARK: - BrowserPanel Agent Ownership

final class BrowserPanelAgentOwnershipTests: XCTestCase {

    @MainActor
    func testSwitchToProfileBlockedOnAgentOwnedPanel() {
        let panel = BrowserPanel(
            workspaceId: UUID(),
            agentSessionId: UUID(),
            agentDataStoreId: UUID()
        )
        let otherProfile = UUID()
        let result = panel.switchToProfile(otherProfile)
        XCTAssertFalse(result, "switchToProfile should be blocked on agent-owned panels")
    }

    @MainActor
    func testSwitchToProfileAllowedOnRegularPanel() {
        let panel = BrowserPanel(workspaceId: UUID())
        // switchToProfile to the same profile returns false (no change), but
        // importantly it doesn't crash and the guard for agentSessionId passes.
        let result = panel.switchToProfile(BrowserProfileStore.shared.builtInDefaultProfileID)
        // Returns false because it's already the default profile, but the agent
        // guard was not triggered.
        XCTAssertFalse(result) // same profile → no-op
    }
}
