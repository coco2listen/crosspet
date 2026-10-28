import Foundation

struct AppearanceHost {
    let pid: Int32
    let parent: Int32
    let executable: String
    let started: Double
}
/// Only process metadata collection belongs to the shell; classification lives in client-policy.js.
enum AppearancePolicy {
    static let modes = ["onWork", "followApp", "always"]
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
        return ClientPolicyBridge.call("hosts", [rows.map { ["pid": $0.pid, "parent": $0.parent, "executable": $0.executable, "started": $0.started] as [String: Any] }]) as? [String: Double]
    }
}
