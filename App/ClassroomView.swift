import Directory
import GamEngine
import Setup
import SwiftUI

/// Classroom (plan 2026-11-11 C1.3; GamGUI's Classroom screen at 3c8d909), read only, in two parts as GamGUI's two tabs:
/// Classes and Plan an Import (`RosterImportView`, C2). Classes: one search field takes a class's name, section or room,
/// which searches the index of open classes read once per domain, or a teacher's address, which reads that teacher's
/// classes, archived ones too, when Return is pressed and never as it's typed. A class opens as a card with who teaches it
/// and who is in it. Nothing here changes Classroom.
struct ClassroomView: View {
    enum Part: String, CaseIterable, Identifiable {
        case classes = "Classes"
        case plan = "Plan an Import"

        var id: Self { self }

        /// The part a launch opens on: Classes, or in debug builds Plan an Import with `SWIFTGAMGUI_TAB=import` (snapshots).
        static var initial: Part {
            #if DEBUG
            if ProcessInfo.processInfo.environment["SWIFTGAMGUI_TAB"] == "import" { return .plan }
            #endif
            return .classes
        }
    }

    let setup: SetupModel
    let directory: DirectoryStore
    let reads: ClassroomReads
    /// The group list as cached, for who can create classes (C1.6).
    let groups: GroupStore
    /// A class another screen asked to open (a person's classes on Users), cleared once its card is open.
    @Binding var requested: String?
    /// The kept roster, for Plan an Import.
    let roster: RosterKeeper
    /// Opens Groups on a group's page (by address), or on its list (empty).
    let openGroup: (String) -> Void
    @State private var part = Part.initial
    @State private var query = ""
    /// The teacher whose classes were asked for (Return), as typed.
    @State private var teacher = ""
    @State private var selection: String?
    @Environment(\.appearsActive) private var appearsActive

    /// The search as GamGUI compares it: stripped.
    private var searched: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// An address in the field: a teacher's classes, read only when asked.
    private var isAddress: Bool { searched.contains("@") }
    private var asked: Bool { isAddress && !teacher.isEmpty && teacher.lowercased() == searched.lowercased() }

    /// The classes listed: a teacher's, or the index's matching the search.
    private var courses: [Classroom.Course]? {
        if isAddress { return asked ? reads.teacher(teacher)?.value : nil }
        return reads.indexed(matching: searched)
    }

    /// Owner ID → address, from the directory as already cached: the index is read without `owneremail`. Never a fetch.
    private var owners: [String: String] { ClassroomReads.owners(directory.users ?? []) }

    var body: some View {
        VStack(spacing: 0) {
            Picker("Part of Classroom", selection: $part) {
                ForEach(Part.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 300)
            .padding([.horizontal, .top])
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            switch part {
            case .classes: classes
            case .plan:
                Divider()
                RosterImportView(setup: setup, roster: roster)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        // A class asked for from another screen opens on Classes (whose list then opens its card).
        .onChange(of: requested, initial: true) {
            if requested != nil { part = .classes }
        }
    }

    @ViewBuilder private var classes: some View {
        // Worked out once per redraw: the index can hold thousands of classes and the directory thousands of people.
        let courses = self.courses, owners = self.owners
        VStack(spacing: 0) {
            controls
            Divider()
            list(courses, owners: owners)
            if setup.active != nil, setup.classroomReadable != false {
                Divider()
                CreatorsPanel(setup: setup, groups: groups, openGroup: openGroup)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        // The index loads after the screen shows: a cold index is a domain-wide read.
        .task(id: setup.generation) { await reads.loadIndex() }
        .onChange(of: setup.generation) { selection = nil; teacher = "" }
        // A class asked for from a person's page opens its card, whether or not the list holds it (an archived class).
        .onChange(of: requested, initial: true) {
            guard let id = requested else { return }
            requested = nil
            if GamCommands.isCourseID(id) { selection = id }
        }
        .onChange(of: reads.indexState?.isReading) { was, now in
            guard was == true, now == false else { return }
            if let problem = reads.indexState?.problem {
                announce("Couldn't read Classroom. \(problem.summary)")
            } else if let count = reads.indexState?.value?.count {
                announce("\(count) open class\(count == 1 ? "" : "es") read.")
            }
        }
        .task(id: courses?.count ?? -1) { selectForSnapshot() }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }
                    .keyboardShortcut("r")
                    .disabled(setup.active == nil || (selection == nil
                        && (isAddress ? !asked || reads.teacher(teacher)?.isReading == true : reads.indexState?.isReading == true)))
                    .accessibilityIdentifier("classroom.refresh")
            }
        }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let selection {
                ClassCard(courseID: selection, listed: courses?.first { $0.id == selection }, owners: owners, reads: reads)
            }
        }
    }

    private func refresh() {
        if let selection { Task { await reads.readCard(selection) } }
        if isAddress {
            guard asked else { return }
            Task { await reads.readTeacher(teacher) }
        } else {
            Task { await reads.loadIndex(force: true) }
        }
    }

    private func announce(_ text: String) {
        guard appearsActive else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    /// Debug builds: `SWIFTGAMGUI_SELECT` types that search (a teacher's address is read) and `SWIFTGAMGUI_CALENDAR`, the
    /// snapshot script's page to open, opens that class's card, for the snapshots.
    private func selectForSnapshot() {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if query.isEmpty, let typed = environment["SWIFTGAMGUI_SELECT"] {
            query = typed
            if typed.contains("@") { submit() }
        }
        if selection == nil, let id = environment["SWIFTGAMGUI_CALENDAR"], courses?.contains(where: { $0.id == id }) == true {
            selection = id
        }
        #endif
    }

    private func submit() {
        guard isAddress, setup.active != nil else { return }
        teacher = searched
        Task { await reads.readTeacher(searched) }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Find a class", text: $query, prompt: Text("Class name, section or room, or a teacher's address"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .accessibilityLabel("Find a class by name, section or room, or a teacher's classes by their address")
                .onSubmit(submit)
            Text("Read only: GAM GUI never changes Classroom. Classroom support hasn't been checked on a real school domain yet.")
                .font(.callout).foregroundStyle(.secondary)
                // It wraps by itself. `fixedSize(horizontal: false, vertical: true)` here, above the list in the split view's
                // column, looped AppKit's layout until it crashed the app (failure-log 2026-11-12).
        }
        .padding()
    }

    @ViewBuilder private func list(_ courses: [Classroom.Course]?, owners: [String: String]) -> some View {
        if let courses {
            List(courses, selection: $selection) { course in
                CourseRow(course: course, owner: course.ownerEmail.isEmpty ? owners[course.ownerID] ?? "" : course.ownerEmail)
            }
            .overlay {
                if courses.isEmpty {
                    Text(isAddress ? "\(teacher) teaches no classes." : searched.isEmpty ? "No open classes."
                         : "No open class matches “\(searched)”.")
                        .foregroundStyle(.secondary)
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text(count(courses.count)).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        } else {
            VStack(spacing: 12) { status }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var status: some View {
        if let domain = setup.reconnecting {
            ProgressView("Connecting to \(domain.name)…")
        } else if setup.active == nil {
            Text("Connect a domain on Setup to see its classes.").foregroundStyle(.secondary)
        } else if isAddress {
            if !asked {
                Text("Press Return to read \(searched)'s classes.").foregroundStyle(.secondary)
            } else if let problem = reads.teacher(teacher)?.problem {
                problemView(problem.summary) { Task { await reads.readTeacher(teacher) } }
            } else {
                ProgressView("Reading \(teacher)'s classes…")
            }
        } else if let problem = reads.indexState?.problem {
            problemView(problem.summary) { Task { await reads.loadIndex(force: true) } }
        } else {
            ProgressView("Reading the open classes…")
        }
    }

    private func problemView(_ summary: String, retry: @escaping () -> Void) -> some View {
        VStack(spacing: 12) {
            Label(summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                .multilineTextAlignment(.center)
            Button("Try Again", action: retry)
        }
    }

    /// "3 open classes" / "1 of 3 open classes match" / "4 classes Alice teaches".
    private func count(_ shown: Int) -> String {
        let noun = { (n: Int) in "class\(n == 1 ? "" : "es")" }
        if isAddress { return "\(shown) \(noun(shown)) \(teacher) teaches, archived ones included" }
        let all = reads.indexState?.value?.count ?? shown
        let read = reads.indexReadAt.map { ", read \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        return searched.isEmpty ? "\(all) open \(noun(all))\(read)" : "\(shown) of \(all) open \(noun(all)) match\(read)"
    }
}

/// Who can create classes (plan 2026-11-11 C1.6; GamGUI's `_classroom_creators.html`), read only: the group named "Classroom
/// Teachers" or at `classroom_teachers@`, from the group list as cached (read once if none is), with its member count and a
/// way to it on Groups, where adding a staff group is the existing, proven write. GAM GUI reconciles nothing. Left off where
/// the admin token is known not to read Classroom.
private struct CreatorsPanel: View {
    let setup: SetupModel
    let groups: GroupStore
    let openGroup: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Who can create classes").font(.headline).accessibilityAddTraits(.isHeader)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .task(id: setup.generation) {
            guard setup.active != nil, groups.groups == nil, groups.problem == nil, !groups.isLoading else { return }
            await groups.load()
        }
    }

    /// The cached list wins over a later failed refresh (GroupStore keeps both; GamGUI's `/classroom/creators` reads
    /// with `stale_ok`): the problem shows only when there is no list, with a way to try again from here.
    @ViewBuilder private var content: some View {
        if let all = groups.groups {
            if let group = ClassroomReads.teachersGroup(in: all) {
                let name = group.name.isEmpty ? group.email : group.name
                let count = group.membersCount.map { " (\($0) direct member\($0 == 1 ? "" : "s"))" } ?? ""
                Text("Members of \(name)\(count). To let a department create classes, add its staff group there.")
                    .font(.callout)
                Button("Open \(name) on Groups") { openGroup(group.email) }
                    .accessibilityHint("Opens the group's page on Groups")
            } else {
                Text("No “\(ClassroomReads.teachersGroupName)” group found. Classroom's settings in the Admin console say which "
                     + "group may create classes; open it on Groups to add staff.")
                    .font(.callout)
                Button("Open Groups") { openGroup("") }
            }
        } else if let problem = groups.problem, !groups.isLoading {
            Label("Couldn't list groups. \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.multicolor).font(.callout)
            Button("Try Again") { Task { await groups.load() } }
                .disabled(setup.active == nil)
                .accessibilityLabel("Try listing the groups again")
        } else {
            ProgressView("Reading the groups…").controlSize(.small)
        }
    }
}

/// One class: its name, then section and room, then its owner and state; read by VoiceOver as one sentence.
private struct CourseRow: View {
    let course: Classroom.Course
    let owner: String

    private var place: String { [course.section, course.room].filter { !$0.isEmpty }.joined(separator: " · ") }
    private var details: String { [owner.isEmpty ? "" : "Owner \(owner)", course.stateWords].filter { !$0.isEmpty }.joined(separator: " · ") }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(course.name.isEmpty ? "Untitled class" : course.name).lineLimit(1).truncationMode(.tail)
            if !place.isEmpty { Text(place).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
            Text(details).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([course.name, place, details].filter { !$0.isEmpty }.joined(separator: ", "))
    }
}

/// One class's card: its details, a link to it in Classroom (only Classroom's own address), and who teaches it beside who
/// is in it, each capped with a count past it. A roster that failed or came back short says so above the lists.
private struct ClassCard: View {
    let courseID: String
    /// The class as the list read it, shown while its own read runs.
    let listed: Classroom.Course?
    let owners: [String: String]
    let reads: ClassroomReads

    private var card: ClassroomReads.Card? { reads.card(courseID) }
    private var course: Classroom.Course? { card?.course.value ?? listed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let problem = card?.course.problem {
                    Label(problem.summary, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                roster
                if card?.course.problem != nil || card?.roster.problem != nil {
                    Button("Read Again") { Task { await reads.readCard(courseID) } }
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 0, maxWidth: .infinity)
        .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal, max: ColumnWidths.inspector.max)
        // Read each time the class is opened, as GamGUI's card is; a quarter second later, so arrowing down the list starts
        // no gam for the classes passed over.
        .task(id: courseID) {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await reads.readCard(courseID)
        }
    }

    @ViewBuilder private var header: some View {
        Text(course?.name.isEmpty == false ? course!.name : "Class \(courseID)").font(.title2.bold())
            .accessibilityAddTraits(.isHeader)
        if let course {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Section", course.section)
                row("Room", course.room)
                row("State", course.stateWords)
                row("Owner", course.ownerEmail.isEmpty ? owners[course.ownerID] ?? "" : course.ownerEmail)
                row("Class ID", course.id)
            }
            if let link = Classroom.classLink(course.link) {
                Link("Open the Class in Classroom", destination: link)
            }
        }
    }

    @ViewBuilder private func row(_ label: String, _ value: String) -> some View {
        if !value.isEmpty {
            GridRow {
                Text(label).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var roster: some View {
        switch card?.roster {
        case nil, .reading?:
            ProgressView("Reading who is in the class…")
        case .read(.failure(let problem))?:
            Label("Couldn't read who is in the class. \(problem.summary)", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .read(.success(let roster))?:
            if !roster.unreadable.isEmpty {
                Label("Part of the roster couldn't be read (\(roster.unreadable.joined(separator: ", "))), so these lists may be "
                      + "incomplete.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            if roster.emailsHidden {
                Label("Some addresses are hidden: the admin token lacks the “Classroom API - Profile Emails” scope.",
                      systemImage: "info.circle").foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                people("Teachers", roster.teachers)
                people("Students", roster.students)
            }
        }
    }

    private func people(_ title: String, _ list: [Classroom.Participant]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title) (\(list.count))").font(.headline).accessibilityAddTraits(.isHeader)
            if list.isEmpty {
                Text("None").foregroundStyle(.secondary)
            }
            // By position: two people listed without an ID or an address would otherwise share one.
            ForEach(Array(list.prefix(ClassroomReads.rosterShown).enumerated()), id: \.offset) { _, person in
                VStack(alignment: .leading, spacing: 0) {
                    // Classroom leaves an address out without the "Profile Emails" scope: said, never a blank row.
                    Text(person.name.isEmpty ? (person.email.isEmpty ? "Someone (no address shown)" : person.email) : person.name)
                        .lineLimit(1)
                    if !person.name.isEmpty {
                        Text(person.email.isEmpty ? "no address shown" : person.email).font(.callout).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            if list.count > ClassroomReads.rosterShown {
                Text("and \(list.count - ClassroomReads.rosterShown) more").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
