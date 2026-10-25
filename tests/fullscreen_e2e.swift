// Real fullscreen/Space E2E. Opens and closes only its uniquely named TextEdit fixture.
// No AppleEvents; Accessibility checks prove each fullscreen transition before testing the pet.
// usage: swift tests/fullscreen_e2e.swift <CrossPet binary> <evidence.json>
import Cocoa

let args = CommandLine.arguments
guard args.count == 3 else { fputs("usage: fullscreen_e2e.swift <binary> <evidence.json>\n", stderr); exit(2) }
let suite = "io.github.crosspet.test.fullscreen.\(getpid())"
let scratch = NSTemporaryDirectory() + "crosspet-fs-\(getpid())"
let fixtureName = "CrossPet-Fullscreen-\(UUID().uuidString).txt"
let fixture = URL(fileURLWithPath: scratch).appendingPathComponent(fixtureName)
let frontBefore = NSWorkspace.shared.frontmostApplication
for sub in ["home", "data", "state"] { try! FileManager.default.createDirectory(atPath: "\(scratch)/\(sub)", withIntermediateDirectories: true) }
FileManager.default.createFile(atPath: "\(scratch)/data/ai-autostart-off", contents: Data())
try! "CrossPet isolated fullscreen test fixture.\n".write(to: fixture, atomically: true, encoding: .utf8)
var results: [[String: Any]] = []
func check(_ name: String, _ ok: Bool, _ detail: String = "") { results.append(["name": name, "passed": ok, "detail": detail]); print(ok ? "PASS" : "FAIL", name, detail) }
func pause(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
func wait(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let until = Date().addingTimeInterval(seconds)
    while Date() < until { if condition() { return true }; pause(0.2) }
    return condition()
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}
func isFullscreen(_ window: AXUIElement) -> Bool? { attribute(window, "AXFullScreen") as? Bool }
func toggleFullscreen() {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: true)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 3, keyDown: false)
    down?.flags = [.maskCommand, .maskControl]; up?.flags = [.maskCommand, .maskControl]
    down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
}
let root = UserDefaults(suiteName: suite)!
root.set("families", forKey: "petMode")
root.set(true, forKey: "hideFullscreen")
for id in ["claude", "gpt", "deepseek"] { UserDefaults(suiteName: "\(suite).pet.\(id)")!.set(true, forKey: "hideFullscreen") }
let pet = UserDefaults(suiteName: "\(suite).pet.claude")!
pet.set(1, forKey: "familySchema"); pet.set([100.0, 150.0], forKey: "origin"); pet.set(0.6, forKey: "size")
let p = Process(); p.executableURL = URL(fileURLWithPath: args[1])
p.environment = ["CFFIXED_USER_HOME": "\(scratch)/home", "CROSSPET_PREFERENCES_SUITE": suite, "CROSSPET_DATA_DIR": "\(scratch)/data", "CROSSPET_STATE_DIR": "\(scratch)/state", "PATH": "/usr/bin:/bin"]
p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
var ownedWindow: AXUIElement?
var textEdit: NSRunningApplication?
/// CrossPet's NSPanel remains alive while hidden; alpha is the observable visibility.
func petAlphas() -> [Double] {
    (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == p.processIdentifier && ($0[kCGWindowLayer as String] as? Int ?? 0) > 0 }
        .compactMap { $0[kCGWindowAlpha as String] as? Double }
}
func petVisible() -> Bool { petAlphas().contains { $0 > 0.5 } }
func fullscreenEvidence() -> String {
    let front = NSWorkspace.shared.frontmostApplication
    let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? [])
        .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == textEdit?.processIdentifier }
        .map { ["bounds": $0[kCGWindowBounds as String] ?? [:], "layer": $0[kCGWindowLayer as String] ?? -1] }
    return "alpha=\(petAlphas()); front=\(front?.bundleIdentifier ?? "nil"); screens=\(NSScreen.screens.map { NSStringFromRect($0.frame) }); textEditWindows=\(windows)"
}
func transition(_ target: Bool, _ name: String) -> Bool {
    guard let window = ownedWindow, let app = textEdit else { return false }
    app.activate(options: [.activateIgnoringOtherApps]); pause(0.3)
    if isFullscreen(window) != target { toggleFullscreen() }
    let changed = wait(10) { isFullscreen(window) == target }
    check(name, changed, "AXFullScreen=\(String(describing: isFullscreen(window)))")
    if changed { pause(2) } // Space animation and CrossPet's foreground polling must settle.
    return changed
}
func runTest() {
    check("accessibility_available", AXIsProcessTrusted())
    guard AXIsProcessTrusted() else { return }
    do { try p.run() } catch { check("crosspet_launch", false, error.localizedDescription); return }
    pause(7)
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first?.activate(options: [.activateIgnoringOtherApps])
    pause(1.5)
    check("pet_visible_at_start", wait(8) { petVisible() }, "\(petAlphas())")
    let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-a", "TextEdit", fixture.path]
    do { try open.run() } catch { check("fixture_open", false, error.localizedDescription); return }
    guard wait(5, { !open.isRunning }) else { open.terminate(); check("fixture_open", false, "open exceeded 5 seconds"); return }
    check("fixture_open", open.terminationStatus == 0)
    guard wait(8, {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first else { return false }
        textEdit = app
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 2)
        let windows = attribute(ax, kAXWindowsAttribute) as? [AXUIElement] ?? []
        ownedWindow = windows.first { (attribute($0, kAXTitleAttribute) as? String)?.contains(fixtureName) == true }
        return ownedWindow != nil
    }) else { check("owned_fixture_window", false, "unique fixture window was not found"); return }
    check("owned_fixture_window", true)
    if let window = ownedWindow { AXUIElementPerformAction(window, kAXRaiseAction as CFString) }
    textEdit?.activate(options: [.activateIgnoringOtherApps]); pause(1)
    check("pet_visible_over_normal_window", petVisible(), "\(petAlphas())")
    guard transition(true, "textedit_entered_fullscreen") else { return }
    let hidden = wait(5) { !petVisible() }
    check("hidden_while_other_app_fullscreen", hidden, fullscreenEvidence())
    guard transition(false, "textedit_exited_fullscreen") else { return }
    check("back_after_exit_fullscreen", wait(5) { petVisible() }, "\(petAlphas())")
    pet.set(false, forKey: "hideFullscreen"); pet.synchronize(); pause(1)
    guard transition(true, "textedit_reentered_fullscreen") else { return }
    check("stays_when_hide_fullscreen_off", petVisible(), "\(petAlphas())")
    _ = transition(false, "textedit_final_exit_fullscreen")
}
runTest()
// Restore the Space before closing only the fixture; never close other documents or quit TextEdit.
if let window = ownedWindow {
    if isFullscreen(window) == true { _ = transition(false, "cleanup_exit_fullscreen") }
    if let close = attribute(window, kAXCloseButtonAttribute) {
        let button = close as! AXUIElement
        check("owned_fixture_closed", AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
    } else { check("owned_fixture_closed", false, "fixture close button unavailable") }
}
if p.isRunning { p.terminate(); _ = wait(5) { !p.isRunning } }
for id in ["", ".pet.claude", ".pet.gpt", ".pet.deepseek"] {
    let domain = suite + id; UserDefaults(suiteName: domain)?.removePersistentDomain(forName: domain)
}
try? FileManager.default.removeItem(atPath: scratch)
frontBefore?.activate(options: [.activateIgnoringOtherApps])
let failed = results.filter { $0["passed"] as? Bool != true }.count
let out: [String: Any] = ["kind": "real_fullscreen_space_TextEdit", "passed": failed == 0, "assertions": results,
    "limitations": ["single display", "TextEdit stands in for a non-AI app", "AI-app fullscreen exception not exercised"]]
try! JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[2]))
print(failed == 0 ? "ALL PASSED (\(results.count))" : "\(failed) FAILED")
exit(failed == 0 ? 0 : 1)
