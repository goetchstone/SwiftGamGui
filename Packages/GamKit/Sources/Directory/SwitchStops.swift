import Foundation
import Jobs
import Setup

/// What a switch to another domain would stop, or hide, for Setup's warning before it checks anything (plan F6,
/// `SetupModel.runningRuns`): every run going in the jobs tray, onboarding's wait for Google between its rounds, and a
/// temporary password on screen not yet handed over.
public enum SwitchStops {
    /// Oldest first, as the tray has them. The wait for Google is one run for its whole length (GamGUI's FinishJob), so a
    /// round of it in the tray isn't named twice; stopped, the new hire is left half set up. A temporary password's details
    /// show on the old domain's person page, which a switch closes: never hidden unwarned.
    @MainActor
    public static func running(jobs: JobBoard, onboarding: OnboardChanges?, users: UserChanges?) -> [SetupModel.RunningRun] {
        let wait = onboarding?.waitForGoogle
        var runs = jobs.runningJobs.filter { $0.preview != wait?.preview }
            .map { SetupModel.RunningRun(id: $0.id, title: $0.title, leftHalfDone: $0.routine) }
        if let wait { runs.append(SetupModel.RunningRun(id: wait.id, title: wait.title, leftHalfDone: true)) }
        if let signIn = users?.signIn {
            runs.append(SetupModel.RunningRun(id: signIn.id, title: passwordLine(signIn.email), leftHalfDone: false))
        }
        return runs
    }

    /// A temporary password's line in the warning.
    public static func passwordLine(_ email: String) -> String {
        "\(email)'s temporary password, not handed over yet: switching closes it before Done"
    }
}
