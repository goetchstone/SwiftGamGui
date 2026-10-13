import AppKit
import Directory
import GamEngine
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
        // Quitting mid-onboarding asks first.
        let onboarding = services.onboardChanges
        AppDelegate.interruptible = { onboarding.interruptible }
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
    /// The person Signatures opens on when another screen sends it one.
    @State private var signaturesPerson: String?
    /// The person Calendars opens on when Users sends it one.
    @State private var calendarsPerson: String?
    /// The person Users opens on when another screen sends it one (Reports' Show in Users).
    @State private var usersPerson: String?
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
                          access: services.userAccess, drafts: services.siriDrafts, calendarReads: services.calendarReads,
                          requested: $usersPerson,
                          openSignatures: { email in
                              signaturesPerson = email
                              screen = .signatures
                          }, openCalendars: { email in
                              calendarsPerson = email
                              screen = .calendars
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
                               requested: $signaturesPerson)
                    .navigationTitle("Signatures")
            case .onboard:
                OnboardView(setup: services.setup, directory: services.directory, changes: services.onboardChanges,
                            roles: services.onboardRoles, templates: services.signatureTemplates, hasGam: services.executor != nil)
                    .navigationTitle("Onboard")
            case .offboard:
                OffboardView(setup: services.setup, directory: services.directory, changes: services.offboardChanges)
                    .navigationTitle("Offboard")
            case .reports:
                ReportsView(setup: services.setup, directory: services.directory, usage: services.usage) { email in
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
