import Foundation
import Testing

@testable import BrowserEngine
@testable import Domain
@testable import Monitoring

/// Proves, structurally, that Shallot has nowhere to report you to.
///
/// A runtime egress test can only observe the endpoints a particular run
/// happened to touch. This scans the shipping source instead and asserts that
/// the code to make an outbound request does not exist outside the two places
/// it is allowed to: `TorKit`, which talks to Tor over loopback, and
/// `BrowserEngine`, which is the browser.
///
/// The scan reads the repository through `#filePath`. When the sources are not
/// present — an archived build, for instance — the tests skip rather than
/// pretending to have verified something.
@Suite("No telemetry")
struct NoTelemetryTests {
    /// The `Packages/ShallotCore/Sources` directory, found relative to this file.
    static var sourceRoot: URL? {
        // …/Shallot/ShallotTests/Security/NoTelemetryTests.swift
        let thisFile = URL(fileURLWithPath: #filePath)
        let repository = thisFile
            .deletingLastPathComponent()   // Security
            .deletingLastPathComponent()   // ShallotTests
            .deletingLastPathComponent()   // repository root
        let sources = repository.appending(path: "Packages/ShallotCore/Sources")
        return FileManager.default.fileExists(atPath: sources.path) ? sources : nil
    }

    static func swiftFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// Modules allowed to open a socket at all.
    ///
    /// `TorKit` dials Tor's control port on 127.0.0.1; `BrowserEngine`
    /// configures the proxy the web view uses. Nothing else has any business
    /// with the network.
    static let modulesAllowedToNetwork: Set<String> = ["TorKit", "BrowserEngine"]

    @Test("No analytics or crash-reporting SDK is present anywhere in the sources")
    func noAnalyticsSDKs() throws {
        let root = try #require(Self.sourceRoot, "sources not available in this build")
        // Names, not behaviours: if one of these ever appears, someone added a
        // dependency that phones home with URLs and identifiers in it.
        let forbidden = [
            "FirebaseAnalytics", "GoogleAnalytics", "Crashlytics", "Sentry",
            "Bugsnag", "Mixpanel", "Amplitude", "AppsFlyer", "Adjust",
            "Segment", "Datadog", "NewRelic", "Instabug", "TelemetryDeck",
        ]
        for file in Self.swiftFiles(under: root) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for name in forbidden {
                #expect(!text.contains("import \(name)"), "\(file.lastPathComponent) imports \(name)")
            }
        }
    }

    @Test("Only TorKit and BrowserEngine contain any networking at all")
    func networkingIsConfinedToTwoModules() throws {
        let root = try #require(Self.sourceRoot, "sources not available in this build")
        // Every way a Swift file can start an outbound connection.
        let networkingAPIs = [
            "URLSession", "NWConnection", "NWBrowser", "CFStream",
            "dataTask", "downloadTask", "uploadTask", "NSURLConnection",
        ]
        for file in Self.swiftFiles(under: root) {
            let module = file.pathComponents
                .drop { $0 != "Sources" }
                .dropFirst()
                .first ?? ""
            guard !Self.modulesAllowedToNetwork.contains(String(module)) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for api in networkingAPIs {
                #expect(
                    !text.contains(api),
                    "\(module)/\(file.lastPathComponent) uses \(api); only \(Self.modulesAllowedToNetwork.sorted().joined(separator: " and ")) may reach the network"
                )
            }
        }
    }

    @Test("The Monitor computes everything locally and stores nothing")
    func monitorIsLocalOnly() throws {
        let root = try #require(Self.sourceRoot, "sources not available in this build")
        let monitoring = root.appending(path: "Monitoring")
        for file in Self.swiftFiles(under: monitoring) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("URLSession"))
            // The event log is explicitly in-memory; a write here would be a
            // browsing history under another name.
            #expect(!text.contains("FileManager"))
            #expect(!text.contains("UserDefaults"))
        }
    }

    @Test("Nothing writes browsing state to UserDefaults")
    func noUserDefaults() throws {
        let root = try #require(Self.sourceRoot, "sources not available in this build")
        for file in Self.swiftFiles(under: root) {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                !text.contains("UserDefaults"),
                "\(file.lastPathComponent) uses UserDefaults, which is unencrypted and survives the session"
            )
        }
    }

    @Test("The event log lives in memory and is bounded")
    func eventLogIsBounded() {
        var log = EventLog(capacity: 5)
        for index in 0..<50 {
            log.append(SecurityEvent(kind: .info, message: "event \(index)"))
        }
        #expect(log.events.count == 5)
        // Newest first, so the terminal view shows what just happened.
        #expect(log.events.first?.message == "event 49")
    }
}
