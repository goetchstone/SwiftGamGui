import Assist
import Directory
import GamEngine
import SwiftUI

/// Reports' connected apps and agents, a check of the whole tenant: every account's app grants (suspended accounts aside),
/// read with GAM when asked (`ConnectedAppsRead`), counted by code (`ConnectedApps.Summary`) and listed AI assistants and
/// agents first, then the broadest access, then the most people, each with who granted it. On request the on-device model
/// words the counts (`AppsExplainer`), never given an app's name. It reads only and reaches no change: its own file, apart
/// from anything that can run gam (invariant 10, `WriteRouteTests`).
struct ConnectedAppsPanel: View {
    let reads: ConnectedAppsRead
    @State private var explained: (facts: AppsExplainer.Facts, state: Explaining)?

    enum Explaining {
        case asking
        case done(String)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Connected apps and agents").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Text("The apps and AI agents people have given access to their accounts (suspended accounts aside), read with GAM "
                     + "when you ask. Reading changes nothing.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            switch reads.state {
            case nil:
                Button("Read Connected Apps") { read() }
                    .padding(.horizontal)
                    .accessibilityHint("Reads every account's connected apps and agents. Nothing changes.")
                Spacer()
            case .reading?:
                HStack { ProgressView().controlSize(.small); Text("Reading every account's apps…").foregroundStyle(.secondary) }
                    .accessibilityElement(children: .combine)
                    .padding(.horizontal)
                Spacer()
            case .read(.failure(let problem), _)?:
                VStack(alignment: .leading, spacing: 8) {
                    Label("Couldn't read the connected apps: \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor).textSelection(.enabled)
                    Button("Try Again") { read() }
                }
                .padding(.horizontal)
                Spacer()
            case .read(.success(let apps), let at)?:
                list(apps, at: at)
            }
        }
    }

    private func read() {
        let reads = reads
        Task { await reads.read() }
    }

    private func list(_ apps: [ConnectedApps.App], at: Date) -> some View {
        let summary = ConnectedApps.Summary(apps)
        return Form {
            Section {
                ForEach(Array(summary.sentences.enumerated()), id: \.offset) { _, sentence in Text(sentence) }
                explanation(summary)
            } header: {
                Text("Summary").accessibilityAddTraits(.isHeader)
            } footer: {
                Text("Counted by this app when read, at \(at.formatted(date: .omitted, time: .shortened)). An app is called AI by its "
                     + "name alone.")
            }
            group("AI assistants and agents, by name", apps.filter(\.looksLikeAI))
            group("Broad access", apps.filter { !$0.looksLikeAI && $0.reach == .broad })
            group("Other apps", apps.filter { !$0.looksLikeAI && $0.reach != .broad })
            Section {
                Text("An attacked account's apps are revoked by Incident's sign-out. To take an app away from everyone, block it in "
                     + "the Admin console (Security → API controls → App access control).")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .textSelection(.enabled)
    }

    @ViewBuilder private func group(_ title: String, _ apps: [ConnectedApps.App]) -> some View {
        if !apps.isEmpty {
            Section {
                ForEach(apps) { app in AppRow(app: app, showsUsers: true) }
            } header: {
                Text("\(title) (\(apps.count))").accessibilityAddTraits(.isHeader)
            }
        }
    }

    @ViewBuilder private func explanation(_ summary: ConnectedApps.Summary) -> some View {
        let facts = Self.facts(summary)
        let current = explained.flatMap { $0.facts == facts ? $0.state : nil }
        if let unavailable = AppsExplainer.unavailable {
            Label(unavailable, systemImage: "sparkles").foregroundStyle(.secondary)
        } else if summary.apps > 0 {
            HStack {
                Text("Have the on-device model explain these counts in plain words. It's given the counts only, never an app's name. "
                     + "Nothing leaves this Mac.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                if case .asking? = current { ProgressView().controlSize(.small) }
                Button("Explain") { explain(facts) }
                    .disabled({ if case .asking? = current { return true } else { return false } }())
                    .accessibilityLabel("Explain the summary with the on-device model")
            }
        }
        switch current {
        case .done(let overview)?:
            VStack(alignment: .leading, spacing: 6) {
                Label("Written by the on-device model from the counts above: check it against them.", systemImage: "sparkles")
                    .font(.callout).foregroundStyle(.secondary)
                Text(overview.isEmpty ? "The model's sentences didn't match the counts, so none is shown." : overview)
            }
            .accessibilityElement(children: .combine)
        case .failed(let why)?:
            Label("The model couldn't explain the summary: \(why)", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
        case .asking?, nil:
            EmptyView()
        }
    }

    private func explain(_ facts: AppsExplainer.Facts) {
        explained = (facts, .asking)
        Task {
            do {
                let overview = try await AppsExplainer.explain(facts)
                if explained?.facts == facts { explained = (facts, .done(overview)) }
            } catch {
                if explained?.facts == facts { explained = (facts, .failed(error.localizedDescription)) }
            }
        }
    }

    /// The summary as the model may see it: its counts, the kinds of access by their raw values.
    static func facts(_ summary: ConnectedApps.Summary) -> AppsExplainer.Facts {
        AppsExplainer.Facts(apps: summary.apps, people: summary.people, ai: summary.ai, aiPeople: summary.aiPeople,
                            broad: summary.broad, aiBroad: summary.aiBroad, onePerson: summary.onePerson,
                            onePersonAI: summary.onePersonAI, onePersonBroad: summary.onePersonBroad,
                            areas: Dictionary(uniqueKeysWithValues: summary.areas.compactMap { kind, count in
                                AppsExplainer.Area(rawValue: kind.rawValue).map { ($0, count) }
                            }))
    }
}

/// One app: its name, whether it looks like an AI assistant or agent, what it may do in words, and (for everyone's list on
/// Reports) who granted it. Read whole by VoiceOver.
struct AppRow: View {
    let app: ConnectedApps.App
    let showsUsers: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(app.name).fontWeight(.semibold)
                if app.looksLikeAI { Label("AI assistant or agent, by its name", systemImage: "sparkles").font(.callout) }
                if app.reach == .broad { Label("Broad access", systemImage: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor).font(.callout) }
            }
            Text(app.access.isEmpty ? "No scopes listed" : app.access.joined(separator: ", ")).font(.callout)
            if showsUsers {
                Text((app.users.count == 1 ? "1 person: " : "\(app.users.count) people: ") + app.users.prefix(6).joined(separator: ", ")
                     + (app.users.count > 6 ? " and \(app.users.count - 6) more" : ""))
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
