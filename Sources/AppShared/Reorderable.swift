import Foundation

/// Order-mutation primitive used by both the channel-grid reorder and
/// the device-sidebar reorder. The actual UI sits on top: dragging a
/// jiggling tile onto another calls into a store method that funnels
/// through `moveItem(id:before:)` and then persists.
///
/// Pure logic, no SwiftUI dependency — keeps the reorder math testable
/// with Swift Testing `@Test`s.
public enum ReorderList {
    /// Move the element identified by `sourceID` to immediately before
    /// `targetID` within `order`. Mutates `order` in place. Returns true
    /// if the move actually changed the order, false if it was a no-op
    /// (source == target, or source not in order, or target not in
    /// order). Both source and target must already be present.
    public static func move<ID: Hashable>(
        sourceID: ID,
        before targetID: ID,
        in order: inout [ID]
    ) -> Bool {
        guard sourceID != targetID,
              let sourceIndex = order.firstIndex(of: sourceID),
              let _ = order.firstIndex(of: targetID)
        else { return false }
        let item = order.remove(at: sourceIndex)
        guard let newTargetIndex = order.firstIndex(of: targetID) else {
            // Target was removed during the remove(at:); restore and bail.
            order.insert(item, at: sourceIndex)
            return false
        }
        order.insert(item, at: newTargetIndex)
        return true
    }

    /// Seed an order array from a natural ordering when nothing is
    /// persisted yet, then append any items present in `natural` but
    /// missing from `order` (e.g. a new channel that the user has never
    /// touched). Used by both the channel grid and the device sidebar
    /// to make sure the canonical "list to display" includes every item
    /// the underlying source knows about.
    public static func reconciled<ID: Hashable>(
        order: [ID],
        natural: [ID]
    ) -> [ID] {
        if order.isEmpty { return natural }
        let known = Set(order)
        let missing = natural.filter { !known.contains($0) }
        return order + missing
    }
}
