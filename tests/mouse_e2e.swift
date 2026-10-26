// Real-mouse E2E: launches an isolated CrossPet, drives the physical cursor with CGEvent, checks window moves,
// per-pet persistence, edge docking and restart restore. Moves the user's real cursor for ~40 s.
// usage: swift tests/mouse_e2e.swift <CrossPet binary> <families|clients> <evidence.json>
import Cocoa

let args = CommandLine.arguments
guard args.count == 4 else { fputs("usage: mouse_e2e.swift <binary> <families|clients> <evidence.json>\n", stderr); exit(2) }
let binary = args[1], mode = args[2], evidencePath = args[3]
let ids = mode == "clients" ? ["claude-tui", "claude-desktop", "codex-tui", "codex-desktop", "dsh-desktop"] : ["claude", "gpt", "deepseek"]
let suite = "io.github.crosspet.test.mouse.\(getpid())"
let scratch = NSTemporaryDirectory() + "crosspet-mouse-\(getpid())"
for sub in ["home", "data", "state"] { try! FileManager.default.createDirectory(atPath: "\(scratch)/\(sub)", withIntermediateDirectories: true) }
FileManager.default.createFile(atPath: "\(scratch)/data/ai-autostart-off", contents: Data())
let screen = NSScreen.screens[0]
let primaryH = screen.frame.height
let size = 0.8, width = 260 * size, height = 362 * size   // refined from the first live window below
var results: [[String: Any]] = []
func check(_ name: String, _ ok: Bool, _ detail: String = "") { results.append(["name": name, "passed": ok, "detail": detail]); print(ok ? "PASS" : "FAIL", name, detail) }

let root = UserDefaults(suiteName: suite)!
root.set(mode, forKey: "petMode")
var seeded: [String: CGPoint] = [:]   // AppKit origin (bottom-left)
for (i, id) in ids.enumerated() {
    let p = UserDefaults(suiteName: "\(suite).pet.\(id)")!
    let origin = CGPoint(x: screen.visibleFrame.minX + 40 + Double(i) * (width + 20), y: screen.visibleFrame.minY + 120)
    p.set(1, forKey: "familySchema"); p.set([origin.x, origin.y], forKey: "origin"); p.set(size, forKey: "size"); p.set(false, forKey: "edgeDock")
    p.set(false, forKey: "hideFullscreen")
    seeded[id] = origin
}
func launch() -> Process {
    let p = Process(); p.executableURL = URL(fileURLWithPath: binary)
    p.environment = ["CFFIXED_USER_HOME": "\(scratch)/home", "CROSSPET_PREFERENCES_SUITE": suite, "CROSSPET_DATA_DIR": "\(scratch)/data", "CROSSPET_STATE_DIR": "\(scratch)/state", "PATH": "/usr/bin:/bin"]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try! p.run(); return p
}
func windows(_ pid: Int32) -> [CGRect] {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 && ($0[kCGWindowAlpha as String] as? Double ?? 1) > 0.5 }
        .compactMap { CGRect(dictionaryRepresentation: $0[kCGWindowBounds as String] as! CFDictionary) }
}
func near(_ a: CGRect, _ b: CGRect, _ tol: Double = 2) -> Bool { abs(a.minX - b.minX) < tol && abs(a.minY - b.minY) < tol && abs(a.width - b.width) < tol }
/// AppKit origin (bottom-left) of a window rectangle given in CG (top-left) coordinates.
func appKitOrigin(_ r: CGRect) -> CGPoint { CGPoint(x: r.minX, y: primaryH - r.maxY) }
func post(_ type: CGEventType, _ p: CGPoint) { CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap) }
func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
func drag(from a: CGPoint, by d: CGVector) {
    post(.mouseMoved, a); pause(0.8)   // the window must see the cursor over the body to stop ignoring the mouse
    post(.leftMouseDown, a); pause(0.15)
    for step in 1...14 { post(.leftMouseDragged, CGPoint(x: a.x + d.dx * Double(step) / 14, y: a.y + d.dy * Double(step) / 14)); pause(0.03) }
    post(.leftMouseUp, CGPoint(x: a.x + d.dx, y: a.y + d.dy)); pause(0.5)
}
func stored(_ id: String) -> [Double]? { UserDefaults(suiteName: "\(suite).pet.\(id)")?.array(forKey: "origin") as? [Double] }

let cursorBefore = CGEvent(source: nil)?.location ?? .zero
var app = launch(); pause(7)
var wins = windows(app.processIdentifier)
check("launch_windows_\(ids.count)", wins.count == ids.count, "\(wins.count) windows")
var rects: [String: CGRect] = [:]   // current CG rectangle of each pet, found by its seeded x
for id in ids {
    let found = wins.first { abs($0.minX - seeded[id]!.x) < 2 && abs($0.width - width) < 2 }
    check("initial_position_\(id)", found != nil)
    rects[id] = found ?? .zero
}
let dx = 37.0, dy = -53.0
for id in ids {
    let rect = rects[id]!
    let body = CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.42)
    let before = windows(app.processIdentifier)
    drag(from: body, by: CGVector(dx: dx, dy: dy))
    let after = windows(app.processIdentifier)
    // The app starts following the cursor after a 3 pt threshold, so allow a few points of slack.
    let moved = after.first { abs($0.minX - (rect.minX + dx)) < 8 && abs($0.minY - (rect.minY + dy)) < 8 && abs($0.width - rect.width) < 2 }
    check("drag_moves_\(id)", moved != nil, "\(String(describing: moved)) vs \(rect)")
    let others = before.filter { !near($0, rect) }
    check("drag_leaves_others_\(id)", others.allSatisfy { o in after.contains { near($0, o) } })
    if let moved {
        rects[id] = moved
        let o = appKitOrigin(moved), s = stored(id)
        check("drag_persisted_\(id)", s != nil && abs(s![0] - o.x) < 2 && abs(s![1] - o.y) < 2, "stored \(String(describing: s)) window \(o)")
    }
}
// Edge dock: drag the first pet to the right edge with docking on.
let first = ids[0]
UserDefaults(suiteName: suite)!.set(true, forKey: "edgeDock")
pause(0.5)
let r0 = rects[first]!
let target = screen.visibleFrame.maxX - width * 0.2 - r0.minX   // centre lands near the edge
drag(from: CGPoint(x: r0.midX, y: r0.minY + r0.height * 0.42), by: CGVector(dx: target, dy: 0))
pause(1.0)
let docked = UserDefaults(suiteName: "\(suite).pet.\(first)")!.string(forKey: "dock")
check("edge_dock_right_\(first)", docked == "right", "dock=\(docked ?? "nil")")
let afterDock = windows(app.processIdentifier)
check("dock_tucks_window_\(first)", afterDock.contains { $0.maxX > screen.frame.maxX - 1 && $0.minX > screen.frame.maxX - width * 0.7 } || docked == "right")
let dockedOrigin = stored(first)

// Restart: positions restore.
app.terminate(); app.waitUntilExit(); pause(1)
app = launch(); pause(7)
wins = windows(app.processIdentifier)
check("restart_windows_\(ids.count)", wins.count == ids.count, "\(wins.count)")
for id in ids.dropFirst() { check("restart_position_\(id)", wins.contains { near($0, rects[id]!, 3) }) }
if let d = dockedOrigin { check("restart_dock_position_\(first)", stored(first)! == d) }
app.terminate(); app.waitUntilExit()
CGWarpMouseCursorPosition(cursorBefore)
for domain in [suite] + ids.map({ "\(suite).pet.\($0)" }) { UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain) }
try? FileManager.default.removeItem(atPath: scratch)
let failed = results.filter { $0["passed"] as? Bool != true }.count
let out: [String: Any] = ["kind": "physical_cursor_CGEvent", "mode": mode, "passed": failed == 0, "assertions": results,
    "limitations": ["Accessibility-trusted CGEvent cursor, not a human", "single display", "no Space/fullscreen switching"]]
try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: evidencePath))
print(failed == 0 ? "ALL PASSED (\(results.count))" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
