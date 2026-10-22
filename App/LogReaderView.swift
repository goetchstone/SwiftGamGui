import Assist
import Directory
import GamEngine
import SwiftUI

/// "Read the logs" (docs/plans/2026-10-19-on-device-log-reader.md): what a pull of the incident logs shows, found by
/// rules in code (`LogReading`), each finding with the fixes it points to, and on request the on-device model's
/// explanation (`LogExplainer`). It changes nothing and reaches no change: a fix only hands an address or a Message-ID
/// to its screen (Incident checks the person; Phishing finds who has the email), and that screen shows its
/// own preview, confirmed there. Its own file, apart from anything that can run gam (invariant 10, `WriteRouteTests`).
struct LogReaderView: View {
    let pull: IncidentLogs.Pull
    /// Opens Incident for a person and checks them.
    let secure: (String) -> Void
    /// Opens Phishing with a Message-ID and finds who has the email.
    let pullEmail: (String) -> Void
    @State private var knowsLockTime = false
    @State private var lockedAt = Date.now
    @State private var explained: (reading: LogReading.Reading, state: Explaining)?
    /// The pull's rows as the reader sees them, made once per pull rather than on every redraw.
    @State private var cached: (key: String, events: [LogReading.Event])?

    /// What identifies the pull read: its query and each log's outcome.
    private var key: String {
        "\(pull.query)|" + pull.logs.map { "\($0.application.rawValue):\((try? $0.rows.get().count).map(String.init) ?? "failed")" }
            .joined(separator: ",")
    }

    enum Explaining {
        case asking
        case done(LogExplainer.Explanation)
        case failed(String)
    }

    private var reading: LogReading.Reading {
        let events = cached.flatMap { $0.key == key ? $0.events : nil } ?? Self.events(pull)
        return LogReading.read(events, context: LogReading.Context(pulledBy: pull.query.ip, lockedAt: knowsLockTime ? lockedAt : nil))
    }

    /// The logs that couldn't be read: their events aren't in the findings, and that is said.
    private var unread: [String] {
        pull.logs.filter { (try? $0.rows.get()) == nil }.map(\.application.name)
    }

    /// Every row read, as the reader sees it.
    static func events(_ pull: IncidentLogs.Pull) -> [LogReading.Event] {
        pull.logs.flatMap { log in
            ((try? log.rows.get()) ?? []).map { row in
                LogReading.Event(log: row.application.rawValue, time: row.date, who: row.who, event: row.event, ip: row.ip,
                                 flagged: row.flagged,
                                 parameters: Dictionary(row.parameters.map { ($0.name, $0.value) }, uniquingKeysWith: { first, _ in first }),
                                 agent: row.agent, app: row.app)
            }
        }
    }

    var body: some View {
        let reading = reading
        Section {
            Toggle("I know when the account was locked", isOn: $knowsLockTime)
            if knowsLockTime {
                DatePicker("Locked at", selection: $lockedAt)
                    .accessibilityHint("Activity from a suspect address after this time is called out.")
            }
            if !unread.isEmpty {
                Label("Not read, so not in these findings: " + unread.joined(separator: ", ") + ".", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
            }
            if reading.findings.isEmpty {
                Text("Nothing in these logs matches a rule: no address Google flagged, and none named. Pull every account's logs "
                     + "by the attacker's address to see more.")
                    .foregroundStyle(.secondary)
            }
            ForEach(reading.findings) { finding in
                FindingRow(finding: finding, secure: secure, pullEmail: pullEmail)
            }
            explanation(reading)
        } header: {
            Text("Read the logs").accessibilityAddTraits(.isHeader)
                .onChange(of: key, initial: true) { _, key in cached = (key, Self.events(pull)) }
        } footer: {
            Text("Found by rules in code, from the logs above. A fix opens its screen with the person or the email filled in; "
                 + "nothing changes until you preview and confirm it there.")
        }
    }

    @ViewBuilder private func explanation(_ reading: LogReading.Reading) -> some View {
        let current = explained.flatMap { $0.reading == reading ? $0.state : nil }
        if let unavailable = LogExplainer.unavailable {
            Label(unavailable, systemImage: "sparkles").foregroundStyle(.secondary)
        } else if !reading.findings.isEmpty {
            HStack {
                Text("Have the on-device model explain these findings in plain words. Nothing leaves this Mac.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if case .asking? = current { ProgressView().controlSize(.small) }
                Button("Explain") { explain(reading) }
                    .disabled({ if case .asking? = current { return true } else { return false } }())
                    .accessibilityLabel("Explain the findings with the on-device model")
            }
        }
        switch current {
        case .done(let explanation)?:
            VStack(alignment: .leading, spacing: 6) {
                Label("Written by the on-device model from the findings above: check each against them.", systemImage: "sparkles")
                    .font(.callout).foregroundStyle(.secondary)
                if !explanation.overview.isEmpty { Text(explanation.overview) }
                ForEach(Array(explanation.points.enumerated()), id: \.offset) { _, point in
                    Text("• \(point.text) (about \(point.cites.joined(separator: ", ")))")
                }
                if !explanation.checks.isEmpty {
                    Text("To check next").fontWeight(.semibold).accessibilityAddTraits(.isHeader)
                    ForEach(Array(explanation.checks.enumerated()), id: \.offset) { _, check in Text("• \(check)") }
                }
            }
            .textSelection(.enabled)
            .accessibilityElement(children: .combine)
        case .failed(let why)?:
            Label("The model couldn't explain them: \(why)", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        case .asking?, nil:
            EmptyView()
        }
    }

    private func explain(_ reading: LogReading.Reading) {
        explained = (reading, .asking)
        Task {
            do {
                let explanation = try await LogExplainer.explain(reading)
                if explained?.reading == reading { explained = (reading, .done(explanation)) }
            } catch {
                if explained?.reading == reading { explained = (reading, .failed(error.localizedDescription)) }
            }
        }
    }
}

/// One finding: its sentence, said with what kind it is, and a button for each fix it points to.
private struct FindingRow: View {
    let finding: LogReading.Finding
    let secure: (String) -> Void
    let pullEmail: (String) -> Void

    private var symbol: String {
        switch finding.kind {
        case .signedInFromSuspect, .appFromSuspect, .actedFromSuspect, .exportedFromSuspect, .passwordOnPhishingSite, .afterLock:
            "exclamationmark.octagon.fill"
        case .mailFromSuspect, .failedFromSuspect, .chatFromSuspect, .pastPhishingWarning, .breachedPassword: "exclamationmark.triangle.fill"
        case .agentActed: "sparkles"
        case .passwordOnOtherSite, .sharedAddress, .suspectAddress: "info.circle"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("\(finding.id). \(finding.words)").textSelection(.enabled)
            } icon: {
                Image(systemName: symbol).symbolRenderingMode(.multicolor)
            }
            .accessibilityLabel("Finding \(finding.id): \(finding.words)")
            if !finding.drafts.isEmpty {
                HStack {
                    ForEach(finding.drafts, id: \.self) { draft in
                        Button(draft.title) {
                            switch draft {
                            case .secureAccount(let person): secure(person)
                            case .pullEmail(let id, _): pullEmail(id)
                            }
                        }
                        .accessibilityHint(hint(draft))
                    }
                }
                .padding(.leading, 28)
            }
        }
    }

    private func hint(_ draft: LogReading.Draft) -> String {
        switch draft {
        case .secureAccount: "Opens Incident and checks them. Nothing changes until you preview and confirm there."
        case .pullEmail: "Opens Phishing and finds who has the email. Nothing changes until you preview and confirm there."
        }
    }
}
