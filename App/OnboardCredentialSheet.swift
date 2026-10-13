import AppKit
import Directory
import GamEngine
import SwiftUI

/// The one-time sign-in card (design doc D4, GamGUI's `_onboard_run.html` credentials): the new account's
/// name, address, temporary password and org unit, how its signature went, and how to sign in. It shows
/// the moment the create ends and is held fifteen minutes or until Done (`OnboardChanges.card`).
///
/// This is the only file that reads the password's text (`TemporaryPassword.shownOnTheSheet`, held to that
/// by `WriteRouteTests.onlyTheCardShowsATemporaryPassword`): the card shows it, Print puts it on paper (or
/// the PDF the print panel can save, the operator's own choice), and Copy puts it on the pasteboard under a
/// concealed type, cleared after two minutes if nothing replaced it. It isn't selectable, and VoiceOver
/// spells it out.
struct OnboardCredentialCard: View {
    let card: OnboardChanges.Card
    let changes: OnboardChanges
    @State private var copied = false

    var body: some View {
        Section {
            if card.unsure {
                Label("The create didn't finish in time; the account may exist \u{2014} check Users before handing this out.",
                      systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            LabeledContent("Name", value: card.name)
            LabeledContent("Email") { Text(card.email).textSelection(.enabled) }
            LabeledContent("Temporary password") {
                Text(card.password.shownOnTheSheet)
                    .font(.title3.monospaced().weight(.semibold))
                    .speechSpellsOutCharacters()
            }
            LabeledContent("Org unit", value: card.orgUnit)
            if let signature = Self.signatureLine(card.signature) {
                LabeledContent("Signature", value: signature)
            }
            Text("Sign in at accounts.google.com \u{2014} Google will require a new password at first login.")
            Text("The temporary password is shown here once: it isn't emailed or written to the audit log. Print or copy it, "
                 + "hand it over, then click Done.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Print\u{2026}") { Self.print(card) }
                    .accessibilityLabel("Print sign-in sheet for \(card.name)")
                Button(copied ? "Copied" : "Copy") {
                    Self.copy(card)
                    copied = true
                }
                .accessibilityLabel("Copy sign-in details for \(card.name)")
                .help("Copies the sign-in details as concealed text, cleared from the clipboard after two minutes.")
                Spacer()
                Button("Done") { changes.doneWithCard() }
                    .accessibilityLabel("Done with the sign-in details for \(card.name)")
                    .accessibilityHint("Drops the temporary password from this Mac. Print or copy it first.")
            }
        } header: {
            Text("Account created \u{2014} sign-in details")
        }
    }

    /// GamGUI's signature line on the card.
    static func signatureLine(_ status: OnboardChanges.Card.SignatureStatus) -> String? {
        switch status {
        case .none: nil
        case .pending(let name): "\u{201C}\(name)\u{201D}: being set"
        case .applied(let name): "\u{201C}\(name)\u{201D} applied"
        case .waiting(let name): "\u{201C}\(name)\u{201D}: waiting for Google \u{2014} applied as soon as the account is ready (below)"
        case .notApplied(let name): "\u{201C}\(name)\u{201D} not applied \u{2014} set it from their page on Users"
        }
    }

    /// The details as GamGUI's Copy and its printable sheet give them.
    private static func details(_ card: OnboardChanges.Card) -> String {
        """
        Name: \(card.name)
        Email: \(card.email)
        Temp password: \(card.password.shownOnTheSheet)
        Org unit: \(card.orgUnit)
        Sign in at accounts.google.com \u{2014} Google will require a new password at first login.
        """
    }

    /// The nspasteboard.org marker for text a clipboard manager shouldn't keep (§9 Q3).
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private static func copy(_ card: OnboardChanges.Card) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealed], owner: nil)
        let text = details(card)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: concealed)
        let mine = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            // Only what this copy put there: never something the operator copied since.
            if NSPasteboard.general.changeCount == mine { NSPasteboard.general.clearContents() }
        }
    }

    /// The printable sheet, through the system print panel (its Save as PDF is the operator's choice).
    private static func print(_ card: OnboardChanges.Card) {
        let page = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 320))
        let body = NSFont.systemFont(ofSize: 13), label = NSFont.boldSystemFont(ofSize: 13)
        let text = NSMutableAttributedString(string: "Sign-in details\n\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 18)])
        for (name, value, font) in [("Name", card.name, body), ("Email", card.email, body),
                                    ("Temporary password", card.password.shownOnTheSheet,
                                     NSFont.monospacedSystemFont(ofSize: 18, weight: .semibold)),
                                    ("Org unit", card.orgUnit, body)] {
            text.append(NSAttributedString(string: "\(name): ", attributes: [.font: label]))
            text.append(NSAttributedString(string: "\(value)\n", attributes: [.font: font]))
        }
        text.append(NSAttributedString(
            string: "\nSign in at accounts.google.com \u{2014} Google will require a new password at first login.\n",
            attributes: [.font: body]))
        page.textStorage?.setAttributedString(text)
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.jobDisposition = .spool
        let operation = NSPrintOperation(view: page, printInfo: info)
        operation.jobTitle = "Sign-in details for \(card.email)"
        if let window = NSApp.keyWindow {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }
}
