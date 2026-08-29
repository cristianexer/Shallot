import Foundation

extension Array {
    /// Moves the elements at `source` so they land before `destination`.
    ///
    /// SwiftUI ships an equivalent on `MutableCollection`, but `Domain` stays
    /// free of UI frameworks, so the drag-to-reorder semantics are implemented
    /// here and unit-tested directly.
    public mutating func moveElements(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.map { self[$0] }
        // Removing shifts everything after it, so the insertion point must be
        // reduced by however many removed elements sat before it.
        let removedBeforeDestination = source.filter { $0 < destination }.count
        for index in source.sorted(by: >) { remove(at: index) }
        let insertionIndex = Swift.max(0, Swift.min(count, destination - removedBeforeDestination))
        insert(contentsOf: moving, at: insertionIndex)
    }
}
