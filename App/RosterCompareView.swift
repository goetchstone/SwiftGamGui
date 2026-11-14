import AppKit
import Directory
import Foundation
import Stores
import SwiftUI
import UniformTypeIdentifiers

/// Compare with Classroom and hand the change list over, on Plan an Import (plan 2026-11-11 C3, C4; GamGUI's
/// `_roster_plan.html` and `_roster_changes.html`). Reads only: the change list says what would make Classroom match the
/// kept roster, and the hand-over is files someone runs with GAM outside this app. The screen says so before the button.
struct RosterCompareView: View {
    let compare: RosterCompare
    let meta: RosterStore.Meta
    @State private var kind: RosterPlan.Kind?
    @State private var query = ""
    /// The query a quarter second after the last keystroke (GamGUI's `delay:250ms`): what the page is searched for.
    @State private var searched = ""
    @State private var page = 1
    /// The page shown, worked out off the main actor (a district's list is tens of thousands of changes).
    @State private var shown: RosterPlan.Page?
    /// Flagged kinds the operator ticked to include.
    @State private var included: Set<RosterPlan.Kind> = []
    @State private var saved: String?
    @AccessibilityFocusState private var summaryFocused: Bool

    private var held: RosterCompare.Held? { compare.held(for: meta.sha256) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if compare.isRunning {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ProgressView().controlSize(.small).accessibilityHidden(true)
                    Text("Reading every class in Classroom, with its people… this can take minutes on a district. You can keep working.")
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if let problem = compare.problem {
                Label("Couldn't compare with Classroom. \(problem)", systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .textSelection(.enabled)
                Button("Try Again") { run() }
                    .keyboardShortcut("r")
            } else if let held {
                changeList(held)
            } else {
                Button("Compare with Classroom") { run() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("r")
                    .accessibilityHint("Reads every class in Classroom, with its people. Changes nothing.")
                Text("Reads Classroom only. The change list says what would make Classroom match this roster.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        // Each compare's own identity: two in one minute share `when`.
        .onChange(of: held?.id) { _, _ in
            (kind, query, searched, page, shown, included, saved) = (nil, "", "", 1, nil, [], nil)
        }
    }

    /// Unstoppable and one at a time: the read carries on if the screen is left. Says what this ask came to; a compare
    /// dropped by a new roster, a purge or a tenant switch says nothing (that change said itself).
    private func run() {
        Task {
            switch await compare.compare() {
            case .compared(let held):
                AccessibilityNotification.Announcement("Compared. \(Self.shown(held.plan.summary))").post()
                summaryFocused = true
            case .failed(let problem):
                AccessibilityNotification.Announcement("Couldn't compare with Classroom. \(problem)").post()
            case .busy:
                AccessibilityNotification.Announcement("A compare is already reading Classroom.").post()
            case .dropped:
                break
            }
        }
    }

    /// GamGUI's planner says "GamGUI"; this app is GAM GUI on the screen. The hand-over's files keep GamGUI's words.
    static func shown(_ text: String) -> String { text.replacingOccurrences(of: "GamGUI", with: "GAM GUI") }

    // MARK: the change list

    @ViewBuilder private func changeList(_ held: RosterCompare.Held) -> some View {
        let plan = held.plan
        HStack(alignment: .firstTextBaseline) {
            Text("Change list · compared \(held.when)").font(.headline).accessibilityAddTraits(.isHeader)
            Spacer()
            Button("Compare Again") { run() }
                .keyboardShortcut("r")
                .accessibilityHint("Reads Classroom again and shows what's still different")
        }
        Text(Self.shown(plan.summary))
            .font(.body.weight(.semibold))
            .accessibilityFocused($summaryFocused)
        ForEach(plan.flags, id: \.kind) { flag in
            Label {
                Text("**\(flag.kind.words) held back.** \(Self.shown(flag.why))")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.orange.opacity(0.1), in: .rect(cornerRadius: 6))
        }
        ForEach(plan.notes, id: \.self) { note in
            Label(Self.shown(note), systemImage: "info.circle")
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 6))
        }
        if !plan.changes.isEmpty {
            kinds(plan)
            list(held)
            handOver(held)
        }
        Text("GAM GUI changes nothing in Classroom. Only classes GAM GUI's alias marks are compared; "
             + "\(RosterPlan.grouped(plan.unmanagedIgnored)) other class\(plan.unmanagedIgnored != 1 ? "es" : "") in Classroom "
             + "\(plan.unmanagedIgnored != 1 ? "are" : "is") left alone.")
            .font(.callout).foregroundStyle(.secondary)
    }

    /// A chip per kind with its count, all first; a flagged kind marked with its icon and "held back", not by color alone.
    private func kinds(_ plan: RosterPlan.ChangeList) -> some View {
        FlowLayout(spacing: 6) {
            chip("All · \(RosterPlan.grouped(plan.changes.count))", selected: kind == nil, flagged: false) { show(nil) }
            ForEach(RosterPlan.Kind.allCases.filter { plan.count($0) > 0 }) { item in
                chip("\(item.words) · \(RosterPlan.grouped(plan.count(item)))", selected: kind == item,
                     flagged: plan.flag(item) != nil) { show(item) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Show one kind of change")
    }

    private func chip(_ title: String, selected: Bool, flagged: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if flagged { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true) }
                Text(title)
            }
        }
        .buttonStyle(.bordered)
        .tint(selected ? Color.accentColor : nil)
        .accessibilityLabel(title + (flagged ? ", held back" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func show(_ item: RosterPlan.Kind?) {
        kind = item
        page = 1
    }

    /// What the shown page is of: a compare, a kind, a search and a page number.
    private struct PageAsk: Equatable {
        let compare: UUID
        let kind: RosterPlan.Kind?
        let query: String
        let page: Int
    }

    @ViewBuilder private func list(_ held: RosterCompare.Held) -> some View {
        let plan = held.plan
        TextField("Class, teacher or student", text: $query)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel("Search the change list")
            .onChange(of: query) { _, _ in page = 1 }
            .task(id: query) {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { searched = query }
            }
            .task(id: PageAsk(compare: held.id, kind: kind, query: searched, page: page)) {
                let (kind, query, page, haystack) = (kind, searched, page, held.haystack)
                let found = await Task.detached { RosterPlan.page(plan, kind: kind, query: query, page: page, haystack: haystack) }.value
                if !Task.isCancelled { shown = found }
            }
        if let shown { rows(shown, of: plan) }
    }

    @ViewBuilder private func rows(_ shown: RosterPlan.Page, of plan: RosterPlan.ChangeList) -> some View {
        let words = searched.trimmingCharacters(in: .whitespaces)
        let what = (kind.map { "\($0.words): " } ?? "") + "\(RosterPlan.grouped(shown.total)) change\(shown.total != 1 ? "s" : "")"
            + (words.isEmpty ? "" : " matching “\(words)”")
            + (shown.pages > 1 ? " · showing \(shown.start + 1)–\(shown.start + shown.rows.count)" : "")
        Text(what).font(.callout).foregroundStyle(.secondary)
        if shown.rows.isEmpty {
            Text("None.").foregroundStyle(.secondary)
        } else {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Change", "Class", "Person or detail"], id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
                .accessibilityHidden(true)
                ForEach(Array(shown.rows.enumerated()), id: \.offset) { _, change in
                    let flagged = plan.flag(change.kind) != nil
                    GridRow {
                        // Held back is said by its icon too, not by color alone (as the chips say it).
                        HStack(spacing: 4) {
                            if flagged { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                            Text(change.kind.words).foregroundStyle(flagged ? .orange : .primary)
                        }
                        Text(change.title).lineLimit(2).help(change.alias)
                        Text(Self.detail(change)).lineLimit(2).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(change.kind.words)\(flagged ? ", held back" : ""): \(change.title), \(Self.detail(change))")
                }
            }
        }
        if shown.pages > 1 {
            HStack {
                Spacer()
                Text("Page \(shown.page) of \(shown.pages)").foregroundStyle(.secondary)
                Button("Previous") { page = shown.page - 1 }.disabled(shown.page <= 1)
                Button("Next") { page = shown.page + 1 }.disabled(shown.page >= shown.pages)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Change list pages")
        }
    }

    /// What a row says beside its class (GamGUI's): a new class and its owner, a before and after, or the person.
    static func detail(_ change: RosterPlan.Change) -> String {
        if change.kind == .create { return "\(change.after), owned by \(change.person)" }
        if !change.before.isEmpty || !change.after.isEmpty {
            return "\(change.before.isEmpty ? "—" : change.before) → \(change.after.isEmpty ? "—" : change.after)"
        }
        return change.person
    }

    // MARK: the hand-over (C4)

    @ViewBuilder private func handOver(_ held: RosterCompare.Held) -> some View {
        let plan = held.plan
        VStack(alignment: .leading, spacing: 8) {
            Text("Hand It Over").font(.headline).accessibilityAddTraits(.isHeader)
            if plan.incomplete {
                Text("Not while part of Classroom couldn't be read. Compare again first.")
            } else {
                // Said before the button, plainly (C4.3).
                // One literal: a literal is a LocalizedStringKey, whose Markdown (the bold, the code) SwiftUI reads.
                Text("GAM GUI doesn't make these changes. The download holds the review sheet and a numbered CSV per kind of change, with the `gam csv` line that runs each, in order. Whoever runs them does so **outside GAM GUI's preview, confirmation and audit log**, and Classroom support hasn't been checked on a real school domain: try them on a test class first.")
                ForEach(plan.flags, id: \.kind) { flag in
                    Toggle(isOn: Binding(get: { included.contains(flag.kind) },
                                         set: { if $0 { included.insert(flag.kind) } else { included.remove(flag.kind) } })) {
                        Text("Include \(flag.kind.words.lowercased()), held back by the risk check")
                    }
                    .toggleStyle(.checkbox)
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Button("Download the Hand-over…") { save(held) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint("Saves a ZIP of the review sheet and the GAM files on this Mac. Nothing runs.")
                }
                if !plan.flags.isEmpty, included.isEmpty {
                    Text("It leaves out what the risk check held back unless you tick it above.").font(.callout).foregroundStyle(.secondary)
                }
                if let saved { Text(saved).font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: .rect(cornerRadius: 8))
    }

    private func save(_ held: RosterCompare.Held) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = RosterHandover.zipName(domain: held.domain, when: held.when)
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        let flagged = RosterPlan.Kind.allCases.filter { included.contains($0) }
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let destination = panel.url else { return }
            Task {
                let said = await compare.handOver(held, including: flagged, to: destination)
                saved = said
                AccessibilityNotification.Announcement(said).post()
            }
        }
        if let window = NSApp.keyWindow { panel.beginSheetModal(for: window, completionHandler: finish) } else { panel.begin(completionHandler: finish) }
    }
}

/// Lays its views out in rows, wrapping to the next row when one is full (the change list's chips).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.width }.max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: min(width, proposal.width ?? width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var items: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].items.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].items.isEmpty ? 0 : spacing
            rows[rows.count - 1].items.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}
