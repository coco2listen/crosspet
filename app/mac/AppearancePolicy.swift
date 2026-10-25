import Foundation

/// Only executable paths, parent IDs and uptime; no command arguments or conversation data.
struct AppearanceHost {
    let pid: Int32
    let parent: Int32
    let executable: String
    let started: Double
}

enum AppearancePolicy {
    static let ids = ["claude-tui", "claude-desktop", "codex-tui", "codex-desktop", "dsh-desktop"]
    static let modes = ["onWork", "followApp", "always"]
    static func hosts(_ processes: [AppearanceHost]) -> [String: Double] {
        let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        var found: [String: Double] = [:]
        for process in processes {
            let path = process.executable
            let name = URL(fileURLWithPath: path).lastPathComponent
            var id: String?
            if path.hasSuffix("/Claude.app/Contents/MacOS/Claude") { id = "claude-desktop" }
            if path.hasSuffix("/ChatGPT.app/Contents/MacOS/ChatGPT") { id = "codex-desktop" }
            if path.hasSuffix("/DeepSeek Harness.app/Contents/MacOS/DeepSeek Harness") { id = "dsh-desktop" }
            if (name == "claude" || name == "codex"), process.parent > 1 {
                var cursor: AppearanceHost? = process
                var visited = Set<Int32>()
                var embedded = false
                while let row = cursor, visited.insert(row.pid).inserted {
                    if ["/ChatGPT.app/", "/Claude.app/", "/DeepSeek Harness.app/", "/CrossPet.app/", "/app-server-daemon/"].contains(where: { row.executable.contains($0) }) { embedded = true; break }
                    cursor = byPID[row.parent]
                }
                if !embedded { id = name == "claude" ? "claude-tui" : "codex-tui" }
            }
            if let id { found[id] = max(found[id] ?? 0, process.started) }
        }
        return found
    }
    static func visible(mode: String, master: Bool, hostStarted: Double?) -> Bool {
        guard master else { return true }
        return mode != "followApp" || hostStarted != nil
    }
    static func shouldLaunch(config: [String: Any], hosts: [String: Double], quitAt: Double?, bootAt: Double) -> Bool {
        guard config["master"] as? Bool ?? true else { return false }
        let pets = config["pets"] as? [[String: Any]] ?? []
        return pets.contains { pet in
            guard pet["enabled"] as? Bool ?? true, let id = pet["id"] as? String,
                  let mode = pet["mode"] as? String, mode != "onWork" else { return false }
            let suppressed = quitAt.map { $0 >= bootAt } ?? false
            if mode == "always" { return !suppressed }
            let aliases = id == "claude" ? ["claude-tui", "claude-desktop"] : id == "gpt" ? ["codex-tui", "codex-desktop"] : id == "deepseek" ? ["dsh-desktop"] : id == "single" ? ids : [id]
            guard mode == "followApp", let started = aliases.compactMap({ hosts[$0] }).max() else { return false }
            return !suppressed || started > quitAt!
        }
    }
    static func scan() -> [String: Double]? {
        let task = Process(); let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-A", "-o", "pid=,ppid=,comm="]
        task.standardOutput = pipe; task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
        let rows = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line -> AppearanceHost? in
            let fields = line.split(maxSplits: 2, whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]) else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size else { return nil }
            let started = Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
            return AppearanceHost(pid: pid, parent: parent, executable: fields[2], started: started)
        }
        return hosts(rows)
    }
}
