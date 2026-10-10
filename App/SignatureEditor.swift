import AppKit
import SwiftUI

/// The template's HTML, typed as it is: an `NSTextView` with every substitution off. SwiftUI's
/// `TextEditor` follows the system's smart-quotes setting, and a curly quote typed into a tag breaks the
/// attribute and swallows what follows, `{variables}` included (GamGUI's curly-quote trap). Smart dashes,
/// text replacement, spelling correction and link detection would change the HTML the same way.
struct SignatureEditor: NSViewRepresentable {
    @Binding var text: String
    /// What VoiceOver calls the field.
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.borderType = .bezelBorder
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.allowsUndo = true
        // The body text style's size, monospaced: it follows the Mac's text size like the rest.
        textView.font = .monospacedSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = text
        textView.delegate = context.coordinator
        textView.setAccessibilityLabel(label)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        // By bytes: Swift's `==` takes "é" and "e" + U+0301 as equal, and the template would keep the other.
        if !textView.string.utf8.elementsEqual(text.utf8) {
            textView.string = text
        }
        textView.setAccessibilityLabel(label)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}
