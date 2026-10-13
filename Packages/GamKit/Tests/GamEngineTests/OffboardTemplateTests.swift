import Foundation
@testable import GamEngine
import Testing

/// Offboarding templates: native, since GamGUI has none. A template leaves out only optional steps and fills in
/// the auto-reply, the reminder and its invitee; the plan it leads to is still `Offboarding.steps`, held to GamGUI.
@Suite("Offboarding templates")
struct OffboardTemplateTests {
    private func starter(_ name: String) throws -> Offboarding.Template {
        try #require(Offboarding.starterTemplates.first { $0.name == name }).template
    }

    /// The operator's routine (2026-10-13): change the password, sign out, assign the delegate, transfer the files,
    /// set the auto-reply, then the reminder. Forwarding off comes with the sign-out: it's part of the lock.
    @Test func handOverIsTheOperatorsRoutine() throws {
        let handOver = try starter("Hand-over")
        #expect(handOver.runs == [.password, .revoke, .forward, .delegate, .vacation, .transfer, .reminder])
        #expect(handOver.leftOut == [.calacls])
        #expect(Offboarding.starterDefault == "Hand-over")
    }

    @Test func theOtherStartersAreGamGUIsRoutineAndTheLock() throws {
        #expect(try starter("All eight steps").runs == Offboarding.Step.gamgui)
        #expect(try starter("Lock only").runs == [.password, .revoke, .forward])
        #expect(Offboarding.starterTemplates.map(\.name) == ["Hand-over", "All eight steps", "Lock only"])
        #expect(Offboarding.starterTemplates.allSatisfy { $0.template.added.isEmpty }, "an added step joins a starter once proven live")
        for (name, template) in Offboarding.starterTemplates {
            #expect(template.problem == nil, "\(name)")
            #expect(template.subject == Offboarding.defaultSubject && template.message == Offboarding.defaultMessage)
            #expect(template.days == 30 && template.invitee.isEmpty)
        }
    }

    /// The lock can't be left out by a template either: `Offboarding.steps` would refuse the plan.
    @Test func aTemplateCantLeaveOutTheLock() throws {
        for locked in [Offboarding.Step.password, .revoke, .forward] {
            let template = Offboarding.Template(leftOut: [locked, .calacls])
            #expect(template.problem == "“\(locked.name)” always runs: the reset, the sign-out and forwarding off lock the account.")
            #expect(throws: Offboarding.Invalid.self) {
                try Offboarding.steps(user: "l@example.com", manager: "m@example.com", subject: "s", message: "m", days: 1,
                                      today: Offboarding.Day(iso: "2026-06-23")!, notApplicable: template.leftOut)
            }
        }
        for optional in Offboarding.optionalSteps { #expect(Offboarding.Template(leftOut: [optional]).problem == nil) }
    }

    /// The same rules as the form's (`OffboardChanges.plan`): GamGUI's `looks_like_email` for the invitee.
    @Test func aTemplatesReminderAndInviteeAreTheFormsRules() {
        #expect(Offboarding.Template(days: 0).problem == "The reminder is between 1 and \(36_500.formatted()) days out.")
        #expect(Offboarding.Template(days: 36_501).problem != nil)
        #expect(Offboarding.Template(days: 1).problem == nil && Offboarding.Template(days: 36_500).problem == nil)
        #expect(Offboarding.Template(invitee: "it@example.com").problem == nil)
        #expect(Offboarding.Template(invitee: "  it@example.com\n").problem == nil)
        for bad in ["it", "@example.com", "a@example.com,b@example.com", "it@example.com file"] {
            #expect(Offboarding.Template(invitee: bad).problem?.hasPrefix("The invitee") == true, "\(bad)")
        }
    }
}
