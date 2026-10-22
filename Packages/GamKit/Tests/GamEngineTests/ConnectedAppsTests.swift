import Foundation
import Testing
@testable import GamEngine

/// Connected apps (`ConnectedApps`): access said in words with its reach, an AI assistant or agent known by whole words of
/// its name, and the grants grouped by app, AI first, then the broadest reach, then the most people.
@Suite("Connected apps")
struct ConnectedAppsTests {
    @Test func accessIsSaidWithItsReach() {
        #expect(ConnectedApps.describe("https://mail.google.com/") == ("all of Gmail (read, send, delete)", .broad, .mail))
        #expect(ConnectedApps.describe("https://www.googleapis.com/auth/gmail.settings.sharing").reach == .broad, "forwarding and delegates")
        #expect(ConnectedApps.describe("https://www.googleapis.com/auth/drive.readonly") == ("read all of Drive", .some, nil))
        #expect(ConnectedApps.describe("https://www.googleapis.com/auth/admin.directory.user") == ("admin: directory.user", .broad, .admin))
        #expect(ConnectedApps.describe("openid").reach == .little)
    }

    @Test func anAIAssistantIsKnownByWholeWordsOfItsName() {
        for name in ["ChatGPT", "ChatGPT for Gmail", "Read AI Notetaker", "Claude", "Microsoft Copilot", "Inbox Agent", "GPT-4o mailer"] {
            #expect(ConnectedApps.looksLikeAI(name), "\(name)")
        }
        for name in ["Zoom", "Promotion Manager", "Harry Potter Quiz", "Airtable", "Mailchimp", "Painting Pro", ""] {
            #expect(!ConnectedApps.looksLikeAI(name), "\(name)")
        }
    }

    @Test func grantsAreGroupedByAppAIFirstThenReach() {
        let stdout = """
            user,clientId,displayText,anonymous,nativeApp,userKey,scopes
            a@example.com,1-zoom,Zoom,False,False,1,https://www.googleapis.com/auth/calendar.readonly
            b@example.com,1-zoom,Zoom,False,False,2,https://www.googleapis.com/auth/calendar.readonly
            a@example.com,2-sync,Mail Sync,False,False,1,https://mail.google.com/
            b@example.com,3-gpt,ChatGPT,False,False,2,https://www.googleapis.com/auth/gmail.readonly
            """
        let apps = ConnectedApps.apps(ConnectedApps.grants(stdout))
        #expect(apps.map(\.name) == ["ChatGPT", "Mail Sync", "Zoom"])
        #expect(apps[2].users == ["a@example.com", "b@example.com"] && apps[1].reach == .broad && apps[0].looksLikeAI)
        #expect(ConnectedApps.words(apps[2]) == "Zoom: read calendars — 2 people")
        #expect(ConnectedApps.apps(ConnectedApps.grants("user,clientId,displayText,anonymous,nativeApp,userKey,scopes\n")).isEmpty)
    }

    /// Broad access is always one of the kinds the summary counts, and only broad access is.
    @Test func everyBroadScopeHasAKind() {
        let scopes = ["https://mail.google.com/", "gmail.modify", "gmail.settings.sharing", "drive", "cloud-platform", "admin.directory.user",
                      "gmail.readonly", "drive.readonly", "drive.file", "calendar", "openid", "gmail.labels", "something.else"]
        for scope in scopes {
            let described = ConnectedApps.describe(scope)
            #expect((described.reach == .broad) == (described.area != nil), "\(scope)")
        }
    }

    /// The summary counts by code what the list shows, and says it in words: AI by name, broad access by kind, the people,
    /// and the apps only one person granted. It holds no app's name.
    @Test func theSummaryCountsTheApps() {
        let stdout = """
            user,clientId,displayText,anonymous,nativeApp,userKey,scopes
            a@example.com,1-zoom,Zoom,False,False,1,https://www.googleapis.com/auth/calendar.readonly
            B@example.com,1-zoom,Zoom,False,False,2,https://www.googleapis.com/auth/calendar.readonly
            c@example.com,1-zoom,Zoom,False,False,3,https://www.googleapis.com/auth/calendar.readonly
            a@example.com,2-sync,Mail Sync,False,False,1,https://mail.google.com/ https://www.googleapis.com/auth/drive
            b@example.com,3-gpt,ChatGPT,False,False,2,https://www.googleapis.com/auth/gmail.readonly
            d@example.com,4-agent,Inbox Agent,False,False,4,https://www.googleapis.com/auth/gmail.settings.sharing
            c@example.com,5-admin,Directory Sync,False,False,3,https://www.googleapis.com/auth/admin.directory.user
            a@example.com,5-admin,Directory Sync,False,False,1,https://www.googleapis.com/auth/admin.directory.user
            """
        let apps = ConnectedApps.apps(ConnectedApps.grants(stdout))
        #expect(apps.first { $0.name == "Mail Sync" }?.areas == [.mail, .drive])
        let summary = ConnectedApps.Summary(apps)
        #expect(summary.apps == 5 && summary.people == 4 && summary.ai == 2 && summary.aiPeople == 2, "addresses aside, case aside")
        #expect(summary.broad == 3 && summary.aiBroad == 1 && summary.areas == [.mail: 1, .drive: 1, .forwarding: 1, .admin: 1])
        #expect(summary.onePerson == 3 && summary.onePersonAI == 2 && summary.onePersonBroad == 2 && summary.mostPeople == 3)
        #expect(summary.sentences == [
            "4 people have given 5 apps access.",
            "2 apps look like an AI assistant or agent by name, granted by 2 people; 1 with broad access.",
            "3 apps have broad access: 1 to all of Gmail or reading and changing mail, 1 to Gmail forwarding and delegates, "
                + "1 to all of Drive, 1 to admin access.",
            "3 apps were granted by one person only, among them 2 that look like AI and 2 with broad access.",
            "At most 3 people granted any one app.",
        ])
        #expect(ConnectedApps.Summary([]).sentences == ["No account has given an app access."])
    }
}
