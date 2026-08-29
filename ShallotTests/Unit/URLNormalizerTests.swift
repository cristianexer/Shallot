import Foundation
import Testing

@testable import Domain

@Suite("Address bar interpretation")
struct URLNormalizerTests {
    @Test("A bare host becomes an https URL")
    func bareHostBecomesHTTPS() {
        #expect(URLNormalizer.resolve("example.org") == .url(URL(string: "https://example.org")!))
    }

    @Test("Words with spaces are a search, not a host")
    func wordsBecomeSearch() {
        #expect(URLNormalizer.resolve("how does tor work") == .search("how does tor work"))
    }

    @Test("A single word with no dot is a search")
    func singleWordIsSearch() {
        #expect(URLNormalizer.resolve("securedrop") == .search("securedrop"))
    }

    @Test("A numeric 'host' is a search, not a hostname")
    func numbersAreSearch() {
        #expect(URLNormalizer.resolve("3.14159") == .search("3.14159"))
    }

    @Test("http is upgraded when HTTPS-only is on")
    func upgradesHTTP() {
        #expect(
            URLNormalizer.resolve("http://example.org/page", httpsOnly: true)
                == .url(URL(string: "https://example.org/page")!)
        )
    }

    @Test("http is left alone when HTTPS-only is off")
    func leavesHTTPWhenAllowed() {
        #expect(
            URLNormalizer.resolve("http://example.org/page", httpsOnly: false)
                == .url(URL(string: "http://example.org/page")!)
        )
    }

    @Test("Onion addresses default to http and are never upgraded")
    func onionStaysHTTP() {
        // Onion services authenticate and encrypt via the address itself, and
        // most never obtained a certificate for 443 — upgrading would break them.
        let address = "\(String(repeating: "a", count: 56)).onion"
        guard case .url(let url) = URLNormalizer.resolve(address, httpsOnly: true) else {
            Issue.record("expected a URL")
            return
        }
        #expect(url.scheme == "http")
        #expect(url.host() == address)
    }

    @Test("An explicit http onion URL is not upgraded")
    func explicitOnionNotUpgraded() {
        let address = "\(String(repeating: "b", count: 56)).onion"
        guard case .url(let url) = URLNormalizer.resolve("http://\(address)/x", httpsOnly: true) else {
            Issue.record("expected a URL")
            return
        }
        #expect(url.scheme == "http")
    }

    @Test("Malformed onion addresses are refused, never loaded")
    func rejectsInvalidOnion() {
        // A v2-length address. Tor removed v2 support, and a 16-character
        // address is a plausible typo-squat of a real service.
        #expect(URLNormalizer.resolve("expyuzz4wqqyqhjn.onion") == .invalidOnion("expyuzz4wqqyqhjn.onion"))
    }

    @Test("Onion addresses with non-base32 characters are refused")
    func rejectsBadAlphabet() {
        let bad = String(repeating: "a", count: 55) + "1"
        #expect(URLNormalizer.resolve("\(bad).onion") == .invalidOnion("\(bad).onion"))
    }

    @Test("Dangerous schemes are never handed to the web view", arguments: [
        "javascript:alert(1)",
        "file:///etc/passwd",
        "data:text/html,<script>1</script>",
        "shallot://open",
    ])
    func refusesDangerousSchemes(_ input: String) {
        let resolution = URLNormalizer.resolve(input)
        #expect(resolution == .search(input), "\(input) must not resolve to a loadable URL")
    }

    @Test("isLoadable rejects everything the policy would refuse")
    func isLoadableIsStrict() {
        #expect(URLNormalizer.isLoadable(URL(string: "https://example.org")!))
        #expect(!URLNormalizer.isLoadable(URL(string: "file:///tmp/x")!))
        #expect(!URLNormalizer.isLoadable(URL(string: "https://")!))
        #expect(!URLNormalizer.isLoadable(URL(string: "http://expyuzz4wqqyqhjn.onion")!))
    }

    @Test("Empty and whitespace input resolve to nothing")
    func emptyInput() {
        #expect(URLNormalizer.resolve("") == .empty)
        #expect(URLNormalizer.resolve("   \n ") == .empty)
    }

    @Test("localhost is treated as a host")
    func localhostIsHost() {
        #expect(URLNormalizer.looksLikeHost("localhost"))
    }

    @Test("httpsUpgrade only applies to non-onion http URLs")
    func upgradeScope() {
        #expect(URLNormalizer.httpsUpgrade(for: URL(string: "http://example.org")!)?.scheme == "https")
        #expect(URLNormalizer.httpsUpgrade(for: URL(string: "https://example.org")!) == nil)
        let onion = URL(string: "http://\(String(repeating: "c", count: 56)).onion")!
        #expect(URLNormalizer.httpsUpgrade(for: onion) == nil)
    }
}

@Suite("Onion address validation")
struct OnionAddressTests {
    @Test("A 56-character base32 address is valid v3")
    func validV3() {
        #expect(OnionAddress.isValidV3("\(String(repeating: "a", count: 56)).onion"))
    }

    @Test("Subdomains of an onion service are valid")
    func subdomainsAllowed() {
        #expect(OnionAddress.isValidV3("www.\(String(repeating: "a", count: 56)).onion"))
    }

    @Test("Case is not significant")
    func caseInsensitive() {
        #expect(OnionAddress.isValidV3("\(String(repeating: "A", count: 56)).ONION"))
    }

    @Test("Non-onion hosts are neither onion nor rejected")
    func nonOnion() {
        #expect(!OnionAddress.isOnion("example.org"))
        #expect(!OnionAddress.isRejectedOnion("example.org"))
    }

    @Test("Wrong length is rejected", arguments: [16, 55, 57])
    func wrongLength(_ length: Int) {
        #expect(!OnionAddress.isValidV3("\(String(repeating: "a", count: length)).onion"))
    }
}
