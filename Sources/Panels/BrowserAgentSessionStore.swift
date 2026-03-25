#if canImport(WebKit)
import AppKit
import Foundation
import WebKit

// MARK: - Cookie Cloning Extension

extension WKWebsiteDataStore {
    /// Clone all cookies from this store to the destination.
    ///
    /// **Must** be called (and awaited) before any navigation in the
    /// destination's `WKWebView`. The clone completes before the WebView
    /// loads its first URL.
    func cloneCookies(to destination: WKWebsiteDataStore) async {
        let cookies = await self.httpCookieStore.allCookies()
        for cookie in cookies {
            await destination.httpCookieStore.setCookie(cookie)
        }
    }
}

// MARK: - On-Disk Manifest

/// Lightweight JSON manifest persisted to disk so that orphaned
/// `WKWebsiteDataStore` files can be garbage-collected after a crash.
private struct AgentSessionManifest: Codable {
    var dataStoreIds: [UUID]
}

// MARK: - BrowserAgentSessionStore

/// Manages `BrowserAgentSession` instances, providing clone-on-first-use
/// cookie isolation per agent + profile pair.
///
/// Follows the same singleton / `@MainActor` / `ObservableObject` pattern
/// as `BrowserProfileStore`.
@MainActor
final class BrowserAgentSessionStore: ObservableObject {
    static let shared = BrowserAgentSessionStore()

    /// Upper bound on concurrent agent sessions to limit disk usage.
    static let maxConcurrentSessions = 10

    // MARK: Published State

    @Published private(set) var sessions: [BrowserAgentSession] = []

    // MARK: Private State

    /// Per-agent-profile serialization: if a cookie clone is already in
    /// progress for a given `(agentUUID, profileId)` pair, subsequent
    /// callers await the existing `Task` instead of starting a duplicate.
    /// Key format: `"\(agentUUID)-\(profileId)"`.
    private var cloneInFlight: [String: Task<BrowserAgentSession, Never>] = [:]

    /// On-disk manifest of active session `dataStoreId`s for crash-recovery GC.
    /// Located at `~/Library/Application Support/{bundleId}/agent_sessions_manifest.json`.
    let manifestURL: URL

    // MARK: Init

    init() {
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let bundleId = Bundle.main.bundleIdentifier ?? "cmux"
        let container = appSupport.appendingPathComponent(bundleId, isDirectory: true)
        self.manifestURL = container.appendingPathComponent(
            "agent_sessions_manifest.json",
            isDirectory: false
        )
    }

    /// Internal initializer for testing — accepts a custom manifest URL
    /// so tests don't write to the production manifest path.
    init(manifestURL: URL) {
        self.manifestURL = manifestURL
    }

    // MARK: - Get or Create

    /// Return an existing session for the agent + profile pair, or create a
    /// new one with a fresh cookie clone.
    ///
    /// Thread-safe against concurrent calls for the same pair: uses
    /// `cloneInFlight` to deduplicate in-flight clones.
    func getOrCreate(agentSurfaceUUID: UUID, profileId: UUID) async -> BrowserAgentSession? {
        // Fast path: return existing session.
        if let existing = sessions.first(where: {
            $0.agentSurfaceUUID == agentSurfaceUUID && $0.sourceProfileId == profileId
        }) {
            return existing
        }

        // Enforce session limit (include in-flight clones toward the cap).
        guard sessions.count + cloneInFlight.count < Self.maxConcurrentSessions else {
            // If at capacity, still check for a matching in-flight clone.
            let key = "\(agentSurfaceUUID)-\(profileId)"
            if let inFlight = cloneInFlight[key] {
                return await inFlight.value
            }
            // At capacity with no in-flight clone — return nil so callers
            // can report a proper error instead of leaking an untracked store.
            return nil
        }

        let key = "\(agentSurfaceUUID)-\(profileId)"

        // If a clone is already in flight for this pair, await it.
        if let inFlight = cloneInFlight[key] {
            return await inFlight.value
        }

        // Start a new clone task.
        let task = Task<BrowserAgentSession, Never> { @MainActor in
            let session = BrowserAgentSession(
                id: UUID(),
                agentSurfaceUUID: agentSurfaceUUID,
                sourceProfileId: profileId,
                dataStoreId: UUID(),
                createdAt: Date()
            )

            // Clone cookies from the source profile's data store into the
            // new agent-specific store.
            let sourceStore = BrowserProfileStore.shared.websiteDataStore(for: profileId)
            let agentStore = WKWebsiteDataStore(forIdentifier: session.dataStoreId)
            await sourceStore.cloneCookies(to: agentStore)

            // If the session was disposed while cloning, skip appending.
            guard !Task.isCancelled else {
                self.cloneInFlight.removeValue(forKey: key)
                return session
            }

            self.sessions.append(session)
            self.cloneInFlight.removeValue(forKey: key)
            self.persistManifest()

            return session
        }

        cloneInFlight[key] = task
        return await task.value
    }

    // MARK: - Dispose

    /// Dispose a session: remove from the in-memory list and delete the
    /// `WKWebsiteDataStore` from disk.
    ///
    /// Callers are responsible for closing owned `BrowserPanel`s (skipping
    /// the undo stack) before or after calling this method.
    func dispose(sessionId: UUID) async {
        guard let index = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let session = sessions.remove(at: index)

        // Cancel any in-flight clone tasks for this agent.
        let agentUUID = session.agentSurfaceUUID
        for (key, task) in cloneInFlight where key.hasPrefix(agentUUID.uuidString) {
            task.cancel()
            cloneInFlight.removeValue(forKey: key)
        }

        // Remove the cloned data store from disk.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            WKWebsiteDataStore.remove(forIdentifier: session.dataStoreId) { _ in
                continuation.resume()
            }
        }

        persistManifest()
    }

    // MARK: - Queries

    /// All sessions owned by a specific agent terminal surface.
    func sessionsForAgent(_ agentUUID: UUID) -> [BrowserAgentSession] {
        sessions.filter { $0.agentSurfaceUUID == agentUUID }
    }

    /// All sessions cloned from a specific source profile.
    func sessionsForProfile(_ profileId: UUID) -> [BrowserAgentSession] {
        sessions.filter { $0.sourceProfileId == profileId }
    }

    /// Computed tab count for a session.
    ///
    /// Derived by counting live `BrowserPanel` instances whose
    /// `agentSessionId` matches. This avoids storing a stale count.
    ///
    /// Enumerates all windows → tab managers → workspaces → panels
    /// to count `BrowserPanel` instances matching the given session.
    func tabCount(for sessionId: UUID) -> Int {
        guard let app = AppDelegate.shared else { return 0 }
        var count = 0
        let windows = app.listMainWindowSummaries()
        for item in windows {
            guard let tm = app.tabManagerFor(windowId: item.windowId) else { continue }
            for ws in tm.tabs {
                for panel in ws.panels.values {
                    if let browser = panel as? BrowserPanel,
                       browser.agentSessionId == sessionId {
                        count += 1
                    }
                }
            }
        }
        return count
    }

    // MARK: - Agent Disconnect

    /// Called when a socket connection drops (agent crash / exit).
    /// Disposes all sessions owned by the disconnected agent surface.
    func handleAgentDisconnect(agentSurfaceUUID: UUID) async {
        let orphaned = sessionsForAgent(agentSurfaceUUID)

        // Close all BrowserPanels owned by these sessions across all windows
        // before disposing the sessions, so panels don't outlive their data stores.
        if let app = AppDelegate.shared {
            let sessionIds = Set(orphaned.map(\.id))
            let windows = app.listMainWindowSummaries()
            for item in windows {
                guard let tm = app.tabManagerFor(windowId: item.windowId) else { continue }
                for ws in tm.tabs {
                    let ownedPanelIds = ws.panels.values
                        .compactMap { $0 as? BrowserPanel }
                        .filter { $0.agentSessionId != nil && sessionIds.contains($0.agentSessionId!) }
                        .map(\.id)
                    for panelId in ownedPanelIds {
                        ws.closePanel(panelId, force: true)
                    }
                }
            }
        }

        for session in orphaned {
            await dispose(sessionId: session.id)
        }
    }

    // MARK: - Garbage Collection

    /// Called on app launch: remove orphaned `WKWebsiteDataStore` files
    /// left behind by sessions that were not cleanly disposed (e.g. crash).
    ///
    /// Reads the on-disk manifest and removes any data store whose ID is
    /// not referenced by a live session.
    func garbageCollect() async {
        let manifest = loadManifest()
        guard !manifest.dataStoreIds.isEmpty else { return }

        let liveIds = Set(sessions.map(\.dataStoreId))

        for storeId in manifest.dataStoreIds where !liveIds.contains(storeId) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                WKWebsiteDataStore.remove(forIdentifier: storeId) { _ in
                    continuation.resume()
                }
            }
        }

        // Rewrite manifest with only live entries (if any).
        persistManifest()
    }

    // MARK: - Manifest Persistence

    /// Persist the current set of `dataStoreId`s to disk so they can be
    /// cleaned up after a crash.
    private func persistManifest() {
        let manifest = AgentSessionManifest(dataStoreIds: sessions.map(\.dataStoreId))
        do {
            let data = try JSONEncoder().encode(manifest)
            let directory = manifestURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[BrowserAgentSessionStore] Failed to persist manifest: \(error)")
            #endif
        }
    }

    /// Load the on-disk manifest. Returns an empty manifest on any error.
    private func loadManifest() -> AgentSessionManifest {
        guard let data = try? Data(contentsOf: manifestURL),
              let manifest = try? JSONDecoder().decode(AgentSessionManifest.self, from: data) else {
            return AgentSessionManifest(dataStoreIds: [])
        }
        return manifest
    }
}
#endif
