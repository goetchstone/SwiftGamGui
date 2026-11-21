import CryptoKit
import Foundation
import Jobs
import Setup

/// What a switch to another domain would stop, or hide, for Setup's warning before it checks anything (plan F6,
/// `SetupModel.runningRuns`): every run going in the jobs tray, onboarding's wait for Google between its rounds, a
/// temporary password on screen not yet handed over, and an audit run going (reads only: a switch stops its GAM at once).
public enum SwitchStops {
    /// Oldest first, as the tray has them. The wait for Google is one run for its whole length (GamGUI's FinishJob), so a
    /// round of it in the tray isn't named twice; stopped, the new hire is left half set up. A temporary password's details
    /// show on the old domain's person page, which a switch closes: never hidden unwarned.
    @MainActor
    public static func running(jobs: JobBoard, onboarding: OnboardChanges?, users: UserChanges?,
                               audits: AuditRunner? = nil) -> [SetupModel.RunningRun] {
        let wait = onboarding?.waitForGoogle
        var runs = jobs.runningJobs.filter { $0.preview != wait?.preview }
            .map { SetupModel.RunningRun(id: $0.id, title: $0.title, leftHalfDone: $0.routine) }
        if let wait { runs.append(SetupModel.RunningRun(id: wait.id, title: wait.title, leftHalfDone: true)) }
        if let signIn = users?.signIn {
            runs.append(SetupModel.RunningRun(id: signIn.id, title: passwordLine(signIn.email), leftHalfDone: false))
        }
        // F3 and F6 met here: a switch stops an audit run's GAM (its step recorded as interrupted), so it's named too.
        for run in AuditRuns.all where audits?.isRunning(run) == true {
            runs.append(SetupModel.RunningRun(id: auditRunID(run), title: auditLine(run), leftHalfDone: false))
        }
        return runs
    }

    /// An audit run's line in the warning: reads only, so stopping it changes nothing.
    public static func auditLine(_ run: AuditRuns.Run) -> String {
        "\(run.title), an audit run: reads only, it stops at once and changes nothing"
    }

    /// The same id for a run of one kind in the warning and in the check after it: the agreement names it by this.
    static func auditRunID(_ run: AuditRuns.Run) -> UUID {
        let digest = Array(SHA256.hash(data: Data("audit-run:\(run.key)".utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    /// A temporary password's line in the warning.
    public static func passwordLine(_ email: String) -> String {
        "\(email)'s temporary password, not handed over yet: switching closes it before Done"
    }
}
