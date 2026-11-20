import FoundationModels

/// The on-device model spike (`SWIFTGAMGUI_SPIKE=model`, debug builds): is the model there, in how many languages, how
/// much it can read at once and which model it is. Its own file: code that talks to a model stays apart from anything that
/// can run gam (invariant 10, `WriteRouteTests`).
enum ModelSpike {
    static func run() {
        #if DEBUG
        let model = SystemLanguageModel.default
        print("SystemLanguageModel.default.availability: \(model.availability)")
        print("supported languages: \(model.supportedLanguages.count)")
        print("context size: \(model.contextSize) tokens; variant: \(model.variant.displayName)")
        #endif
    }
}
