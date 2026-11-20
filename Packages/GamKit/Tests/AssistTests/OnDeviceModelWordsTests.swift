import Foundation
import FoundationModels
import Testing
@testable import Assist

/// The model's failures in words (`OnDeviceModel`, the log explainer's), each saying what happened and never "Try again"
/// where that can't help; a failed answer's raw text never reaches them; another error keeps its own description.
@Suite("On-device model words")
struct OnDeviceModelWordsTests {
    @Test func aFailureIsSaidInWords() {
        let tooLong = LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 8193, debugDescription: "too long"))
        #expect(OnDeviceModel.failure(tooLong) == "there is more here than the model can read at once. Nothing is lost: the lists are complete without it.")
        let downloading = SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "assets"))
        #expect(OnDeviceModel.failure(downloading) == "the on-device model is still being set up (downloading). Try again in a while.")
        let cut = GeneratedContent.ParsingError(rawContent: "{\"text\": \"carol@example.com was", debugDescription: "cut")
        #expect(OnDeviceModel.failure(cut) == "the model's answer didn't come out whole.")
        #expect(OnDeviceModel.failure(CancellationError()) == "it was stopped.")
        let other = URLError(.timedOut)
        #expect(OnDeviceModel.failure(other) == other.localizedDescription)
    }
}
