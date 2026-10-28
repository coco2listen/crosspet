import Foundation

/// A source-scoped snapshot contains metadata only; prompts and tool arguments never cross this boundary.
struct FamilyResult: Codable, Equatable {
    let status: String
    let pose: String
    let event: String
    let ts: Double

}

struct FamilySnapshot: Codable, Equatable {
    let schema: Int
    let family: String
    let source: String
    let client: String
    let sessionId: String
    let model: String
    var status: String
    var pose: String
    var event: String
    var ts: Double
    var observedAt: Double
    let turnId: String?
    let eventId: String?
    let sequence: Int64?
    let pid: Int32?
    let producerId: String?
    let tool: String?
    let after: String?
    let afterTs: Double?
    let lastResult: FamilyResult?

}

struct FamilyAggregate {
    let status: String
    let pose: String
    let event: String
    let ts: Double
    let stale: Bool
    let count: Int
    let payload: [String: Any]
}

/// A valid snapshot may only update origin diagnostics or be older than the current state.
/// Such a file is safe to cache until its mtime changes; invalid/incomplete writes must retry.
enum FamilyIngestResult {
    case invalid
    case ignored
    case applied(FamilySnapshot)

    var cacheable: Bool {
        if case .invalid = self { return false }
        return true
    }
    var appliedSnapshot: FamilySnapshot? {
        if case let .applied(snapshot) = self { return snapshot }
        return nil
    }
}


/// A thin JavaScriptCore adapter. No client/status/appearance rules live in Swift.
final class FamilyState {
    let family: String
    let client: String?
    let staleAfter: Double
    private var state: [String: Any] = [:]
    var scope: [String: Any] { ["family": family, "client": client as Any? ?? NSNull(), "staleAfter": staleAfter, "now": Date().timeIntervalSince1970] }
    var records: [String: FamilySnapshot] {
        guard let value = state["records"], let data = try? JSONSerialization.data(withJSONObject: value) else { return [:] }
        return (try? JSONDecoder().decode([String: FamilySnapshot].self, from: data)) ?? [:]
    }
    init(family: String, client: String? = nil, staleAfter: Double = 180) {
        self.family = family; self.client = client; self.staleAfter = staleAfter
    }
    @discardableResult func ingest(_ data: Data) -> Bool { ingestResult(data).appliedSnapshot != nil }
    func ingestResult(_ data: Data) -> FamilyIngestResult {
        guard let snapshot = try? JSONSerialization.jsonObject(with: data),
              let answer = ClientPolicyBridge.call("ingest", [state, snapshot, scope]) as? [String: Any] else { return .invalid }
        if let next = answer["state"] as? [String: Any] { state = next }
        switch answer["result"] as? String {
        case "ignored": return .ignored
        case "applied":
            guard let data = try? JSONSerialization.data(withJSONObject: answer["snapshot"] ?? snapshot),
                  let decoded = try? JSONDecoder().decode(FamilySnapshot.self, from: data) else { return .invalid }
            return .applied(decoded)
        default: return .invalid
        }
    }
    @discardableResult func markProcessExited(key: String, producerId: String, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard let next = ClientPolicyBridge.call("processExited", [state, key, producerId, now]) as? [String: Any] else { return false }
        state = next; return true
    }
    func sessions(now: Double = Date().timeIntervalSince1970) -> [String: [String: Any]] {
        ClientPolicyBridge.call("sessions", [state, now, scope]) as? [String: [String: Any]] ?? [:]
    }
    func aggregate(now: Double = Date().timeIntervalSince1970) -> FamilyAggregate {
        let answer = ClientPolicyBridge.call("aggregate", [state, now, scope]) as? [String: Any] ?? [:]
        return FamilyAggregate(status: answer["status"] as? String ?? "Unknown", pose: answer["pose"] as? String ?? "sleeping",
            event: answer["event"] as? String ?? "NoSessions", ts: answer["ts"] as? Double ?? 0,
            stale: answer["stale"] as? Bool ?? false, count: answer["count"] as? Int ?? 0,
            payload: answer["payload"] as? [String: Any] ?? [:])
    }
}
