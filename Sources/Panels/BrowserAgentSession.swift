import Foundation

/// Represents one agent's isolated browser session against a specific profile.
///
/// Each `BrowserAgentSession` maps an agent terminal surface to a cloned
/// `WKWebsiteDataStore` derived from a source `BrowserProfileDefinition`.
/// Multiple agents sharing the same imported profile each get their own
/// session with independent cookie state (clone-on-first-use).
///
/// ```
/// Agent -> BrowserAgentSession -> BrowserProfileDefinition -> WKWebsiteDataStore
/// ```
struct BrowserAgentSession: Codable, Identifiable, Sendable {
    /// Unique identifier for this agent session.
    let id: UUID

    /// Internal UUID of the agent's terminal surface that owns this session.
    let agentSurfaceUUID: UUID

    /// The original imported profile this session was cloned from.
    let sourceProfileId: UUID

    /// Agent-specific `WKWebsiteDataStore` identifier (used with
    /// `WKWebsiteDataStore(forIdentifier:)`). Cookies from `sourceProfileId`
    /// are cloned into this store on first use.
    let dataStoreId: UUID

    /// When this session was created.
    let createdAt: Date
}
