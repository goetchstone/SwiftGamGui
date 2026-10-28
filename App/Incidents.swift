import Directory
import Foundation
import GamEngine
import Observation
import Stores

/// The incidents kept on this Mac (`IncidentStore`) for Incident's screen, why the store didn't open, and which one is
/// open there. The open incident's ID (an ID only, never its contents) is remembered across launches, so it's open again
/// after the app restarts or is rebuilt.
@MainActor
@Observable
final class Incidents {
    private(set) var store: IncidentStore?
    /// Why the store didn't open (its folder couldn't be read): nothing is saved, so nothing is made over what's there.
    let openProblem: String?
    /// The incident open on Incident.
    var openID: String? {
        didSet { if let defaults { defaults.set(openID, forKey: Self.openKey) } }
    }
    /// The open incident's evidence as last read: each saved read's name, and those that couldn't be read.
    var evidence: (id: String, names: [String], unreadable: [String])?
    /// What each saved read of the open incident read, in a line (its `about.txt` past the first), by its name: for the report.
    var abouts: [String: String] = [:]
    /// The addresses a saved read of the open incident read every account from (`IncidentLogs.sweptAddress`): their sweep is done.
    var swept: Set<String> = []
    /// The same evidence put together (`IncidentLogs.evidence`; nil when no saved read was readable): what a pull just
    /// saved to it is added to, in memory (`add`).
    var together: (id: String, pull: IncidentLogs.Pull?)?
    /// Reading the evidence, or an export picked.
    var loading = false
    /// Which evidence was last read and shown, or is being read: the tenant's connection, the incident and `reload`. Coming
    /// back to Incident with the same reads nothing again (the operator, 2026-10-27).
    var shownKey: String?
    /// Bumped to read the evidence again (a pull or an export was just saved to it).
    var reload = 0
    /// The last problem, in words, shown with the incident.
    var problem: String?
    private let defaults: UserDefaults?
    private static let openKey = "incident.open"

    /// `defaults` nil (the demo) remembers nothing across launches.
    init(root: URL, defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        openID = defaults?.string(forKey: Self.openKey)
        do {
            store = try IncidentStore(root: root)
            openProblem = nil
        } catch {
            openProblem = error.message
        }
    }

    func records(for domain: String) -> [IncidentStore.Record] { store?.records(for: domain) ?? [] }

    /// What a saved read read, in a line: its `about.txt` past the line saying when it was exported.
    nonisolated static func about(_ export: ActivityLogs.Export) -> String {
        export.about.split(whereSeparator: \.isNewline).dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
    func record(_ id: String?) -> IncidentStore.Record? { id.flatMap { id in store?.records.first { $0.id == id } } }

    /// A new incident, saved; the problem in words when it wasn't.
    func create(domain: String, title: String, opened: Date, openedBy: String, reported: String) -> Result<IncidentStore.Record, Failure> {
        guard store != nil else { return .failure(Failure(openProblem ?? "The incidents couldn't be opened.")) }
        do {
            return .success(try store!.create(domain: domain, title: title, opened: opened, openedBy: openedBy, reported: reported))
        } catch {
            return .failure(Failure(error.message))
        }
    }

    /// Saves the details; the problem in words, or nil.
    func save(_ record: IncidentStore.Record) -> String? {
        do {
            try store?.save(record)
            return nil
        } catch {
            return error.message
        }
    }

    /// Adds a note; the problem in words, or nil.
    func addNote(_ text: String, at: Date, to id: String) -> String? {
        do {
            try store?.addNote(text, at: at, to: id)
            return nil
        } catch {
            return error.message
        }
    }

    /// Keeps `warning` (a bare Message-ID) as a warning picked for the email `email` in the incident `id`, or with nil clears
    /// that email's: the problem in words, or nil once saved (Respond's Who it reached).
    func pickWarning(email: String, warning: String?, in id: String) -> String? {
        guard var record = record(id) else { return "That incident isn't kept any more." }
        if let warning {
            let picked = IncidentStore.Warning(email: email, warning: warning)
            guard !record.warnings.contains(picked) else { return nil }
            record.warnings.append(picked)
        } else {
            record.warnings.removeAll { $0.email == email }
        }
        return save(record)
    }

    /// Keeps `phish` (a bare Message-ID) as the email that started the incident `id`, or with nil clears it: the problem in words,
    /// or nil once saved (Investigate's Where it started).
    func pickPhish(_ phish: String?, in id: String) -> String? {
        guard var record = record(id) else { return "That incident isn't kept any more." }
        guard record.phish != phish else { return nil }
        record.phish = phish
        return save(record)
    }

    /// Marks the to-do item of `kind` saying `words`, on `basis`, done by hand in the incident `id`, as `how` says, now, by
    /// `by`, in place of any tick of it before; or with `how` nil undoes it: the problem in words, or nil once saved (Respond's
    /// Mark Done…).
    func tick(kind: String, words: String, basis: String, how: String?, by: String, in id: String) -> String? {
        guard var record = record(id) else { return "That incident isn't kept any more." }
        record.ticks.removeAll { $0.kind == kind && $0.words == words && $0.basis == basis }
        if let how {
            record.ticks.append(IncidentStore.Tick(kind: kind, words: words, basis: basis, how: how.trimmingCharacters(in: .whitespacesAndNewlines),
                                                   at: Date(), by: by))
        }
        return save(record)
    }

    /// Keeps an export (read with `IncidentStore.readExport`) as the incident's evidence; the problem in words, or nil.
    func keep(_ export: IncidentStore.Export, in id: String) -> String? {
        do {
            try store?.keep(export, in: id)
            return nil
        } catch {
            return error.message
        }
    }

    /// A pull read while the incident `id` is open, saved to its evidence as Export All writes one (only what was read
    /// from Google: what's shown from the evidence is there already), and what to show: the evidence with it added in
    /// memory (`IncidentLogs.adding`), which is what reading every saved read back gives (`IncidentStore.readsBackLast`),
    /// so none is read again (failure log 2026-10-23: each pull re-read and re-parsed every saved one). Off the main actor.
    /// Nil to show the read as it is, the evidence then read back whole (`reload`): it wasn't read yet, or is being read,
    /// or a read-back could differ. Throws when the pull couldn't be saved.
    func add(_ read: IncidentLogs.Pull, to id: String) async throws(Failure) -> IncidentLogs.Pull? {
        guard let store else { throw Failure(openProblem ?? "The incidents couldn't be opened.") }
        let shown = !loading && evidence?.id == id ? evidence : nil, base = together?.id == id ? together : nil
        let saved = await Task.detached { () -> Result<(name: String, about: String, swept: String?, added: (together: IncidentLogs.Pull?, readable: Bool)?), Failure> in
            do {
                let export = try IncidentLogs.exportAll(read, into: try store.evidenceFolder(of: id)).export
                guard let shown, let base,
                      IncidentStore.readsBackLast(export, after: shown.names,
                                                 saved: shown.names.count + shown.unreadable.filter { !shown.names.contains($0) }.count)
                else { return .success((export.name, Self.about(export), IncidentLogs.sweptAddress(about: export.about), nil)) }
                return .success((export.name, Self.about(export), IncidentLogs.sweptAddress(about: export.about), IncidentLogs.adding(export, to: base.pull)))
            } catch let problem as IncidentStore.Problem {
                return .failure(Failure(problem.message))
            } catch {
                return .failure(Failure("Couldn't save the pull to the incident: \(error.localizedDescription)."))
            }
        }.value
        switch saved {
        case .failure(let failure):
            throw failure
        case .success((let name, let about, let swept, let added?)) where evidence?.id == id && evidence?.names == shown?.names:
            evidence = (id, (shown?.names ?? []) + [name], (shown?.unreadable ?? []) + (added.readable ? [] : [name]))
            abouts[name] = about
            if let swept { self.swept.insert(swept) }
            together = (id, added.together)
            return added.together
        case .success:
            reload += 1
            return nil
        }
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
