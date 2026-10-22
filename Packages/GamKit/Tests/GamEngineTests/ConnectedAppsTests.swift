import Foundation
import Testing
@testable import GamEngine

/// Connected apps (`ConnectedApps`): access said in words with its reach, an AI assistant or agent known by whole words of
/// its name, and the grants grouped by app, AI first, then the broadest reach, then the most people.
@Suite("Connected apps")
struct ConnectedAppsTests {
    @Test func accessIsSaidWithItsReach() {
        #expect(ConnectedApps.describe("https://mail.google.com/") == ("all of Gmail (read, send, delete)", .broad))
        #expect(ConnectedApps.describe("https://www.googleapis.com/auth/gmail.settings.sharing").reach == .broad, "forwarding and delegates")
        #expect(ConnectedApps.describe("https://www.googleapis.com/auth/drive.readonly") == ("read all of Drive", .some))
        #expect(ConnectedApps.describe("https://www.googleapis.com/auth/admin.directory.user") == ("admin: directory.user", .broad))
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
}
