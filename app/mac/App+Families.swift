import Cocoa
import WebKit

extension App {
    var owner: App { coordinator ?? self }
    var allControllers: [App] { [owner] + owner.familyPets }
    var allPets: [App] { allControllers.filter { $0.panel != nil } }
    var activePets: [App] { allPets.filter { $0.activeInMode } }
    var menuPet: App { activePets.first ?? owner }

    /// The shared module owns the registry. Adding a client does not require a Swift switch.
    static var petSpecs: [(id: String, family: String, client: String?, title: String)] { ClientPolicyBridge.specs }
    static let familySpecs: [(id: String, family: String, client: String?, title: String)] = [
        ("deepseek", "deepseek", nil, "DeepSeek"), ("gpt", "gpt", nil, "GPT"), ("claude", "claude", nil, "Claude")]
    static var petIds: [String] { petSpecs.map(\.id) }
    /// Default window position: step left from the right edge, one slot per pet.
    static func slot(of id: String?) -> Int {
        (familySpecs + petSpecs).firstIndex { $0.id == id }.map { $0 < familySpecs.count ? $0 : $0 - familySpecs.count } ?? 0
    }

    func setupFamilyPets() {
        if familiesMode { migrateSeen() }
        applyPetMode()
    }

    /// Create controllers lazily by mode; only enabled pets allocate a window.
    func createFamilyWindows() {
        let missing = (Self.familySpecs + Self.petSpecs).filter { spec in
            (petMode == "clients") == (spec.client != nil) && !familyPets.contains { $0.petId == spec.id }
        }
        for spec in missing {
            let pet = App(family: spec.family, client: spec.client, petId: spec.id)
            pet.coordinator = self
            pet.screensAsleep = screensAsleep
            pet.latestRelease = latestRelease
            familyPets.append(pet)
            pet.userHidden = owner.userHidden
        }
    }

    func applyPetMode() {
        if owner !== self { owner.applyPetMode(); return }
        quotaGeneration += 1; codexInFlight = false
        if familiesMode {
            SharedPreferences.migrate(domain: preferenceDomain, shared: appPreferences)
            if owner.characterIds.isEmpty { owner.loadCharacters() }
            createFamilyWindows()
        }
        let flag = root.appendingPathComponent("multi-pets-enabled")
        if familiesMode { try? Data("1".utf8).write(to: flag, options: .atomic) }
        else if FileManager.default.fileExists(atPath: flag.path) { try? FileManager.default.removeItem(at: flag) }
        for pet in allControllers {
            pet.activeInMode = pet.family == nil ? !familiesMode : (pet.client != nil) == (petMode == "clients") && familiesMode && (pet.windowDefaults.object(forKey: "enabled") as? Bool ?? true)
            if pet.activeInMode {
                if pet.panel == nil { pet.createPetWindow() }
                pet.applyHiddenState()
                pet.panel.orderFrontRegardless()
            } else if pet.family == nil || !familiesMode { pet.releasePetWindow() }
            else { pet.panel?.orderOut(nil) }
        }
        refreshAppearance()
        updateSharedResets()
        pushSettings()
    }

    @objc func changePetMode(_ sender: NSMenuItem) {
        appPreferences.set(sender.representedObject as? String ?? "single", forKey: "petMode")
        owner.applyPetMode()
        owner.saveAppearanceConfiguration()
    }

    @objc func togglePetEnabled() {
        guard family != nil else { return }
        windowDefaults.set(!(windowDefaults.object(forKey: "enabled") as? Bool ?? true), forKey: "enabled")
        owner.applyPetMode()
        owner.saveAppearanceConfiguration()
    }

    @objc func toggleClientPet(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, Self.petIds.contains(id),
              let preferences = UserDefaults(suiteName: "\(preferenceDomain).pet.\(id)") else { return }
        preferences.set(!(preferences.object(forKey: "enabled") as? Bool ?? true), forKey: "enabled")
        appPreferences.set("clients", forKey: "petMode")
        owner.applyPetMode()
        owner.saveAppearanceConfiguration()
    }

    @objc func setPetSize(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? Double else { return }
        windowDefaults.set(value, forKey: "size")
        applySizes(animateTo: CGFloat(value)); pushSettings()
    }

    func addFamilyMenu(to menu: NSMenu) {
        let petsItem = NSMenuItem(title: "桌宠", action: nil, keyEquivalent: "")
        let pets = NSMenu()
        for spec in Self.petSpecs {
            let item = owner.add(pets, spec.title, #selector(toggleClientPet(_:)))
            item.representedObject = spec.id
            let preferences = UserDefaults(suiteName: "\(preferenceDomain).pet.\(spec.id)")!
            item.state = (preferences.object(forKey: "enabled") as? Bool ?? true) ? .on : .off
        }
        petsItem.submenu = pets; menu.addItem(petsItem)
        let single = owner.add(menu, "原有单桌宠", #selector(changePetMode(_:)))
        single.representedObject = "single"
        single.state = petMode == "single" ? .on : .off
        let size = NSMenuItem(title: "这只桌宠的大小", action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for value in [0.6, 0.8, 1.0, 1.2, 1.4, 1.6] {
            let item = add(sizes, "\(Int(value * 100))%", #selector(setPetSize(_:)))
            item.representedObject = value
            item.state = abs(Double(petScale) - value) < 0.01 ? .on : .off
        }
        size.submenu = sizes; menu.addItem(size)
        menu.addItem(.separator())
    }

    func appendRenderEvidence(_ row: [String: Any], to path: String) {
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10)
        let url = URL(fileURLWithPath: path)
        if !FileManager.default.fileExists(atPath: path) { try? Data().write(to: url, options: .atomic) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
    }

    func pollClientQuota(_ family: String, _ client: String) {
        if family == "gpt" && !defaults.bool(forKey: "gptQuota") { js("setQuota('gpt', null)"); return }
        if family == "deepseek" && !dsQuotaEnabled { js("setQuota('deepseek', null)"); return }
        let file = stateDir.appendingPathComponent("clients/\(family)-\(client)-quota.json")
        let text = (try? Data(contentsOf: file)).flatMap { data -> String? in
            guard (try? JSONSerialization.jsonObject(with: data)) != nil else { return nil }
            return String(data: data, encoding: .utf8)
        } ?? "null"
        guard text != clientQuotaPayloads[family + client] else { return }
        clientQuotaPayloads[family + client] = text
        js("setClientQuota(\(quote(family)), \(quote(client)), \(text))")
    }

    func pollFamilyStates() {
        guard !pauseRealEvents, let family, let state = familyState else { return }
        let dir = stateDir.appendingPathComponent("families/\(family)", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] where file.pathExtension == "json" {
            guard let stamp = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  let data = try? Data(contentsOf: file) else { continue }
            // Cache validated files even when they belong to the other client or are old/duplicate.
            // Invalid/incomplete writes keep retrying; aggregate deadlines still run every poll.
            _ = state.ingestResult(data)
            _ = stamp // Cache installation is delivered in the renderer optimization PR.

        }
        for (key, record) in state.records {
            if let pid = record.pid, pid > 1, let producer = record.producerId,
               kill(pid, 0) != 0, errno == ESRCH {
                state.markProcessExited(key: key, producerId: producer)
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: state.sessions(), options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8), text != familySessionPayload {
            familySessionPayload = text
            js("setSessions(\(quote(family)), \(text))")
        }
        let aggregate = state.aggregate()

        if let data = try? JSONSerialization.data(withJSONObject: aggregate.payload, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8), text != familyPayload {
            familyPayload = text
            lastPose[family] = (aggregate.pose, Date(timeIntervalSince1970: aggregate.ts))
            if isolatedRun, let trace = ProcessInfo.processInfo.environment["CROSSPET_RENDER_TRACE"], trace.hasPrefix("/") {
                let code = "applyFamilyState(\(quote(family)), \(text)); JSON.stringify({charId, renderedPose:pose, badge:document.getElementById('familyStatus')?.textContent})"
                web.evaluateJavaScript(code) { [weak self] result, error in
                    guard let self else { return }
                    var row = aggregate.payload
                    row["family"] = family; row["pet"] = self.petId ?? family; row["displayAt"] = Date().timeIntervalSince1970
                    if let result = result as? String, let data = result.data(using: .utf8),
                       let view = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        row.merge(view) { _, new in new }
                    }
                    if let error { row["error"] = error.localizedDescription }
                    // Opt-in test evidence contains state metadata only, never client payloads.
                    row.removeValue(forKey: "sessionId")
                    self.appendRenderEvidence(row, to: trace)
                    if aggregate.payload["lastResult"] != nil, ["Offline", "Idle"].contains(aggregate.status) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                            self?.web?.evaluateJavaScript("JSON.stringify({charId,renderedPose:pose,badge:document.getElementById('familyStatus')?.textContent})") { view, _ in
                                guard let self, let view = view as? String, let data = view.data(using: .utf8),
                                      var evidence = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
                                evidence["family"] = family; evidence["kind"] = "result-animation-after-dwell"
                                evidence["displayAt"] = Date().timeIntervalSince1970
                                self.appendRenderEvidence(evidence, to: trace)
                            }
                        }
                    }
                }
            } else { js("applyFamilyState(\(quote(family)), \(text))") }
        }
        // Only client envelopes prove account attribution. Never fill missing data from legacy files.
        if let client {
            if quotaAggregate {
                for spec in Self.petSpecs { if let origin = spec.client { pollClientQuota(spec.family, origin) } }
            } else { pollClientQuota(family, client) }
        }
    }
}
