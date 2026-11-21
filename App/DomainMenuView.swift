import Setup
import SwiftUI
import Vault

/// The domain menu (plan F6, GamGUI's #173): with another domain in the Keychain, the toolbar names the active one, and its
/// panel switches to another from any screen. A switch is Setup's own Check access (`SetupModel.checkAccess`): it switches
/// only on a pass, says first what it would stop, and answers in words when it doesn't switch. One per window; the menu bar's
/// Domain menu reaches the window in front (`DomainCommands`).
@MainActor
@Observable
final class DomainSwitcher {
    /// The panel is open.
    var isOpen = false
    /// What the last switch asked from here says, when it didn't switch; nil otherwise.
    private(set) var answer: DomainMenu.Answer?
    private let setup: SetupModel

    init(setup: SetupModel) {
        self.setup = setup
    }

    func open() {
        answer = nil
        isOpen = true
    }

    /// Checks `domain`'s access, as Setup does, and makes it active on a pass. The panel shows how it goes.
    func choose(_ domain: Domain, announce: @escaping (String) -> Void) {
        ask(domain, typedAdmin: "", agreedToStop: [], announce: announce)
    }

    /// Switch Anyway: the same check, agreeing to stop exactly the runs the warning named.
    func switchAnyway(_ warning: SetupModel.SwitchWarning, announce: @escaping (String) -> Void) {
        ask(warning.domain, typedAdmin: warning.typedAdmin, agreedToStop: warning.runIDs, announce: announce)
    }

    private func ask(_ domain: Domain, typedAdmin: String, agreedToStop: Set<UUID>, announce: @escaping (String) -> Void) {
        isOpen = true
        answer = nil
        let setup = setup
        Task {
            let from = setup.active
            let outcome = await setup.checkAccess(domain, typedAdmin: typedAdmin, agreedToStop: agreedToStop)
            answer = DomainMenu.answer(outcome, switchingTo: domain, from: from)
            switch outcome {
            case .connected:
                isOpen = false
                announce("Switched to \(domain.name).")
            case .warned:
                if let warning = setup.switchWarning { announce(warning.headline + " Switch anyway, or cancel.") }
            default:
                if let answer { announce(answer.text) }
            }
        }
    }
}

/// What the menu bar's Domain menu does in the window in front.
struct DomainMenuActions {
    let open: () -> Void
    let choose: (Domain) -> Void
    let openSetup: () -> Void
}

extension FocusedValues {
    @Entry var domainMenu: DomainMenuActions?
}

/// The toolbar's button: the active domain, named "Domain, <domain>" for VoiceOver with whom it signs in as, opening the panel.
/// Shown only while another domain is stored; disabled while Setup is checking or changing a domain.
struct DomainButton: View {
    let setup: SetupModel
    @Bindable var switcher: DomainSwitcher
    let openSetup: () -> Void
    let announce: (String) -> Void

    var body: some View {
        if let active = setup.active, !DomainMenu.others(setup).isEmpty {
            let admin = setup.connectedAdmin
            Button {
                if switcher.isOpen { switcher.isOpen = false } else { switcher.open() }
            } label: {
                Label {
                    Text(active.name).lineLimit(1).truncationMode(.middle).frame(maxWidth: 180)
                } icon: {
                    Image(systemName: "building.2")
                }
                .labelStyle(.titleAndIcon)
            }
            .disabled(setup.isBusy || setup.reconnecting != nil)
            .help("\(active.name) is active\(admin.map { ", signed in as \($0)" } ?? ""). Switch to another domain here (⇧⌘D).")
            .accessibilityLabel("Domain, \(active.name)")
            .accessibilityHint(admin.map { "Signed in as \($0)" } ?? "")
            .popover(isPresented: $switcher.isOpen, arrowEdge: .bottom) {
                DomainPanel(setup: setup, switcher: switcher, openSetup: {
                    switcher.isOpen = false
                    openSetup()
                }, announce: announce)
                .frame(width: 360)
            }
        }
    }
}

/// The panel: what's active, the other domains, and what a switch says (checking, what it would stop, why it didn't).
struct DomainPanel: View {
    let setup: SetupModel
    let switcher: DomainSwitcher
    let openSetup: () -> Void
    let announce: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch Domain").font(.headline).accessibilityAddTraits(.isHeader)
            if let active = setup.active {
                Text("\(active.name) is active\(setup.connectedAdmin.map { ", signed in as \($0)" } ?? ""). Switching checks the "
                     + "domain's access the way Setup does, and switches only if it passes.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            let others = DomainMenu.others(setup)
            if !others.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(others, id: \.self) { domain in
                        Button { switcher.choose(domain, announce: announce) } label: {
                            Label(domain.name, systemImage: "arrow.right.circle").frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.borderless)
                        .disabled(setup.isBusy)
                        .accessibilityLabel("Switch to \(domain.name)")
                    }
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Other domains")
            }
            if let checking = setup.checking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking access to \(checking.name)…")
                }
                .accessibilityElement(children: .combine)
            }
            if let warning = setup.switchWarning {
                SwitchWarningView(warning: warning, busy: setup.isBusy,
                                  switchAnyway: { switcher.switchAnyway(warning, announce: announce) },
                                  cancel: { setup.dismissSwitchWarning() })
            }
            if let answer = switcher.answer {
                AnswerView(answer: answer, openSetup: openSetup)
            }
            Divider()
            HStack(alignment: .firstTextBaseline) {
                Text("Setup checks access again or removes a domain.").font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open Setup", action: openSetup)
            }
        }
        .padding()
    }
}

/// Why a switch didn't happen, in GamGUI's words: the line, the check's own summary, and the fix's link or Setup.
private struct AnswerView: View {
    let answer: DomainMenu.Answer
    let openSetup: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(answer.text, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                .fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            if let detail = answer.detail {
                Text(detail).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            }
            if let link = answer.link {
                Link("Authorize in the Google Admin console", destination: link)
            }
            if answer.toSetup {
                Button(answer.link == nil ? "Open Setup" : DomainMenu.toSetupForScopes, action: openSetup)
                    .buttonStyle(.link)
            }
        }
        .font(.callout)
    }
}

/// What making another domain active would stop (GamGUI's `_switch_warning.html`): every run going now, a routine said left
/// half done, then Switch Anyway (for exactly those runs) or Cancel. On the domain menu's panel and on Setup.
struct SwitchWarningView: View {
    let warning: SetupModel.SwitchWarning
    let busy: Bool
    /// Return and Escape answer it: on the panel, not on Setup, where Return belongs to its text fields.
    var shortcuts = true
    let switchAnyway: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(warning.headline, systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
                .fontWeight(.semibold).fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(warning.runs) { run in
                    Text("• " + SetupModel.SwitchWarning.line(run)).fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(SetupModel.SwitchWarning.line(run))
                }
            }
            Text(SetupModel.SwitchWarning.footer).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Switch Anyway", action: switchAnyway)
                    .keyboardShortcut(shortcuts ? .defaultAction : nil)
                    .disabled(busy)
                    .accessibilityHint("Checks \(warning.domain.name)'s access, and switches only if it passes.")
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(shortcuts ? .cancelAction : nil)
            }
        }
        .font(.callout)
    }
}

/// The menu bar's Domain menu: Switch Domain… (⇧⌘D) opens the panel of the window in front; each other domain switches to it
/// there; Setup… opens Setup. Keyboard-reachable without Full Keyboard Access, as the toolbar's button isn't.
struct DomainCommands: Commands {
    let setup: SetupModel
    @FocusedValue(\.domainMenu) private var menu

    var body: some Commands {
        CommandMenu("Domain") {
            let others = DomainMenu.others(setup)
            Button("Switch Domain…") { menu?.open() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(menu == nil || others.isEmpty)
            if !others.isEmpty {
                Divider()
                ForEach(others, id: \.self) { domain in
                    Button("Switch to \(domain.name)") { menu?.choose(domain) }
                        .disabled(menu == nil || setup.isBusy)
                }
            }
            Divider()
            Button("Setup…") { menu?.openSetup() }
                .disabled(menu == nil)
        }
    }
}
