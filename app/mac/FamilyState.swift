import Foundation

/// A source-scoped snapshot contains metadata only; prompts and tool arguments never cross this boundary.
struct FamilyResult: Codable, Equatable {
    let status: String
    let pose: String
    let event: String
    let ts: Double
    var payload: [String: Any] { ["status": status, "pose": pose, "event": event, "ts": ts] }
    var valid: Bool { ts.isFinite && ts > 0 && ["Success", "Error"].contains(status) && ["Stop", "StopFailure", "AfterAgent", "turn/end"].contains(event) }
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

    // JSON encoding avoids ambiguous concatenation when a session ID contains punctuation.
    var key: String {
        let data = try! JSONEncoder().encode([source, client, sessionId])
        return String(decoding: data, as: UTF8.self)
    }

    var terminal: Bool {
        status == "Success" || status == "Offline" || (status == "Idle" && ["Stop", "AfterAgent", "turn/end"].contains(event)) || (status == "Error" && ["Stop", "StopFailure", "AfterAgent", "turn/end"].contains(event))
    }
    func unconfirmed(now: Double, staleAfter: Double) -> Bool {
        !terminal && status != "Idle" && now - observedAt > staleAfter
    }
    var originKey: String { String(decoding: try! JSONEncoder().encode([source, sessionId]), as: UTF8.self) }

    func payload(now: Double, staleAfter: Double) -> [String: Any] {
        var result: [String: Any] = ["pose": pose, "event": event, "ts": ts,
            "status": status, "source": source, "client": client, "sessionId": sessionId,
            "model": model, "stale": status != "Offline" && now - observedAt > staleAfter]
        if let turnId { result["turnId"] = turnId }
        if let lastResult, lastResult.valid, now - lastResult.ts >= 0, now - lastResult.ts < 10 { result["lastResult"] = lastResult.payload }
        if let tool { result["tool"] = tool }
        if let after, let afterTs { result["after"] = after; result["afterTs"] = afterTs }
        if unconfirmed(now: now, staleAfter: staleAfter) {
            result["recordedStatus"] = status
            result["recordedEvent"] = event
            result["status"] = "Unknown"; result["pose"] = "sleeping"; result["event"] = "StateStale"
            result.removeValue(forKey: "after"); result.removeValue(forKey: "afterTs")
        }
        return result
    }
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

/// One instance per pet. Called on the UI thread; producers atomically replace independent session files.
final class FamilyState {
    static let sourceFamilies = ["claude-code": "claude", "codex": "gpt", "deepseek-harness": "deepseek"]
    static let priority = ["Offline": 0, "Idle": 1, "Success": 2, "Thinking": 3,
        "Tool Running": 4, "Error": 5, "Waiting Input": 6, "Waiting Permission": 7]
    let family: String
    /// Five-client mode: only snapshots whose producer proved this client are routed here.
    let client: String?
    let staleAfter: Double
    private(set) var records: [String: FamilySnapshot] = [:]
    /// Valid sessions of this family whose client could not be identified; never guessed into a pet.
    private var unknownRecords: [String: FamilySnapshot] = [:]
    private var knownClients: [String: Set<String>] = [:]
    var unattributed: Set<String> { unattributedKeys(now: Date().timeIntervalSince1970) }
    private func unattributedKeys(now: Double) -> Set<String> {
        Set(unknownRecords.values.filter {
            !$0.terminal && now - $0.observedAt <= staleAfter && (knownClients[$0.originKey]?.count ?? 0) != 1
        }.map(\.key))
    }
    private var closedTurns: [String: [String]] = [:]

    init(family: String, client: String? = nil, staleAfter: Double = 180) {
        self.family = family
        self.client = client
        self.staleAfter = staleAfter
    }

    private func follows(_ next: FamilySnapshot, _ previous: FamilySnapshot) -> Bool {
        guard next != previous, next.ts >= previous.ts else { return false }
        if next.producerId == previous.producerId, let a = next.sequence, let b = previous.sequence { return a > b }
        return next.observedAt >= previous.observedAt && (next.observedAt > previous.observedAt || next.ts > previous.ts)
    }

    @discardableResult
    func ingest(_ data: Data) -> Bool {
        guard let next = try? JSONDecoder().decode(FamilySnapshot.self, from: data),
              next.schema == 1, next.family == family,
              Self.sourceFamilies[next.source] == family,
              ["tui", "desktop", "unknown"].contains(next.client),
              !next.sessionId.isEmpty, Self.priority[next.status] != nil,
              next.ts.isFinite, next.observedAt.isFinite,
              next.ts > 0, next.observedAt > 0 else { return false }
        // Validate before recording diagnostics, including snapshots for the other pet.
        if next.status == "Success", !["Stop", "AfterAgent", "turn/end"].contains(next.event) { return false }
        if next.client != "unknown" { knownClients[next.originKey, default: []].insert(next.client) }
        if next.client == "unknown" {
            if let previous = unknownRecords[next.key] {
                if follows(next, previous) { unknownRecords[next.key] = next }
            } else { unknownRecords[next.key] = next }
        }
        if let client, next.client != client { return false }
        let key = next.key
        if let previous = records[key] {
            guard follows(next, previous) else { return false }
            let sameProducer = next.producerId == previous.producerId
            // Sequence numbers from a restarted producer have no relationship to the old process.
            if !sameProducer { closedTurns[key] = nil }
        }
        if let turn = next.turnId, !turn.isEmpty,
           closedTurns[key]?.contains(turn) == true, next.status != "Offline" { return false }
        records[key] = next
        if let turn = next.turnId, !turn.isEmpty,
           next.status == "Success" || next.status == "Offline" ||
            (next.event == "Stop" && ["Error", "Idle"].contains(next.status)) || next.event == "turn/end" {
            var finished = closedTurns[key] ?? []
            if !finished.contains(turn) { finished.append(turn) }
            closedTurns[key] = Array(finished.suffix(32))
        }
        return true
    }

    /// Only invoke after observing the recorded producer exit, never after a quiet interval.
    @discardableResult
    func markProcessExited(key: String, producerId: String, now: Double = Date().timeIntervalSince1970) -> Bool {
        guard var state = records[key], state.producerId == producerId,
              state.pid != nil, state.status != "Offline" else { return false }
        state.status = "Offline"
        state.pose = "sleeping"
        state.event = "ProcessExit"
        state.ts = now
        state.observedAt = now
        records[key] = state
        return true
    }

    func sessions(now: Double = Date().timeIntervalSince1970) -> [String: [String: Any]] {
        records.mapValues { $0.payload(now: now, staleAfter: staleAfter) }
    }

    func aggregate(now: Double = Date().timeIntervalSince1970) -> FamilyAggregate {
        // Finished animations have the same four-second display lifetime as existing session cards.
        // Keep the recorded result intact, then let ongoing work take priority over an old result.
        func settled(_ snapshot: FamilySnapshot) -> Bool {
            let terminal = snapshot.status == "Success" ||
                (snapshot.status == "Error" && ["Stop", "StopFailure", "AfterAgent", "turn/end"].contains(snapshot.event))
            return terminal && now - snapshot.observedAt >= 4
        }
        func displayStatus(_ snapshot: FamilySnapshot) -> String {
            snapshot.unconfirmed(now: now, staleAfter: staleAfter) ? "Unknown" : settled(snapshot) ? "Idle" : snapshot.status
        }
        let uncertain = records.values.filter { $0.unconfirmed(now: now, staleAfter: staleAfter) }
        let latestUncertain = uncertain.map(\.observedAt).max() ?? 0
        let current = records.values.filter {
            !$0.unconfirmed(now: now, staleAfter: staleAfter) && $0.status != "Offline" &&
                (now - $0.observedAt <= staleAfter || $0.observedAt > latestUncertain)
        }
        // Historical unfinished work cannot beat newer evidence of a completed/current task.
        // If only unfinished stale evidence remains, expose uncertainty rather than invent a result.
        let candidates = !current.isEmpty ? current : !uncertain.isEmpty ? uncertain : Array(records.values)
        let unknown = unattributedKeys(now: now)
        let selected = candidates.max { a, b in
            let ap = Self.priority[displayStatus(a)] ?? 0, bp = Self.priority[displayStatus(b)] ?? 0
            if ap != bp { return ap < bp }
            if a.observedAt != b.observedAt { return a.observedAt < b.observedAt }
            return a.key < b.key
        }
        guard let selected else {
            // No event is not evidence of Offline: only SessionEnd or an observed process exit is.
            var payload: [String: Any] = ["status": "Unknown", "pose": "sleeping", "event": "NoSessions", "ts": 0,
                                        "stale": false, "confidence": "unknown"]
            if !unknown.isEmpty { payload["unattributed"] = unknown.count }
            return FamilyAggregate(status: "Unknown", pose: "sleeping", event: "NoSessions", ts: 0,
                                   stale: false, count: 0, payload: payload)
        }
        var payload = selected.payload(now: now, staleAfter: staleAfter)
        let status = displayStatus(selected)
        let pose = selected.unconfirmed(now: now, staleAfter: staleAfter) ? "sleeping" : settled(selected) ? "idle" : selected.pose
        if settled(selected) {
            payload["recordedStatus"] = selected.status
            payload["status"] = status
            payload["pose"] = pose
            payload["stale"] = false
        }
        if let result = records.values.compactMap({ $0.lastResult }).filter({ $0.valid && now - $0.ts >= 0 && now - $0.ts < 10 }).max(by: { $0.ts < $1.ts }) {
            payload["lastResult"] = result.payload
        }
        payload["confidence"] = payload["stale"] as? Bool == true ? "stale" : "event"
        if !unknown.isEmpty { payload["unattributed"] = unknown.count }
        return FamilyAggregate(status: status, pose: pose, event: selected.unconfirmed(now: now, staleAfter: staleAfter) ? "StateStale" : selected.event,
            ts: selected.ts, stale: payload["stale"] as? Bool ?? false,
            count: records.values.filter { $0.status != "Offline" }.count, payload: payload)
    }
}
