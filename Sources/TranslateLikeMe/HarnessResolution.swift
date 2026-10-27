import Foundation

// One configuration contract for Settings, readiness probes and actual runs.
// `choice` contains only explicit flags: a catalog default is used to validate
// capabilities and describe the run, never to pin the CLI's default model.
struct HarnessResolution: Equatable {
    enum Source: String {
        case application, configuration, catalog, cli
    }

    let choice: HarnessChoice
    let model: String?
    let modelSource: Source
    let effortSource: Source
    let efforts: [HarnessEffort]?
    let rejectedEffort: String?

    static func current(for provider: Provider) -> HarnessResolution {
        resolve(picked: Settings.harnessPick(for: provider), configured: HarnessDefaults.configured(for: provider),
                catalog: HarnessModels.catalog(for: provider), requiresModelForEffort: provider == .antigravity)
    }

    static func resolve(picked: HarnessChoice, configured: HarnessChoice, catalog: HarnessCatalog,
                        requiresModelForEffort: Bool = false) -> HarnessResolution {
        let flagModel = picked.model ?? configured.model
        let model = flagModel ?? catalog.defaultModel
        let efforts = catalog.efforts(for: model)
        let requested = picked.effort ?? configured.effort
        let incompatible = requested.map { value in efforts.map { !$0.contains { $0.id == value } } ?? false }
            ?? false
        let rejected = incompatible || (requiresModelForEffort && flagModel == nil)
        let effort = rejected ? nil : requested
        let modelSource: Source = picked.model != nil ? .application
            : configured.model != nil ? .configuration : model != nil ? .catalog : .cli
        let effortSource: Source = effort == nil ? .cli : picked.effort != nil ? .application : .configuration
        return HarnessResolution(choice: .init(model: flagModel, effort: effort), model: model,
                                 modelSource: modelSource, effortSource: effortSource, efforts: efforts,
                                 rejectedEffort: rejected ? requested : nil)
    }
}
