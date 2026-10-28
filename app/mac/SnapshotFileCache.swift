import Foundation

/// Caches only consumed bytes. The caller decides whether an ignored snapshot is valid;
/// this class knows nothing about clients, event ordering or display state.
final class SnapshotFileCache {
    private struct Signature: Equatable {
        let modified: Date
        let size: UInt64
        let inode: UInt64
    }
    private var consumed: [String: Signature] = [:]
    /// Number of Data reads attempted; metadata-only checks are not counted.
    private(set) var readCount = 0

    func read(_ url: URL, consume: (Data) -> Bool) {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let modified = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            consumed.removeValue(forKey: path)
            return
        }
        let signature = Signature(modified: modified, size: size.uint64Value, inode: inode.uint64Value)
        guard consumed[path] != signature else { return }
        // Invalidate the previous success before reading: a rejected replacement must
        // remain retryable even if its writer later restores the old timestamp/size.
        consumed.removeValue(forKey: path)
        readCount += 1
        guard let data = try? Data(contentsOf: url), consume(data) else { return }
        consumed[path] = signature
    }

    /// Called with the paths enumerated this poll; deleted files must not retain signatures.
    func retain(_ paths: Set<String>) {
        consumed = consumed.filter { paths.contains($0.key) }
    }

    /// Invalidate bytes when the consumer's lifetime changes. The diagnostic count is cumulative.
    func reset() {
        consumed.removeAll()
    }
}
