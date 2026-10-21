import Foundation

/// 记录文件（反馈用）：一行一个 JSON，只留最近 200 行（超过 240 行时截回 200）。
/// 桌宠处理记录 events/pet.jsonl、换角色记录 switches.jsonl 都用它；格式见 docs/架构.md「记录」。写不了就算了，不影响桌宠
enum Ledger {
    static func append(_ url: URL, _ line: [String: Any], keep: Int = 200) {
        var row = line
        row["t"] = (Date().timeIntervalSince1970 * 100).rounded() / 100
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data((text + "\n").utf8)); try? h.close()
        } else {
            try? Data((text + "\n").utf8).write(to: url)
        }
        guard let all = try? String(contentsOf: url, encoding: .utf8) else { return }
        let rows = all.split(separator: "\n", omittingEmptySubsequences: true)
        if rows.count > 240 { try? (rows.suffix(keep).joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8) }
    }

    /// 文件最后 n 行（没有文件返回空串）
    static func tail(_ url: URL, _ n: Int) -> String {
        guard let all = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return all.split(separator: "\n", omittingEmptySubsequences: false).suffix(n).joined(separator: "\n")
    }
}
