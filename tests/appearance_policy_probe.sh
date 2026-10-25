#!/bin/sh
# Pure policy checks: synthetic process metadata, no live client control.
set -eu
cd "$(dirname "$0")/.."
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
cat > "$scratch/main.swift" <<'SWIFT'
import Foundation

var checks = 0
func check(_ condition: @autoclosure () -> Bool, _ label: String) {
    guard condition() else { fputs("FAIL: \(label)\n", stderr); exit(1) }
    checks += 1
}
func host(_ pid: Int32, _ parent: Int32, _ path: String, _ started: Double = 100) -> AppearanceHost {
    AppearanceHost(pid: pid, parent: parent, executable: path, started: started)
}
func config(_ id: String = "codex-desktop", _ mode: String = "followApp", enabled: Bool = true, master: Bool = true) -> [String: Any] {
    ["master": master, "pets": [["id": id, "mode": mode, "enabled": enabled]]]
}
func launch(_ config: [String: Any], _ hosts: [String: Double] = [:], quit: Double? = nil, boot: Double = 10) -> Bool {
    AppearancePolicy.shouldLaunch(config: config, hosts: hosts, quitAt: quit, bootAt: boot)
}

let rows = [host(1, 0, "/sbin/launchd"), host(2, 1, "/bin/zsh"),
    host(10, 1, "/Applications/Claude.app/Contents/MacOS/Claude"),
    host(20, 1, "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT"),
    host(30, 1, "/Applications/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness"),
    host(40, 2, "/opt/homebrew/bin/claude"), host(50, 2, "/opt/homebrew/bin/codex")]
let found = AppearancePolicy.hosts(rows)
check(Set(found.keys) == Set(AppearancePolicy.ids), "all five clients recognized independently")
for id in AppearancePolicy.ids {
    check(found[id] == 100, "host start for \(id)")
    check(launch(config(id), found), "followApp launches \(id) on host presence")
    check(!launch(config(id)), "followApp does not launch \(id) without host")
}
check(AppearancePolicy.hosts([host(60, 1, "/tmp/Claude"), host(61, 1, "/tmp/ChatGPT"), host(62, 1, "/tmp/DeepSeek Harness")]).isEmpty, "desktop basename alone cannot identify host")
check(AppearancePolicy.hosts([host(63, 1, "/Applications/Other.app/Contents/MacOS/ChatGPT")]).isEmpty, "unrelated app executable cannot identify Codex Desktop")
check(AppearancePolicy.hosts([host(64, 1, "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")]).isEmpty, "embedded Codex path cannot count as TUI")
check(AppearancePolicy.hosts([host(65, 1, "/Applications/Claude.app/Contents/Resources/claude")]).isEmpty, "embedded Claude path cannot count as TUI")
let descendants = rows.prefix(5) + [host(70, 20, "/bin/sh"), host(71, 70, "/opt/homebrew/bin/codex"), host(72, 10, "/opt/homebrew/bin/claude"), host(73, 30, "/opt/homebrew/bin/claude")]
let desktopOnly = AppearancePolicy.hosts(Array(descendants))
check(desktopOnly["codex-tui"] == nil && desktopOnly["claude-tui"] == nil, "desktop ancestors exclude nested CLI even outside bundle path")
check(desktopOnly.count == 3, "excluding embedded CLI retains desktop hosts")
check(AppearancePolicy.hosts([host(74, 1, "/Users/test/.codex/packages/app-server-daemon/releases/test/bin/codex")]).isEmpty, "orphan background Codex daemon is not terminal TUI")
check(AppearancePolicy.hosts([host(75, 1, "/opt/homebrew/bin/claude")]).isEmpty, "orphan CLI has no live terminal parent")
check(AppearancePolicy.hosts([host(76, 1, "/Users/test/.codex/packages/app-server-daemon/releases/test/bin/codex"), host(77, 76, "/opt/homebrew/bin/codex")]).isEmpty, "daemon ancestor cannot count as terminal TUI")
check(AppearancePolicy.hosts([host(78, 1, "/Applications/CrossPet.app/Contents/MacOS/CrossPet"), host(79, 78, "/opt/homebrew/bin/claude")]).isEmpty, "CrossPet helper cannot count as terminal TUI")
let cycle = AppearancePolicy.hosts([host(80, 81, "/opt/homebrew/bin/codex"), host(81, 80, "/bin/sh")])
check(cycle["codex-tui"] == 100, "ancestry cycles terminate safely")
let restarted = AppearancePolicy.hosts([host(90, 2, "/opt/homebrew/bin/codex", 50), host(91, 2, "/opt/homebrew/bin/codex", 200)])
check(restarted["codex-tui"] == 200, "newest surviving instance determines restart time")
let exited = AppearancePolicy.hosts(rows.filter { $0.pid != 20 })
check(exited["codex-desktop"] == nil, "host exit removes Desktop presence")
check(!AppearancePolicy.visible(mode: "followApp", master: true, hostStarted: exited["codex-desktop"]), "host exit hides followApp pet")
check(AppearancePolicy.visible(mode: "followApp", master: true, hostStarted: 1), "old but alive host stays visible without silence timeout")
check(AppearancePolicy.visible(mode: "onWork", master: true, hostStarted: nil), "default onWork preserves visibility after host exit")
check(AppearancePolicy.visible(mode: "always", master: true, hostStarted: nil), "always remains visible without a host")
check(AppearancePolicy.visible(mode: "followApp", master: false, hostStarted: nil), "master off restores legacy visibility")
check(!launch(config("codex-desktop", "onWork"), found), "onWork does not use host watcher to launch")
check(launch(config("codex-desktop", "always")), "always launches without host")
check(!launch(config("codex-desktop", "always"), quit: 120), "manual quit suppresses always in same boot")
check(!launch(config(), ["codex-desktop": 100], quit: 120), "manual quit suppresses existing host")
check(launch(config(), ["codex-desktop": 121], quit: 120), "host restart after quit allows followApp launch")
check(!launch(config(), ["codex-desktop": 120], quit: 120), "equal-time host is not a proven restart")
check(launch(config(), ["codex-desktop": 200], quit: 120, boot: 150), "reboot clears old manual quit suppression")
check(launch(config("codex-desktop", "always"), quit: 120, boot: 150), "reboot allows always again")
check(!launch(config(enabled: false), found), "disabled pet never autolaunches")
check(!launch(config("codex-desktop", "always", enabled: false)), "disabled always pet never autolaunches")
check(!launch(config(master: false), found), "master off disables watcher launch")
check(!launch(config("codex-desktop", "always", master: false)), "master off disables always launch")
check(!launch([:]), "missing configuration preserves onWork default")
check(!launch(["pets": [["id": "codex-desktop"]]], found), "missing mode cannot change legacy autostart")
check(!launch(config("codex-desktop", "invalid"), found), "invalid mode cannot launch")
check(launch(["pets": [["id": "codex-desktop", "mode": "followApp"]]], found), "missing master/enabled defaults remain enabled")
check(launch(config("claude"), ["claude-tui": 100]), "legacy Claude family follows TUI")
check(launch(config("gpt"), ["codex-desktop": 100]), "legacy GPT family follows Desktop")
check(launch(config("deepseek"), ["dsh-desktop": 100]), "legacy DeepSeek family follows Harness")
check(launch(config("single"), ["claude-desktop": 100]), "single pet follows any supported host")
check(!launch(config("unknown"), found), "unknown pet cannot borrow another host")
print("Appearance policy: \(checks) checks passed (synthetic process metadata; not real client lifecycle E2E)")
SWIFT
swiftc app/mac/AppearancePolicy.swift "$scratch/main.swift" -o "$scratch/appearance-policy-probe"
"$scratch/appearance-policy-probe"
