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
    /// Reading the evidence, or an export picked.
    var loading = false
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

    /// Keeps an export (read with `IncidentStore.readExport`) as the incident's evidence; the problem in words, or nil.
    func keep(_ export: IncidentStore.Export, in id: String) -> String? {
        do {
            try store?.keep(export, in: id)
            return nil
        } catch {
            return error.message
        }
    }

    /// A pull of the logs made while the incident is open, saved to its evidence as Export All writes one, off the main
    /// actor (a whole pull's CSVs are hundreds of thousands of rows; failure log 2026-10-23); the problem in words, or nil.
    func keep(_ pull: IncidentLogs.Pull, in id: String) async -> String? {
        guard let store else { return openProblem }
        return await Task.detached { () -> String? in
            do {
                _ = try IncidentLogs.exportAll(pull, into: try store.evidenceFolder(of: id))
                return nil
            } catch let problem as IncidentStore.Problem {
                return problem.message
            } catch {
                return "Couldn't save the pull to the incident: \(error.localizedDescription)."
            }
        }.value
    }

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }
}
