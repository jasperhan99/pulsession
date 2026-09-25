import Foundation
import Testing
@testable import Pulse

@Suite("Pulse navigation links")
struct PulseLinkTests {
    @Test("Added-account separators are encoded as path data, not fragments")
    func roundTrip() {
        let account = AccountKey(.claudeCode, slot: "work")
        let link = PulseLink.account(account)
        #expect(link.url.absoluteString == "pulsession://account/claudeCode%23work")
        #expect(PulseLink(url: link.url) == link)
        #expect(PulseLink(url: PulseLink.settings.url) == .settings)
        #expect(PulseLink(url: PulseLink.integrations.url) == .integrations)
    }

    @Test("Malformed or action-bearing URLs are rejected", arguments: [
        "https://account/codex", "pulsession://account/codex#work", "pulsession://account/codex%23",
        "pulsession://account/codex/extra", "pulsession://account/codex?refresh=true", "pulsession://account/unknown",
        "pulsession://user@account/codex", "pulsession://account:80/codex", "pulsession://settings/extra",
        "pulsession://refresh/codex", "pulsession://account/claudeCode%23work%23other"
    ])
    func rejects(_ value: String) throws {
        #expect(PulseLink(url: try #require(URL(string: value))) == nil)
    }

    @MainActor
    @Test("Navigation selects only existing accounts and repeated links still clear search")
    func selectsExistingAccounts() {
        let navigation = SettingsNavigation()
        let account = AccountKey(.codex, slot: "work")
        navigation.open(.account(account), accounts: [account])
        #expect(navigation.pane == .account(account))
        let request = navigation.requestID
        navigation.open(.account(account), accounts: [account])
        #expect(navigation.requestID != request)
        navigation.open(.integrations, accounts: [])
        navigation.open(.account(account), accounts: [])
        #expect(navigation.pane == .integrations)
    }
}
