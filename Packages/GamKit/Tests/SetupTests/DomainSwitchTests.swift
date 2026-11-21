import Foundation
import GamEngine
import Security
@testable import Setup
import Synchronization
import TestSupport
import Testing
import Vault

/// Switching domains from the toolbar's menu (plan F6, GamGUI's #173 `tests/test_domain_menu.py`): it is Setup's own Check
/// access, so it switches only on a pass; it says first what a switch stops, and again after the pass for a run started during
/// the check; one check at a time; and every way it doesn't switch is said in GamGUI's words.
@MainActor
@Suite("Domain switch", .serialized)
struct DomainSwitchTests {
    let store = MemoryStore()
    let base: URL
    let example = Domain("example.com")!
    let other = Domain("example.org")!

    init() throws {
        setenv("GAM_MOCK_FIXTURES", Fixtures.mockGamData.path, 1)
        base = try RuntimeDirectory.prepare(
            FileManager.default.temporaryDirectory.appending(path: "swiftgamgui-run-\(UUID().uuidString)"))
    }

    /// Two domains stored, example.com connected; example.org's token signs in as `otherAdmin` (the mock fails some scopes
    /// for `partialdwd@`).
    private func connected(otherAdmin: String? = "admin@example.org") async throws -> SetupModel {
        let vault = Vault(store: store)
        let runner = AuthenticatedRunner(runner: GamRunner(binary: Fixtures.mockGam), vault: vault, runtimeDirectory: base)
        for (domain, admin) in [(example, "admin@example.com" as String?), (other, otherAdmin)] {
            try store.write(Data(#"{"type": "service_account", "client_email": "gam@p.iam.gserviceaccount.com", "client_id": "123"}"#.utf8),
                            as: .oauth2Service, for: domain)
            try store.write(admin.map { Fixtures.oauth2(admin: $0) } ?? Data(#"{"refresh_token": "placeholder"}"#.utf8),
                            as: .oauth2, for: domain)
        }
        let model = SetupModel(vault: vault, runner: runner, lastDomain: .memory())
        await model.refresh()
        #expect(await model.checkAccess(example) == .connected)
        return model
    }

    private func run(_ title: String, halfDone: Bool = false) -> SetupModel.RunningRun {
        SetupModel.RunningRun(id: UUID(), title: title, leftHalfDone: halfDone)
    }

    @Test func theMenuOffersTheOtherDomainsOnlyWhileOneIsActive() async throws {
        let vault = Vault(store: store)
        let model = SetupModel(vault: vault, runner: nil, lastDomain: .memory())
        try store.write(Data("{}".utf8), as: .oauth2Service, for: example)
        await model.refresh()
        #expect(DomainMenu.others(model).isEmpty, "nothing active: no menu")
        let switched = try await connected()
        #expect(DomainMenu.others(switched) == [other])
        #expect(await switched.checkAccess(other) == .connected)
        #expect(DomainMenu.others(switched) == [example])
    }

    @Test func aPassSwitchesAndAFailedCheckSaysWhyAndKeepsTheActiveDomain() async throws {
        let model = try await connected(otherAdmin: "partialdwd@example.org")
        let outcome = await model.checkAccess(other)
        guard case .failed(let check) = outcome else { Issue.record("\(outcome)"); return }
        #expect(model.active == example && model.generation == 1)
        let answer = try #require(DomainMenu.answer(outcome, switchingTo: other, from: model.active))
        #expect(answer.text == "example.org didn't pass the access check, so example.com stays active.")
        #expect(answer.detail == "Domain-wide delegation isn't authorized for 2 of 7 scopes yet. Use the link, then check again.")
        #expect(answer.link == check.authorizationURL && answer.link?.host() == "admin.google.com" && answer.toSetup)
    }

    /// GamGUI's words for a refusing Keychain, here a refused Touch ID or a locked Mac: nothing changed.
    @Test func aKeychainThatRefusesKeepsTheDomainAndSaysSo() async throws {
        let model = try await connected()
        for status in [errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed] {
            store.failNext(.read, with: status)
            let outcome = await model.checkAccess(other)
            #expect(outcome == .keychainRefused)
            #expect(DomainMenu.answer(outcome, switchingTo: other, from: model.active)?.text
                    == "The Keychain didn't hand over example.org's credentials: it may be locked, or its password prompt was "
                    + "cancelled. Nothing changed. Try again.")
            #expect(model.active == example && model.generation == 1)
        }
    }

    @Test func aDomainWhoseTokenNamesNoAdminIsSentToSetup() async throws {
        let model = try await connected(otherAdmin: nil)
        let outcome = await model.checkAccess(other)
        #expect(outcome == .noAdmin && model.active == example)
        let answer = DomainMenu.answer(outcome, switchingTo: other, from: model.active)
        #expect(answer?.text == "example.org's oauth2.txt names no admin, so switch to it on Setup, where you type its super-admin email.")
        #expect(answer?.toSetup == true)
    }

    /// Before any check: every run going now, a routine said left half done; Switch Anyway goes ahead for exactly those.
    @Test func aSwitchWhileARunGoesSaysFirstWhatItStopsAndChecksNothing() async throws {
        let model = try await connected()
        let offboarding = run("Offboarding carol@example.com", halfDone: true), suspend = run("Suspend user for dana@example.com")
        model.runningRuns = { [offboarding, suspend] }
        let reads = store.readCount
        #expect(await model.checkAccess(other) == .warned)
        #expect(store.readCount == reads, "nothing read: no Touch ID before the operator says go")
        let warning = try #require(model.switchWarning)
        #expect(warning.headline == "Switching to example.org stops what's running on example.com after its current step:")
        #expect(warning.runs.map(SetupModel.SwitchWarning.line) == [
            "Offboarding carol@example.com — stopped part-way, it is left half done: the steps after it won't run",
            "Suspend user for dana@example.com"])
        #expect(model.active == example && !model.isBusy)
        // A run started since the warning: Switch Anyway warns again, naming it too.
        let later = run("Trash message for 9 addresses")
        model.runningRuns = { [offboarding, suspend, later] }
        #expect(await model.checkAccess(other, agreedToStop: warning.runIDs) == .warned)
        #expect(model.switchWarning?.runs.map(\.title) == [offboarding.title, suspend.title, later.title])
        #expect(await model.checkAccess(other, agreedToStop: try #require(model.switchWarning).runIDs) == .connected)
        #expect(model.active == other && model.switchWarning == nil)
    }

    /// GamGUI's review: a run started while the check ran was stopped by the pass. It's asked again after the pass, before
    /// the activation: warned of, not stopped.
    @Test func aRunStartedDuringTheCheckIsWarnedOfNotStopped() async throws {
        let model = try await connected()
        let asked = Mutex(0)
        let started = run("Offboarding carol@example.com", halfDone: true)
        model.runningRuns = { asked.withLock { $0 += 1; return $0 } == 1 ? [] : [started] }
        #expect(await model.checkAccess(other) == .warned)
        #expect(model.active == example && model.generation == 1, "not switched: the run goes on")
        #expect(model.lastCheck?.domain == other && model.lastCheck?.result.isAuthorized == true)
        #expect(model.switchWarning?.runs == [started])
        model.dismissSwitchWarning()
        #expect(model.switchWarning == nil && model.active == example)
    }

    @Test func checkingTheActiveDomainAgainStopsNothing() async throws {
        let model = try await connected()
        model.runningRuns = { [run("Offboarding carol@example.com", halfDone: true)] }
        #expect(await model.checkAccess(example) == .connected)
        #expect(model.switchWarning == nil && model.generation == 1)
    }

    /// Two checks in flight once ended on whichever finished last: a second is refused, naming the domain being checked.
    @Test func aSecondSwitchIsRefusedWhileACheckRuns() async throws {
        let model = try await connected()
        let first = Task { await model.checkAccess(other) }
        while model.checking == nil { await Task.yield() }
        let second = await model.checkAccess(example)
        #expect(second == .busy(checking: other))
        #expect(DomainMenu.answer(second, switchingTo: example, from: model.active)?.text
                == "example.org's access is being checked. Wait for its answer, then try again. Nothing changed.")
        #expect(await first.value == .connected)
        #expect(model.active == other && model.checking == nil)
        #expect(DomainMenu.answer(.busy(checking: nil), switchingTo: other, from: example)?.text
                == "Setup is busy with another action. Wait for it to finish, then try again. Nothing changed.")
    }

    @Test func nothingIsSaidForAPassOrAWarning() {
        #expect(DomainMenu.answer(.connected, switchingTo: other, from: example) == nil)
        #expect(DomainMenu.answer(.warned, switchingTo: other, from: example) == nil)
        #expect(DomainMenu.answer(.cancelled, switchingTo: other, from: example) == nil)
        #expect(DomainMenu.answer(.notRun("GAM didn't answer within 60 seconds."), switchingTo: other, from: example)
                == DomainMenu.Answer(text: "example.org's access check couldn't run, so nothing changed.",
                                     detail: "GAM didn't answer within 60 seconds.", link: nil, toSetup: false))
    }
}
