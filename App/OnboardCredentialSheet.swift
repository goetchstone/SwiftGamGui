import AppKit
import Directory
import GamEngine
import SwiftUI

/// The one-time sign-in card (design doc D4, GamGUI's `_onboard_run.html` credentials): the new account's
/// name, address, temporary password and org unit, how its signature went, and how to sign in. It shows
/// the moment the create ends and is held fifteen minutes or until Done (`OnboardChanges.card`).
struct OnboardCredentialCard: View {
    let card: OnboardChanges.Card
    let changes: OnboardChanges

    var body: some View {
        SignInCard(details: SignInDetails(
            name: card.name, email: card.email, orgUnit: card.orgUnit, password: card.password,
            unsure: card.unsure ? "The create didn't finish in time; the account may exist \u{2014} check Users before handing this out." : nil,
            signature: Self.signatureLine(card.signature), header: "Account created \u{2014} sign-in details"),
            done: changes.doneWithCard)
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

}

/// What a sign-in card shows: a new account's (onboarding) or an existing person's after Set Temporary Password.
struct SignInDetails {
    let name: String
    let email: String
    let orgUnit: String
    let password: TemporaryPassword
    /// Why the password may not be the account's now (the write didn't finish), said first.
    let unsure: String?
    let signature: String?
    let header: String
}

/// The sign-in details with Print, Copy and Done.
///
/// This is the only file that reads the password's text (`TemporaryPassword.shownOnTheSheet`, held to that
/// by `WriteRouteTests.onlyTheCardShowsATemporaryPassword`): the card shows it, Print puts it on paper (or
/// the PDF the print panel can save, the operator's own choice), and Copy puts it on the pasteboard under a
/// concealed type, cleared after two minutes if nothing replaced it. It isn't selectable, and VoiceOver
/// spells it out.
struct SignInCard: View {
    let details: SignInDetails
    let done: () -> Void
    @State private var copied = false

    var body: some View {
        Section {
            if let unsure = details.unsure {
                Label(unsure, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            LabeledContent("Name", value: details.name)
            LabeledContent("Email") { Text(details.email).textSelection(.enabled) }
            LabeledContent("Temporary password") {
                Text(details.password.shownOnTheSheet)
                    .font(.title3.monospaced().weight(.semibold))
                    .speechSpellsOutCharacters()
            }
            if !details.orgUnit.isEmpty {
                LabeledContent("Org unit", value: details.orgUnit)
            }
            if let signature = details.signature {
                LabeledContent("Signature", value: signature)
            }
            Text("Sign in at accounts.google.com \u{2014} Google will require a new password at first login.")
            Text("The temporary password is shown here once: it isn't emailed or written to the audit log. Print or copy it, "
                 + "hand it over, then click Done.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Button("Print\u{2026}") { Self.print(details) }
                    .accessibilityLabel("Print sign-in sheet for \(details.name)")
                Button(copied ? "Copied" : "Copy") {
                    Self.copy(details)
                    copied = true
                }
                .accessibilityLabel("Copy sign-in details for \(details.name)")
                .help("Copies the sign-in details as concealed text, cleared from the clipboard after two minutes.")
                Spacer()
                Button("Done", action: done)
                    .accessibilityLabel("Done with the sign-in details for \(details.name)")
                    .accessibilityHint("Drops the temporary password from this Mac. Print or copy it first.")
            }
        } header: {
            Text(details.header)
        }
    }

    /// The details as GamGUI's Copy and its printable sheet give them.
    private static func text(_ card: SignInDetails) -> String {
        """
        Name: \(card.name)
        Email: \(card.email)
        Temp password: \(card.password.shownOnTheSheet)
        Org unit: \(card.orgUnit)
        Sign in at accounts.google.com \u{2014} Google will require a new password at first login.
        """
    }

    private static func copy(_ card: SignInDetails) {
        let pasteboard = NSPasteboard.general
        // This Mac only: Universal Clipboard would offer it to the operator's other devices, where no clear
        // reaches (security review, 2026-10-13).
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let text = Self.text(card)
        pasteboard.setString(text, forType: .string)
        pasteboard.setString(text, forType: SignInCopy.concealed)
        pasteboard.setString("", forType: SignInCopy.mark)
        let mine = pasteboard.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            // Only what this copy put there: never something the operator copied since.
            if NSPasteboard.general.changeCount == mine { NSPasteboard.general.clearContents() }
        }
    }

    /// The printable sheet, through the system print panel (its Save as PDF is the operator's choice).
    private static func print(_ card: SignInDetails) {
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

/// A sign-in card on the clipboard: marked, so the clear that its two minutes would have made also happens at
/// quit and, after a crash or a force-quit, at the next launch, as long as nothing was copied over it since.
@MainActor
enum SignInCopy {
    /// The nspasteboard.org marker for text a clipboard manager shouldn't keep (§9 Q3).
    static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    /// This app's own marker on a sign-in copy.
    static let mark = NSPasteboard.PasteboardType("io.github.goetchstone.swiftgamgui.signin-card")

    static func clearLeftover() {
        if NSPasteboard.general.types?.contains(mark) == true { NSPasteboard.general.clearContents() }
    }
}
