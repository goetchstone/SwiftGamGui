import Foundation
import FoundationModels
import Testing
@testable import Assist

/// The model's failures in words (`OnDeviceModel`, the log explainer's): an answer too long is said so; another error keeps
/// its own description.
@Suite("On-device model words")
struct OnDeviceModelWordsTests {
    @Test func aFailureIsSaidInWords() {
        let tooLong = LanguageModelError.contextSizeExceeded(.init(contextSize: 8192, tokenCount: 8193, debugDescription: "too long"))
        #expect(OnDeviceModel.failure(tooLong) == "its answer ran longer than the model allows. Try again.")
        let other = URLError(.timedOut)
        #expect(OnDeviceModel.failure(other) == other.localizedDescription)
    }
}
