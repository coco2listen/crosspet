import Cocoa
import WebKit

extension App {
    /// One process-wide request and timer, including when both GPT renderers are enabled.
    func updateSharedResets() {
        if owner !== self { owner.updateSharedResets(); return }
        guard familiesMode else {
            resetGeneration += 1; resetTimer?.invalidate(); resetTimer = nil; resetTask?.cancel(); resetTask = nil
            js("setCodexResets(\(codexResets))"); return
        }
        let on = codexResets && activePets.contains { $0.ready }
        for pet in allPets { pet.js("setCodexResets(\(on), true)") }
        if on {
            if resetNextPollAt > Date() {
                deliverSharedResets(raw: resetJSON, ok: resetJSON != nil, wait: max(1, resetNextPollAt.timeIntervalSinceNow) * 1000)
                scheduleSharedResets()
            } else { refreshSharedResets() }
        } else {
            resetGeneration += 1
            resetTimer?.invalidate(); resetTimer = nil
            resetTask?.cancel(); resetTask = nil
        }
    }

    func refreshSharedResets() {
        if owner !== self { owner.refreshSharedResets(); return }
        guard codexResets, activePets.contains(where: { $0.ready }) else { return }
        guard resetTask == nil else { return }
        if let raw = resetJSON, Date().timeIntervalSince(resetFetchedAt) < 20 {
            deliverSharedResets(raw: raw, ok: true, wait: 1800000); scheduleSharedResets(); return
        }
        resetTimer?.invalidate(); resetTimer = nil
        var request = URLRequest(url: URL(string: "https://codex-resets.com/api/v1/status")!)
        request.timeoutInterval = 10; request.cachePolicy = .reloadIgnoringLocalCacheData
        resetGeneration += 1
        let generation = resetGeneration
        resetTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            DispatchQueue.main.async {
                guard let self, self.resetGeneration == generation else { return }
                self.resetTask = nil
                guard self.codexResets else { return }
                let response = response as? HTTPURLResponse
                let ok = response?.statusCode == 200 && data.flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
                let raw = ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
                let wait = response?.statusCode == 429 ? max(1, Double(response?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1800) * 1000 : ok ? 1800000.0 : 600000.0
                if let raw { self.resetJSON = raw; self.resetFetchedAt = Date() }
                self.deliverSharedResets(raw: raw, ok: ok, wait: wait)
                self.resetNextPollAt = Date().addingTimeInterval(wait / 1000)
                self.scheduleSharedResets()
            }
        }
        resetTask?.resume()
    }

    func scheduleSharedResets() {
        resetTimer?.invalidate(); resetTimer = nil
        guard codexResets, activePets.contains(where: { $0.ready }) else { return }
        let delay = max(1, resetNextPollAt.timeIntervalSinceNow)
        resetTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.refreshSharedResets() }
    }

    func deliverSharedResets(raw: String?, ok: Bool, wait: Double) {
        let value = raw ?? "null"
        allPets.forEach { $0.js("sharedResetResult(\(value), \(ok), \(wait))") }
    }
}
