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
        // The Vault's session ends with the screen's.
        AppDelegate.lockVault = services.lockVault
    }

    var body: some Scene {
        WindowGroup("GAM GUI") {
            ContentView(services: services)
                // Each CSV a screen saves through a save panel is listed on Files (plan F4).
                .environment(services.savedFiles)
                .task { await Spikes.runIfRequested(services: services) }
        }
        // Every launch opens a fresh window: an admin tool has nothing worth restoring, and a restored
        // "no windows" state once left a launch with no window at all.
        .restorationBehavior(.disabled)
        // Room for the list and a person's page side by side. A window the operator sized keeps its size.
        .defaultSize(width: 1200, height: 760)
        // Switch Domain… (⇧⌘D) and each other domain, for the window in front (plan F6).
        .commands { DomainCommands(setup: services.setup) }
    }
}

enum Screen: String, CaseIterable, Identifiable {
    case home = "Home"
    case users = "Users"
    case groups = "Groups"
    /// Shared drives and their members (roadmap 4.7).
    case drives = "Shared Drives"
    case calendars = "Calendars"
    /// Google Classroom, read only: find a class by name or teacher, see who is in it.
    case classroom = "Classroom"
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
    /// What this app made, read only: the Sheets exported, each incident's evidence, the files saved (plan F4).
    case files = "Files"
    case setup = "Setup"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .home: "house"
        case .users: "person.2"
        case .groups: "person.3"
        case .drives: "externaldrive.connected.to.line.below"
        case .calendars: "calendar"
        case .classroom: "graduationcap"
        case .signatures: "signature"
        case .onboard: "person.badge.plus"
        case .offboard: "person.badge.minus"
        case .compromised: "exclamationmark.shield"
        case .phishing: "envelope.badge.shield.half.filled"
        case .builder: "terminal"
        case .reports: "chart.bar.doc.horizontal"
        case .audit: "list.bullet.clipboard"
        case .files: "folder"
        case .setup: "key"
        }
    }

    /// The screen a launch opens on: Home, or in debug builds `SWIFTGAMGUI_SCREEN` (for snapshots).
    static var initial: Screen {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["SWIFTGAMGUI_SCREEN"],
           let screen = allCases.first(where: { $0.rawValue.lowercased().replacingOccurrences(of: " ", with: "") == name.lowercased() }) {
            return screen
        }
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
    /// The toolbar's domain menu (plan F6): this window's panel, and what its last switch said.
    @State private var switcher: DomainSwitcher
    /// Tenant changes since this window first had a domain connected: the screen is made again for the tenant now, as GamGUI
    /// reloads it, so nothing a screen held for the old one (a selection, a form, the Builder's last result) shows there.
    /// Every change counts, a removal or re-import then a check included (plan F6's review), but not the window's first
    /// connection (nothing was shown for a domain before it), and Setup is never made again: it holds no domain's data, and
    /// its own Check Access is often what switched (its form, focus and scroll stay).
    @State private var switches = 0
    /// A domain has been connected while this window was open, or was when it opened.
    @State private var everConnected: Bool
    #if DEBUG
    @State private var demoJobs = false
    /// Snapshots (`SWIFTGAMGUI_TAB=domain` or `domain-warning`): the domain menu's panel over the screen.
    @State private var demoDomain = false

    /// Three made-up runs for the tray's snapshot: a pull from every mailbox that ended with two mailboxes failed, an offboarding
    /// part done, and a suspend still checking before it runs. Events as the executor reports them; nothing runs.
    static func showDemoJobs(_ board: JobBoard) {
        let offboarding = UUID(), pull = UUID()
        board.handle(.started(job: pull, preview: UUID(), title: "Trash message for 9 addresses", total: 9))
        board.handle(.checked(job: pull))
        for name in ["alice", "bob", "dana", "erin", "frank", "gwen", "hank"] {
            board.handle(.step(job: pull, item: "Trash message: \(name)@example.com", outcome: .succeeded, detail: ""))
        }
        for name in ["ivy", "jack"] {
            board.handle(.step(job: pull, item: "Trash message: \(name)@example.com", outcome: .failed,
                               detail: "Mail service not enabled for \(name)@example.com."))
        }
        board.handle(.finished(job: pull))
        board.handle(.started(job: offboarding, preview: UUID(), title: "Offboarding carol@example.com", total: 12, routine: true))
        board.handle(.checked(job: offboarding))
        for step in ["Sign out", "Reset password", "Hide from directory", "Set vacation", "Remove group member"] {
            board.handle(.step(job: offboarding, item: "\(step): carol@example.com", outcome: .succeeded, detail: ""))
        }
        board.handle(.started(job: UUID(), preview: UUID(), title: "Suspend user for dana@example.com", total: 1))
    }
    #endif
    /// The person Signatures opens on when another screen sends it one.
    @State private var signaturesPerson: String?
    /// The person Calendars opens on when Users sends it one.
    @State private var calendarsPerson: String?
    /// The class Classroom opens on when Users sends it one (a person's classes).
    @State private var classroomCourse: String?
    /// The group Groups opens on when Classroom sends it one (who can create classes); empty for the list.
    @State private var groupsGroup: String?
    /// The person Users opens on when another screen sends it one (Reports' Show in Users).
    @State private var usersPerson: String?
    /// The audit run Reports opens on when Home sends it one (a scheduled run that's due).
    @State private var reportsRun: String?
    /// Home's All Failures in Audit: Audit opens narrowed to failures, and takes it.
    @State private var auditFailures = false
    /// The person Incident checks when Users sends it one (Actions → Secure Account…).
    @State private var compromisedPerson: String?
    /// A Message-ID another screen asked Phishing to find (the log reader's "Pull … from Every Mailbox…").
    @State private var phishingMessage: String?
    /// The catalog command another screen asked the Builder to open (Reports' named reports).
    @State private var builderCommand: String?
    /// Incident's reading of the logs, and the directory as it reads it: kept by the window, so going to another screen and
    /// back reads nothing again (the operator, 2026-10-27: each return re-read every event).
    @State private var incidentReading = LogReaderView.Memory()
    @State private var directoryIndex = DirectoryIndex()
    @State private var gamVersion: String?
    @Environment(\.appearsActive) private var appearsActive

    init(services: AppServices) {
        self.services = services
        _switcher = State(initialValue: DomainSwitcher(setup: services.setup))
        _everConnected = State(initialValue: services.setup.active != nil)
    }

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
            Group {
                switch screen ?? .home {
                case .home:
                    HomeView(setup: services.setup, directory: services.directory, schedules: services.runSchedules,
                             openRun: { key in
                                 reportsRun = key
                                 screen = .reports
                             }, gamVersion: gamVersion,
                             hasGam: services.gam != nil, executor: services.executor, auditURL: services.auditURL, jobs: services.jobs,
                             openFailures: {
                                 auditFailures = true
                                 screen = .audit
                             }) { screen = .setup }
                        .navigationTitle("Home")
                case .users:
                    UsersView(setup: services.setup, directory: services.directory, changes: services.userChanges,
                              access: services.userAccess, searches: services.mailboxSearches, chromeProfiles: services.chromeProfiles, personDevices: services.personDevices, drafts: services.siriDrafts, calendarReads: services.calendarReads,
                              classroom: services.classroom,
                              departments: services.departmentForMany, groups: services.groups,
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
                              }, openClass: { id in
                                  classroomCourse = id
                                  screen = .classroom
                              })
                    .navigationTitle("Users")
                case .drives:
                    SharedDrivesView(setup: services.setup, model: services.sharedDrives)
                        .navigationTitle("Shared Drives")
                case .groups:
                    GroupsView(setup: services.setup, directory: services.directory, groups: services.groups,
                               members: services.groupMembers, changes: services.groupChanges, requested: $groupsGroup)
                        .navigationTitle("Groups")
                case .calendars:
                    CalendarsView(setup: services.setup, directory: services.directory, reads: services.calendarReads,
                                  changes: services.calendarChanges, requested: $calendarsPerson)
                        .navigationTitle("Calendars")
                case .classroom:
                    ClassroomView(setup: services.setup, directory: services.directory, reads: services.classroom,
                                  groups: services.groups, requested: $classroomCourse, roster: services.roster) { address in
                        groupsGroup = address
                        screen = .groups
                    }
                        .navigationTitle("Classroom")
                case .signatures:
                    SignaturesView(setup: services.setup, directory: services.directory, changes: services.signatureChanges,
                                   access: services.userAccess, templates: services.signatureTemplates, groups: services.groups,
                                   roles: services.onboardRoles, requested: $signaturesPerson)
                        .navigationTitle("Signatures")
                case .onboard:
                    OnboardView(setup: services.setup, directory: services.directory, changes: services.onboardChanges,
                                roles: services.onboardRoles, hires: services.hiresFromCSV, templates: services.signatureTemplates, groups: services.groups,
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
                    BuilderView(setup: services.setup, access: services.userAccess, directory: services.directory, groups: services.groups,
                                changes: services.builderChanges, readAudit: services.readAudit, exports: services.sheetExports,
                                requested: $builderCommand)
                        .navigationTitle("Builder")
                case .reports:
                    ReportsView(setup: services.setup, directory: services.directory, usage: services.usage,
                                apps: services.connectedApps, runs: services.auditRuns, suspend: services.inactiveSuspend,
                                schedules: services.runSchedules, requestedRun: $reportsRun,
                                openCommand: { id in
                                    builderCommand = id
                                    screen = .builder
                                }) { email in
                        usersPerson = email
                        screen = .users
                    }
                    .navigationTitle("Reports")
                case .audit:
                    AuditView(auditURL: services.auditURL, showFailures: $auditFailures)
                        .navigationTitle("Audit")
                case .files:
                    FilesView(auditURL: services.auditURL, incidents: services.incidents, saved: services.savedFiles)
                        .navigationTitle("Files")
                case .setup:
                    SetupView(model: services.setup)
                        .navigationTitle("Setup")
                }
            }
            // A tenant change makes the screen again, for the tenant now (plan F6); Setup stays as it is.
            .id(screen == .setup ? -1 : switches)
        }
        // The domain menu (plan F6), then the jobs tray, on every screen: each run the executor makes, and Stop.
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DomainButton(setup: services.setup, switcher: switcher, openSetup: { screen = .setup }, announce: announce)
            }
            ToolbarItem(placement: .primaryAction) { JobsButton(board: services.jobs) }
        }
        // The menu bar's Domain menu acts on the window in front.
        .focusedSceneValue(\.domainMenu, DomainMenuActions(open: { switcher.open() },
                                                           choose: { switcher.choose($0, announce: announce) },
                                                           openSetup: { screen = .setup }))
        .onChange(of: services.setup.generation) {
            // Incident's reading is the window's, kept across screens: another tenant's is dropped whichever screen shows.
            incidentReading.clear()
            if everConnected {
                switches += 1
                // What one screen asked another to open belongs to the old tenant.
                (signaturesPerson, calendarsPerson, classroomCourse, groupsGroup, usersPerson) = (nil, nil, nil, nil, nil)
                (compromisedPerson, phishingMessage, builderCommand, reportsRun) = (nil, nil, nil, nil)
            }
            if services.setup.active != nil { everConnected = true }
        }
        #if DEBUG
        // Snapshots (`SWIFTGAMGUI_TAB=jobs`): the tray over the screen, with made-up runs: nothing runs.
        .sheet(isPresented: $demoJobs) { JobsTray(board: services.jobs).frame(width: 440, height: 520) }
        .task {
            guard ProcessInfo.processInfo.environment["SWIFTGAMGUI_TAB"] == "jobs", Spikes.isRequested else { return }
            Self.showDemoJobs(services.jobs)
            demoJobs = true
        }
        // The domain menu's panel (`domain`), and its warning of what a switch would stop (`domain-warning`: the tray's
        // made-up runs going, then example.org chosen, so nothing is checked).
        .sheet(isPresented: $demoDomain) {
            DomainPanel(setup: services.setup, switcher: switcher, openSetup: {}, announce: { _ in }).frame(width: 380)
        }
        .task(id: services.setup.active) {
            let tab = ProcessInfo.processInfo.environment["SWIFTGAMGUI_TAB"]
            guard tab == "domain" || tab == "domain-warning", Spikes.isRequested, services.setup.active != nil, !demoDomain
            else { return }
            if tab == "domain-warning", let other = DomainMenu.others(services.setup).first {
                Self.showDemoJobs(services.jobs)
                await services.setup.checkAccess(other)
            }
            demoDomain = true
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
