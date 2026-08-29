import Foundation
import Testing

@testable import Domain

@Suite("Security levels")
struct SecurityLevelTests {
    @Test("Only Safest turns JavaScript off")
    func javaScriptMapping() {
        #expect(SecurityLevel.standard.allowsJavaScript)
        #expect(SecurityLevel.safer.allowsJavaScript)
        #expect(!SecurityLevel.safest.allowsJavaScript)
    }

    @Test("Standard is the only level without strict blocking")
    func strictBlockingMapping() {
        #expect(!SecurityLevel.standard.usesStrictBlocking)
        #expect(SecurityLevel.safer.usesStrictBlocking)
        #expect(SecurityLevel.safest.usesStrictBlocking)
    }

    @Test("Every level explains itself, and Safest warns about breakage")
    func explanations() {
        for level in SecurityLevel.allCases {
            #expect(!level.explanation.isEmpty)
        }
        #expect(SecurityLevel.safest.explanation.lowercased().contains("break"))
    }
}

@Suite("Settings and per-site exceptions")
struct AppSettingsTests {
    @Test("Defaults are the private choice")
    func defaultsArePrivate() {
        let settings = AppSettings.default
        #expect(settings.httpsOnly)
        #expect(settings.blockWebRTC)
        #expect(settings.blockWebAuthn)
        #expect(settings.blockWebTransport)
        #expect(settings.blockDNSPrefetch)
        #expect(settings.isolateCircuitPerTab)
        #expect(settings.clearOnExit)
        #expect(settings.searchEngine == .duckDuckGoOnion)
        #expect(settings.siteExceptions.isEmpty)
    }

    @Test("An exception applies only to the host it was granted for")
    func exceptionScope() {
        var settings = AppSettings.default
        settings.setException(.webRTC, on: "meet.example", enabled: true)
        #expect(settings.allows(.webRTC, on: "meet.example"))
        #expect(!settings.allows(.webRTC, on: "other.example"))
        #expect(!settings.allows(.webAuthn, on: "meet.example"))
        #expect(!settings.allows(.webRTC, on: nil))
    }

    @Test("Granting twice does not duplicate, and revoking removes")
    func exceptionIdempotence() {
        var settings = AppSettings.default
        settings.setException(.webAuthn, on: "bank.example", enabled: true)
        settings.setException(.webAuthn, on: "bank.example", enabled: true)
        #expect(settings.siteExceptions.count == 1)
        settings.setException(.webAuthn, on: "bank.example", enabled: false)
        #expect(settings.siteExceptions.isEmpty)
    }

    @Test("A JavaScript exception softens Safest for that host only")
    func javaScriptException() {
        var settings = AppSettings.default
        settings.securityLevel = .safest
        settings.setException(.javaScript, on: "app.example", enabled: true)
        #expect(settings.effectiveSecurityLevel(for: "app.example", tabOverride: nil) == .safer)
        #expect(settings.effectiveSecurityLevel(for: "other.example", tabOverride: nil) == .safest)
    }

    @Test("A tab override wins over everything")
    func tabOverrideWins() {
        var settings = AppSettings.default
        settings.securityLevel = .safest
        #expect(settings.effectiveSecurityLevel(for: "a.example", tabOverride: .standard) == .standard)
    }

    @Test("Settings survive a JSON round trip")
    func roundTrip() throws {
        var settings = AppSettings.default
        settings.securityLevel = .safest
        settings.setException(.webTransport, on: "x.example", enabled: true)
        settings.bridges = BridgeConfig(isEnabled: true, transport: .obfs4, lines: [])
        let data = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: data) == settings)
    }
}

@Suite("Search engines")
struct SearchEngineTests {
    @Test("The default search engine is an onion service")
    func defaultIsOnion() throws {
        let url = try #require(SearchEngine.duckDuckGoOnion.searchURL(for: "tor"))
        #expect(url.host()?.hasSuffix(".onion") == true)
        #expect(url.query()?.contains("q=tor") == true)
    }

    @Test("Queries needing escaping produce a valid URL")
    func escapesQuery() throws {
        let url = try #require(SearchEngine.duckDuckGo.searchURL(for: "a & b?c=d"))
        #expect(url.absoluteString.contains("q="))
        #expect(!url.absoluteString.contains(" "))
    }
}

@Suite("Favourites")
struct FavouriteTests {
    @Test("Onion favourites are detected and their address is elided")
    func onionDisplay() {
        let address = String(repeating: "a", count: 56)
        let favourite = Favourite(title: "SecureDrop", url: URL(string: "http://\(address).onion")!)
        #expect(favourite.isOnion)
        #expect(favourite.displayURL.hasSuffix("…onion"))
        #expect(favourite.displayURL.count < address.count)
    }

    @Test("A short clearnet host is shown in full")
    func clearnetDisplay() {
        let favourite = Favourite(title: "BBC News", url: URL(string: "https://bbc.co.uk/news")!)
        #expect(!favourite.isOnion)
        #expect(favourite.displayURL == "bbc.co.uk")
    }

    @Test("Monograms come from the title", arguments: [
        ("BBC News", "BN"), ("SecureDrop", "SE"), ("x", "X"),
    ])
    func monograms(_ input: (title: String, expected: String)) {
        let favourite = Favourite(title: input.title, url: URL(string: "https://example.org")!)
        #expect(favourite.monogram == input.expected)
    }
}

@Suite("Tor runtime state")
struct TorRuntimeStateTests {
    @Test("Only .running may carry traffic — this is the kill switch")
    func killSwitchPredicate() {
        #expect(TorRuntimeState.running.canCarryTraffic)
        #expect(!TorRuntimeState.off.canCarryTraffic)
        #expect(!TorRuntimeState.starting(progress: 99).canCarryTraffic)
        #expect(!TorRuntimeState.stopping.canCarryTraffic)
        #expect(!TorRuntimeState.failed(reason: "x").canCarryTraffic)
    }

    @Test("Progress reflects the state")
    func progress() {
        #expect(TorRuntimeState.starting(progress: 42).progress == 42)
        #expect(TorRuntimeState.running.progress == 100)
        #expect(TorRuntimeState.off.progress == 0)
        #expect(TorRuntimeState.failed(reason: "x").progress == 0)
    }
}

@Suite("Bandwidth samples")
struct BandwidthSampleTests {
    @Test("Rates divide by the interval")
    func rates() {
        let sample = BandwidthSample(downBytes: 2048, upBytes: 1024, interval: 2)
        #expect(sample.downKilobytesPerSecond == 1)
        #expect(sample.upKilobytesPerSecond == 0.5)
    }

    @Test("A zero interval does not divide by zero")
    func zeroInterval() {
        let sample = BandwidthSample(downBytes: 100, upBytes: 100, interval: 0)
        #expect(sample.downKilobytesPerSecond == 0)
        #expect(sample.upKilobytesPerSecond == 0)
    }
}

@Suite("Reordering")
struct ReorderTests {
    @Test("Moving down lands after the removal shift")
    func moveDown() {
        var items = [0, 1, 2, 3, 4]
        items.moveElements(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        #expect(items == [1, 2, 0, 3, 4])
    }

    @Test("Moving up lands before the destination")
    func moveUp() {
        var items = [0, 1, 2, 3, 4]
        items.moveElements(fromOffsets: IndexSet(integer: 4), toOffset: 1)
        #expect(items == [0, 4, 1, 2, 3])
    }

    @Test("Moving several at once keeps their relative order")
    func moveMultiple() {
        var items = [0, 1, 2, 3, 4]
        items.moveElements(fromOffsets: IndexSet([0, 2]), toOffset: 5)
        #expect(items == [1, 3, 4, 0, 2])
    }
}
