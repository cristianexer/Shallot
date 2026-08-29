import SwiftUI

/// The four top-level destinations.
public enum AppSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case browser
    case favourites
    case monitor
    case settings

    public var id: String { rawValue }

    /// The sidebar title on iPad. The compact tab bar is icon-only, so these
    /// double as the VoiceOver labels there — which is why they are proper
    /// words rather than abbreviations.
    public var title: String {
        switch self {
        case .browser: "Browse"
        case .favourites: "Favourites"
        case .monitor: "Monitor"
        case .settings: "Settings"
        }
    }

    public var symbol: String {
        switch self {
        case .browser: "globe"
        case .favourites: "bookmark"
        case .monitor: "waveform.path.ecg"
        case .settings: "gearshape"
        }
    }

    /// Spoken description for VoiceOver, beyond the bare title.
    public var accessibilityHint: String {
        switch self {
        case .browser: "Open pages over Tor"
        case .favourites: "Sites saved on this device"
        case .monitor: "Live circuit, bandwidth and security events"
        case .settings: "Security level, connection and privacy options"
        }
    }
}
