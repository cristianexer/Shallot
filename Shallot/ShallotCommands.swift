import Domain
import Features
import SwiftUI

/// Hardware-keyboard shortcuts, for iPad and for a Mac keyboard on iPhone.
///
/// Declared as `Commands` rather than as hidden buttons so they also appear in
/// the ⌘ shortcut overlay, which is where an iPad user goes looking for them.
struct ShallotCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                model.section = .browser
                model.browser.newTab()
            }
            .keyboardShortcut("t", modifiers: .command)

            Button("Close Tab") {
                guard let id = model.browser.session.activeTabID else { return }
                model.browser.closeTab(id)
            }
            .keyboardShortcut("w", modifiers: .command)
        }

        CommandMenu("Browse") {
            Button("Open Address…") {
                model.section = .browser
                model.browser.syncAddressField()
                model.browser.isEditingAddress = true
            }
            .keyboardShortcut("l", modifiers: .command)

            Button("Reload") { model.browser.reload() }
                .keyboardShortcut("r", modifiers: .command)

            Divider()

            Button("New Identity") {
                Task { await model.newIdentity() }
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])

            Button("New Circuit") {
                Task { await model.monitor.requestNewCircuit() }
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])

            Divider()

            Button("Save to Favourites") { model.browser.toggleFavourite() }
                .keyboardShortcut("d", modifiers: .command)
        }

        CommandMenu("View") {
            ForEach(AppSection.allCases) { section in
                Button(section.title) { model.section = section }
                    .keyboardShortcut(shortcut(for: section), modifiers: .command)
            }
        }
    }

    private func shortcut(for section: AppSection) -> KeyEquivalent {
        switch section {
        case .browser: "1"
        case .favourites: "2"
        case .monitor: "3"
        case .settings: "4"
        }
    }
}
