import FoundationModels

/// The on-device model spike (`SWIFTGAMGUI_SPIKE=model`, debug builds): is the model there, and in how
/// many languages. Its own file: code that talks to a model stays apart from anything that can run gam
/// (invariant 10, `WriteRouteTests`).
enum ModelSpike {
    static func run() {
        #if DEBUG
        let model = SystemLanguageModel.default
        print("SystemLanguageModel.default.availability: \(model.availability)")
        print("supported languages: \(model.supportedLanguages.count)")
        #endif
    }
}
