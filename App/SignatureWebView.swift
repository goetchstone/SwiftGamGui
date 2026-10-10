import AppKit
import GamEngine
import SwiftUI
import WebKit

/// A signature drawn as Gmail draws it (design doc D1): a `WKWebView` that runs no script, keeps nothing
/// (a non-persistent data store), loads only HTTPS images (the page shell's policy, `Signature.previewDocument`,
/// and the rule list `Signature.contentRules`, compiled once), and goes nowhere: every navigation but its
/// own `loadHTMLString(_, baseURL: nil)` is cancelled (links, forms, a meta refresh, subframes, a dropped
/// file), a new window is never made, and there's no context menu, link preview or swipe back. GamGUI drew
/// it in a sandboxed `<iframe srcdoc>` under the same policy.
struct SignatureWebView: NSViewRepresentable {
    /// The whole page: `Signature.previewDocument(body)`.
    let document: String
    /// Set when the page couldn't be drawn, so the pane says so instead of showing a blank box.
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator { Coordinator(failed: $failed) }

    func makeNSView(context: Context) -> PreviewWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let view = PreviewWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.uiDelegate = context.coordinator
        view.allowsLinkPreview = false
        view.allowsBackForwardNavigationGestures = false
        view.allowsMagnification = false
        // A file dropped on a web view is loaded in it.
        view.unregisterDraggedTypes()
        context.coordinator.show(document, in: view)
        return view
    }

    func updateNSView(_ view: PreviewWebView, context: Context) {
        context.coordinator.show(document, in: view)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let failed: Binding<Bool>
        /// The page asked for last; a slower rule-list compile never draws an older one over it.
        private var wanted: [UInt8]?
        /// This view's own load, the only navigation allowed: until WebKit asks about it.
        private var expecting = false
        private var load: WKNavigation?
        private var rulesAdded = false

        init(failed: Binding<Bool>) {
            self.failed = failed
        }

        func show(_ document: String, in view: WKWebView) {
            let bytes = Array(document.utf8)
            guard bytes != wanted else { return }
            wanted = bytes
            Task { @MainActor [weak self, weak view] in
                // Nothing is drawn without the rule list: the HTML view still shows the signature.
                guard let rules = await PreviewRules.compiled() else {
                    self?.failed.wrappedValue = true
                    return
                }
                guard let self, let view, self.wanted == bytes else { return }
                if !self.rulesAdded {
                    view.configuration.userContentController.add(rules)
                    self.rulesAdded = true
                }
                self.failed.wrappedValue = false
                self.expecting = true
                self.load = view.loadHTMLString(document, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            let own = expecting && action.targetFrame?.isMainFrame == true
                && (action.request.url.map { $0.absoluteString == "about:blank" } ?? true)
            if own { expecting = false }
            return own ? .allow : .cancel
        }

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            nil
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            if navigation === load { failed.wrappedValue = true }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            if navigation === load { failed.wrappedValue = true }
        }
    }
}

/// No context menu: its Open Link, Download Image and Reload would reach past the policy.
final class PreviewWebView: WKWebView {
    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
    }
}

/// The rule list, compiled once a launch and shared by every preview.
@MainActor
enum PreviewRules {
    private static var compiling: Task<WKContentRuleList?, Never>?

    static func compiled() async -> WKContentRuleList? {
        if let compiling { return await compiling.value }
        let task = Task { @MainActor in
            try? await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "SignaturePreview", encodedContentRuleList: Signature.contentRules)
        }
        compiling = task
        return await task.value
    }
}

/// One signature, as Gmail draws it or as its HTML, with Copy HTML. `html` is what the HTML view shows and
/// Copy copies (in the confirm sheet, the held argv element itself); `rendered` is the body the Rendered
/// view draws (for a new signature, GAM's stored form of it). The HTML view is the drawing's text
/// alternative for VoiceOver.
struct SignaturePane: View {
    let html: String
    let rendered: String
    /// What the pane shows, for VoiceOver and its controls' names: "New signature for Alice Anders".
    let label: String
    /// Said in place of an empty signature.
    var empty = "No signature set."
    var height: CGFloat = 150
    @State private var mode = Mode.rendered
    @State private var failed = false

    enum Mode: String, CaseIterable, Identifiable {
        case rendered = "Rendered", html = "HTML"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .accessibilityLabel("Show the \(label.lowercasedFirst) as")
                Spacer(minLength: 8)
                Button("Copy HTML", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(html, forType: .string)
                    AccessibilityNotification.Announcement("Copied.").post()
                }
                .labelStyle(.titleOnly)
                .disabled(html.isEmpty)
                .accessibilityLabel("Copy the HTML of the \(label.lowercasedFirst)")
            }
            Group {
                if html.isBlank && rendered.isBlank {
                    Text(empty).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                } else if mode == .rendered && !failed {
                    SignatureWebView(document: Signature.previewDocument(rendered), failed: $failed)
                        .accessibilityLabel(label)
                        .accessibilityHint("Drawn as Gmail shows it. Choose HTML to read it as text.")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if failed && mode == .rendered {
                                Label("This couldn't be drawn here; its HTML is below.", systemImage: "exclamationmark.triangle")
                            }
                            Text(verbatim: html)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(8)
                    }
                    .accessibilityLabel("\(label), HTML")
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
            .frame(height: height)
            // A new body is drawn afresh, even after one that couldn't be.
            .onChange(of: rendered) { failed = false }
            .background(.background, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
        }
    }
}

extension String {
    /// "New signature for Alice" → "new signature for Alice", for a control's name built around it.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }

    /// Nothing but white space, for what a screen shows (the model's own checks are Python's strip).
    var isBlank: Bool { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}
