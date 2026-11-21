import Vault

/// Where the executor keeps each signature a step replaces, before it replaces it (`WriteStep.KeepFirst`): Gmail keeps
/// no copy of a replaced signature. Stores' `SignatureBackupStore` is the one the app gives the executor. Only the
/// executor starts a kept run and keeps into it, in the write lock (`WriteRouteTests`): a screen reads what was kept,
/// and puts it back through a preview like any other change.
public protocol SignatureKeeper: Sendable {
    /// A new kept run for `what` (the run's title) on `domain`, made before the run's first step. `restoring` names the kept
    /// runs this one puts back (a Put Back's source, `KeepFirst`'s `restoring`): they outlive it, whatever it keeps. Throws
    /// when there's nowhere to keep the copies: then the run is refused, and nothing is replaced.
    func start(what: String, domain: Domain, restoring: Set<String>) throws -> any KeptSignatureRun
}

/// One run's kept signatures, open while the run goes.
public protocol KeptSignatureRun: AnyObject, Sendable {
    /// The run's id, which the audit's records of its steps name (`kept`) and a Put Back loads.
    var id: String { get }
    /// How many signatures it holds so far.
    var keptCount: Int { get }
    /// `email`'s signature as it was (`previous`, byte for byte) and what the step sets, on disk and flushed before the
    /// step's write. Throws when it can't be: then that write doesn't run, and the run stops.
    func keep(email: String, previous: String, setting: String) throws
    /// The run's end: closed, and removed when it kept nobody. Only a run that kept someone makes room among the kept runs,
    /// so failed attempts don't push real copies out.
    func close()
}
