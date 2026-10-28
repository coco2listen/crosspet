import Cocoa

extension App {
    /// Store once, fan out effects to every live renderer; disabled controllers read the same store on recreation.
    func applySharedSettings(key: String) {
        if owner !== self { owner.applySharedSettings(key: key); return }
        for pet in allControllers {
            switch key {
            case "textSize", "textLinked": pet.applySizes()
            case "hideFullscreen": pet.applyFullscreenBehavior(); pet.checkFullscreen()
            case "layer": pet.applyLayer()
            case "edgeDock": if !pet.edgeDockEnabled { pet.undock() }
            case "dsQuota", "quotaAggregate":
                pet.stamps["deepseek-quota"] = nil
                pet.stamps[stateDir.appendingPathComponent("deepseek-quota.json").path] = nil
                if !pet.dsQuotaEnabled { pet.js("setQuota('deepseek', null)") }
            case "skins", "names":
                if pet.ready { pet.loadCharacters(); if let id = pet.currentId { pet.js("refreshLook(\(pet.quote(id)))") } }
            default: break
            }
            guard pet.ready else { continue }
            switch key {
            case "aura": pet.js("setAuraMode(\(pet.quote(pet.auraMode)))")
            case "showName": pet.js("setShowName(\(pet.showName))")
            case "eggs": pet.js("setEggsEnabled(\(pet.eggsEnabled))")
            case "powerSave": pet.js("setPowerSave(\(pet.powerSave))")
            case "quotaAggregate": pet.js("setQuotaAggregate(\(pet.quotaAggregate))")
            case "quotaStyle": pet.js("setQuotaStyle(\(pet.quote(pet.quotaStyle)))")
            case "peakStyle": pet.js("setPeakStyle(\(pet.quote(pet.peakStyle)))")
            case "peakSkins": pet.js("setPeakSkins(\(pet.peakSkinsJSON))")
            case "gptQuota": if !defaults.bool(forKey: "gptQuota") { pet.js("setCodexQuota(null)") }
            case "agyQuota": if !defaults.bool(forKey: "agyQuota") { pet.js("setQuota('gemini', null)") }
            default: break
            }
        }
        if key == "gptQuota" { refreshCodexQuota(.now) }
        if key == "agyQuota" { refreshAntigravityQuota() }
        if key == "codexResets" { updateSharedResets() }
        pushSettings()
    }
}
