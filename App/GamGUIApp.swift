import AppKit
import Directory
import GamEngine
import Jobs
import Setup
import SwiftUI

@main
struct GamGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var services: AppServices

    init() {
        let services = AppServices.make()
        _services = State(initialValue: services)
        // Siri's intents reach the drafts only (invariant 10).
        SiriIntents.register(services.siriDrafts)
        // Quitting mid-onboarding, mid-offboarding, mid-lock or mid-trash asks first.
        let onboarding = services.onboardChanges, offboarding = services.offboardChanges
        let compromised = services.compromisedChanges, phishing = services.phishingChanges
        AppDelegate.interruptible = {
            offboarding.interruptible ?? compromised.interruptible ?? onboarding.interruptible ?? phishing.interruptible
        }
    }

    var body: some Scene {
        WindowGroup("GAM GUI") {
            ContentView(services: services)
                .task { await Spikes.runIfRequested(services: services) }
        }
        // Every launch opens a fresh window: an admin tool has nothing worth restoring, and a restored
        // "no windows" state once left a launch with no window at all.
        .restorationBehavior(.disabled)
        // Room for the list and a person's page side by side. A window the operator sized keeps its size.
        .defaultSize(width: 1200, height: 760)
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case home = "Home"
    case users = "Users"
    case groups = "Groups"
    case calendars = "Calendars"
    case signatures = "Signatures"
    case onboard = "Onboard"
    case offboard = "Offboard"
    /// A taken-over account, start to finish (the compromised-account runbook): find who's affected, secure, pull, clean up.
    case compromised = "Incident"
    case phishing = "Phishing"
    /// GAM's command catalog: browse every command, run any that only reads.
    case builder = "Builder"
    case reports = "Reports"
    case audit = "Audit"
    case setup = "Setup"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: "house"
        case .users: "person.2"
        case .groups: "person.3"
        case .calendars: "calendar"
        case .signatures: "signature"
        case .onboard: "person.badge.plus"
        case .offboard: "person.badge.minus"
        case .compromised: "exclamationmark.shield"
        case .phishing: "envelope.badge.shield.half.filled"
        case .builder: "terminal"
        case .reports: "chart.bar.doc.horizontal"
        case .audit: "list.bullet.clipboard"
        case .setup: "key"
        }
    }

    /// The screen a launch opens on: Home, or in debug builds `SWIFTGAMGUI_SCREEN` (for snapshots).
    static var initial: Screen {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SCREEN"],
           let screen = allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) { return screen }
        #endif
        return .home
    }
}

/// The widths the window is built from. On macOS 27, when a person's page opens, SwiftUI adds the
/// inspector's width (and the floating sidebar's, a second time) to the list's minimum without raising
/// the window's: in a window narrower than that sum, AppKit loops until it raises NSGenericException
/// (failure-log 2026-10-10, "person-page layout loop"). So the sidebar and the inspector are bounded,
/// and the smallest window holds both at their widest with `Spikes.spareWidth` to spare; the screenshot
/// runs check it.
enum ColumnWidths {
    static let sidebar = (min: 150.0, ideal: 170.0, max: 190.0)
    static let inspector = (min: 320.0, ideal: 360.0, max: 400.0)
    static let windowMin = 920.0
    /// The window's own minimum height. A page never asks for more (the snapshots hold it): a taller minimum
    /// grows the window past the screen.
    static let windowMinHeight = 520.0
}

struct ContentView: View {
    let services: AppServices
    @State private var screen: Screen? = Screen.initial
    #if DEBUG
    @State private var demoJobs = false

    /// Two made-up runs for the tray's snapshot: an offboarding part done, and a pull from every mailbox that ended with two
    /// mailboxes failed. Events as the executor reports them; nothing runs.
    static func showDemoJobs(_ board: JobBoard) {
        let offboarding = UUID(), pull = UUID()
        board.handle(.started(job: pull, preview: UUID(), title: "Trash message for 9 addresses", total: 9))
        for name in ["alice", "bob", "dana", "erin", "frank", "gwen", "hank"] {
            board.handle(.step(job: pull, item: "Trash message: \(name)@example.com", outcome: .succeeded, detail: ""))
        }
        for name in ["ivy", "jack"] {
            board.handle(.step(job: pull, item: "Trash message: \(name)@example.com", outcome: .failed,
                               detail: "Mail service not enabled for \(name)@example.com."))
        }
        board.handle(.finished(job: pull))
        board.handle(.started(job: offboarding, preview: UUID(), title: "Offboarding carol@example.com", total: 12))
        for step in ["Sign out", "Reset password", "Hide from directory", "Set vacation", "Remove group member"] {
            board.handle(.step(job: offboarding, item: "\(step): carol@example.com", outcome: .succeeded, detail: ""))
        }
    }
    #endif
    /// The person Signatures opens on when another screen sends it one.
    @State private var signaturesPerson: String?
    /// The person Calendars opens on when Users sends it one.
    @State private var calendarsPerson: String?
    /// The person Users opens on when another screen sends it one (Reports' Show in Users).
    @State private var usersPerson: String?
    /// The person Incident checks when Users sends it one (Actions → Secure Account…).
    @State private var compromisedPerson: String?
    /// A Message-ID another screen asked Phishing to find (the log reader's "Pull … from Every Mailbox…").
    @State private var phishingMessage: String?
    /// Incident's reading of the logs, and the directory as it reads it: kept by the window, so going to another screen and
    /// back reads nothing again (the operator, 2026-10-27: each return re-read every event).
    @State private var incidentReading = LogReaderView.Memory()
    @State private var directoryIndex = DirectoryIndex()
    @State private var gamVersion: String?
    @Environment(\.appearsActive) private var appearsActive

    private var connection: String {
        let setup = services.setup, directory = services.directory
        if let domain = setup.active {
            return directory.isLoading && directory.users == nil
                ? "Connected to \(domain.name) · Loading the directory…" : "Connected to \(domain.name)"
        }
        if let domain = setup.reconnecting { return "Connecting to \(domain.name)…" }
        if let failure = setup.reconnectFailure { return "Couldn't reconnect to \(failure.domain.name)" }
        return "Not connected"
    }

    var body: some View {
        NavigationSplitView {
            List(Screen.allCases, selection: $screen) { item in
                Label(item.rawValue, systemImage: item.symbol)
            }
            .navigationSplitViewColumnWidth(min: ColumnWidths.sidebar.min, ideal: ColumnWidths.sidebar.ideal,
                                            max: ColumnWidths.sidebar.max)
        } detail: {
            switch screen ?? .home {
            case .home:
                HomeView(setup: services.setup, directory: services.directory, gamVersion: gamVersion,
                         hasGam: services.gam != nil, executor: services.executor, auditURL: services.auditURL) { screen = .setup }
                    .navigationTitle("Home")
            case .users:
                UsersView(setup: services.setup, directory: services.directory, changes: services.userChanges,
                          access: services.userAccess, searches: services.mailboxSearches, chromeProfiles: services.chromeProfiles, drafts: services.siriDrafts, calendarReads: services.calendarReads,
                          requested: $usersPerson,
                          openSignatures: { email in
                              signaturesPerson = email
                              screen = .signatures
                          }, openCalendars: { email in
                              calendarsPerson = email
                              screen = .calendars
                          }, openCompromised: { email in
                              compromisedPerson = email
                              screen = .compromised
                          })
                .navigationTitle("Users")
            case .groups:
                GroupsView(setup: services.setup, directory: services.directory, groups: services.groups,
                           members: services.groupMembers, changes: services.groupChanges)
                    .navigationTitle("Groups")
            case .calendars:
                CalendarsView(setup: services.setup, directory: services.directory, reads: services.calendarReads,
                              changes: services.calendarChanges, requested: $calendarsPerson)
                    .navigationTitle("Calendars")
            case .signatures:
                SignaturesView(setup: services.setup, directory: services.directory, changes: services.signatureChanges,
                               access: services.userAccess, templates: services.signatureTemplates,
                               roles: services.onboardRoles, requested: $signaturesPerson)
                    .navigationTitle("Signatures")
            case .onboard:
                OnboardView(setup: services.setup, directory: services.directory, changes: services.onboardChanges,
                            roles: services.onboardRoles, templates: services.signatureTemplates, groups: services.groups,
                            hasGam: services.executor != nil)
                    .navigationTitle("Onboard")
            case .offboard:
                OffboardView(setup: services.setup, directory: services.directory, changes: services.offboardChanges,
                             templates: services.offboardTemplates, hasGam: services.executor != nil)
                    .navigationTitle("Offboard")
            case .compromised:
                CompromisedView(setup: services.setup, directory: services.directory, changes: services.compromisedChanges,
                                logs: services.incidentLogs, groupsReached: services.groupsReached, known: services.knownSignIns,
                                nobodyHas: services.nobodyHas, incidents: services.incidents, readerMemory: incidentReading,
                                directoryIndex: directoryIndex, auditURL: services.auditURL, hasGam: services.executor != nil,
                                requested: $compromisedPerson) { id in
                    // An empty ID only opens the screen: what the operator pasted there stays.
                    if !id.isEmpty { phishingMessage = id }
                    screen = .phishing
                }
                    .navigationTitle("Incident")
            case .phishing:
                PhishingView(setup: services.setup, changes: services.phishingChanges, hasGam: services.executor != nil,
                             requested: $phishingMessage)
                    .navigationTitle("Phishing")
            case .builder:
                BuilderView(setup: services.setup, access: services.userAccess)
                    .navigationTitle("Builder")
            case .reports:
                ReportsView(setup: services.setup, directory: services.directory, usage: services.usage,
                            apps: services.connectedApps) { email in
                    usersPerson = email
                    screen = .users
                }
                .navigationTitle("Reports")
            case .audit:
                AuditView(auditURL: services.auditURL)
                    .navigationTitle("Audit")
            case .setup:
                SetupView(model: services.setup)
                    .navigationTitle("Setup")
            }
        }
        // The jobs tray, on every screen: each run the executor makes, and Stop.
        .toolbar {
            ToolbarItem(placement: .primaryAction) { JobsButton(board: services.jobs) }
        }
        #if DEBUG
        // Snapshots (`SWIFTGAMGUI_TAB=jobs`): the tray over the screen, with made-up runs: nothing runs.
        .sheet(isPresented: $demoJobs) { JobsTray(board: services.jobs).frame(width: 440, height: 520) }
        .task {
            guard ProcessInfo.processInfo.environment["SWIFTGAMGUI_TAB"] == "jobs", Spikes.isRequested else { return }
            Self.showDemoJobs(services.jobs)
            demoJobs = true
        }
        #endif
        // Siri's request opens Users in the window in front, where it's drafted.
        .onChange(of: services.siriDrafts.titleChange != nil && appearsActive, initial: true) { _, wanted in
            if wanted { screen = .users }
        }
        // On every screen: connecting at launch, then loading, in words.
        .navigationSubtitle(connection)
        // And spoken, each step once: from the window in front only (every window sees the same models),
        // and "loaded" only for a load that succeeded.
        .onChange(of: services.setup.reconnecting) { _, domain in
            if let domain { announce("Connecting to \(domain.name).") }
        }
        .onChange(of: services.setup.reconnectFailure) { _, failure in
            if let failure { announce("Couldn't reconnect to \(failure.domain.name). \(failure.problem)") }
        }
        .onChange(of: services.directory.loadedAt) { _, loaded in
            if loaded != nil, let users = services.directory.users { announce("\(users.count.formatted()) accounts loaded.") }
        }
        .onChange(of: services.directory.problem) { _, problem in
            if let problem { announce("Couldn't load the directory. \(problem.summary)") }
        }
        .frame(minWidth: ColumnWidths.windowMin, minHeight: ColumnWidths.windowMinHeight)
        .task {
            // Local and credential-free.
            if let gam = services.gam {
                gamVersion = await GamVersion.running(gam.runner, runtimeDirectory: gam.runtimeDirectory)
            }
        }
        .task {
            // The domain connected last time is checked again (one Touch ID), and connecting loads the
            // directory: no trip to Setup on every launch. Once per run, not per window; never during a
            // spike or a snapshot.
            guard !Spikes.isRequested else { return }
            services.setup.reconnectAtLaunch()
        }
    }

    private func announce(_ text: String) {
        guard appearsActive else { return }
        AccessibilityNotification.Announcement(text).post()
    }
}
