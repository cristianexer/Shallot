import Domain
import Foundation
import Observation
import SwiftData

/// `SettingsStoring` over SwiftData, saving on every change.
@MainActor
@Observable
public final class SwiftDataSettingsStore: SettingsStoring {
    public private(set) var settings: AppSettings = .default
    public private(set) var needsRelaunchForBridges = false
    public private(set) var hasSeededDefaults = false

    @ObservationIgnored private let context: ModelContext
    @ObservationIgnored private var appliedBridges: BridgeConfig = .disabled

    public init(container: ModelContainer) {
        self.context = ModelContext(container)
        reload()
    }

    public func reload() {
        guard let record = fetchRecord() else {
            settings = .default
            appliedBridges = settings.bridges
            needsRelaunchForBridges = false
            return
        }
        settings = record.decoded()
        appliedBridges = record.decodedAppliedBridges() ?? settings.bridges
        needsRelaunchForBridges = settings.bridges != appliedBridges
        hasSeededDefaults = record.hasSeededDefaults
    }

    public func update(_ mutate: (inout AppSettings) -> Void) {
        mutate(&settings)
        needsRelaunchForBridges = settings.bridges != appliedBridges
        persist()
    }

    public func markBridgesApplied() {
        appliedBridges = settings.bridges
        needsRelaunchForBridges = false
        persist()
    }

    public func markDefaultsSeeded() {
        hasSeededDefaults = true
        persist()
    }

    private func fetchRecord() -> SettingsRecord? {
        var descriptor = FetchDescriptor<SettingsRecord>()
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func persist() {
        guard let payload = try? JSONEncoder().encode(settings) else { return }
        let appliedPayload = try? JSONEncoder().encode(appliedBridges)
        if let record = fetchRecord() {
            record.payload = payload
            record.appliedBridgePayload = appliedPayload
            record.hasSeededDefaults = hasSeededDefaults
        } else {
            context.insert(
                SettingsRecord(
                    payload: payload,
                    appliedBridgePayload: appliedPayload,
                    hasSeededDefaults: hasSeededDefaults
                )
            )
        }
        // A failed settings save is not worth crashing over; the in-memory
        // value is already correct and the next change will try again.
        try? context.save()
    }
}
