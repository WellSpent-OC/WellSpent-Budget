import Foundation
import WellSpentCrypto
import WellSpentModel
import WellSpentStore
import WellSpentSync

/// What one sync round does with each group, decided before anything is
/// sent. Pure: it reads this Mac's database and the server's list and
/// changes neither, so every rule can be tested on its own.
enum GroupAction: Equatable, Sendable {
    /// Listed on the server and held here: take in, then send.
    case sync(GroupID, level: AccessLevel)
    /// Made here and not on the server yet: create it there, then sync.
    case create(GroupID)
    /// On the server, not here yet, with its import key: make a stand-in
    /// here, then sync to fill it.
    case placeholder(ServerGroup)
    /// On the server with no import key yet, because its founder has not
    /// updated. Nothing is made here until they have, not even for the
    /// founder's own second device: only the device that holds the old
    /// statements' key may give the group its key.
    case waitForFounder(GroupID)
    /// Made here before the switch by this person, and not yet sent up:
    /// send everything once and check it arrived (`ReadableMove`).
    case moveAsCreator(GroupID, level: AccessLevel)
    /// Joined before the switch, and its founder has since sent it up: take
    /// their copy and send this person's own entries, once.
    case adopt(ServerGroup)
    /// Deleted here, with its delete queued: sent for everyone by someone
    /// who may, and otherwise this person leaves the group.
    case sendDelete(GroupID, level: AccessLevel)
    /// Deleted here by a member who may not delete it for everyone: edits
    /// saved before the delete go once, then this person leaves the group,
    /// so a new invite can bring it back.
    case leave(GroupID, level: AccessLevel)
    /// Deleted here only, with edits saved before that still queued: they
    /// go once, and the queue is then dropped.
    case letGo(GroupID, level: AccessLevel)
    /// Deleted here and never on the server: its queue has nobody to go to.
    case dropQueue(GroupID)
    /// Hidden here after this person was removed, and listed again: they
    /// were added back, on another device or by a new invite. Shown again,
    /// and taken in from the start.
    case rejoin(ServerGroup)
    /// No longer listed for this person, who was removed or left elsewhere:
    /// hidden here, with what this Mac knew of it kept.
    case removed(GroupID)
    /// Founded by this account, and missing from the server's list. Nobody
    /// can remove a group's founder, so the server has lost it, perhaps to a
    /// restore from an older backup. Nothing is hidden, deleted or sent;
    /// the app says so.
    case missingOnServer(GroupID)
}

enum SyncPlan {
    /// One action per group that needs one, in a fixed order: the server's
    /// list first, then groups only this Mac holds.
    static func actions(store: Store, listed: [ServerGroup], me: UserID) throws -> [GroupAction] {
        var actions: [GroupAction] = []
        let known = Dictionary(uniqueKeysWithValues: try store.serverGroups().map { ($0.groupID, $0) })
        let listedIDs = Set(listed.map(\.id))

        for group in listed {
            if let local = try store.group(group.id) {
                if let action = try heldAction(local, listed: group, known: known[group.id], me: me, store: store) {
                    actions.append(action)
                }
            } else if !group.deleted {
                actions.append(group.importKey.isEmpty ? .waitForFounder(group.id) : .placeholder(group))
            }
        }
        for local in try store.groups(includeDeleted: true) where !listedIDs.contains(local.id) {
            if let action = try unlistedAction(local, known: known[local.id], me: me, store: store) {
                actions.append(action)
            }
        }
        return actions
    }

    /// A group the server lists and this Mac holds.
    private static func heldAction(_ local: BudgetGroup, listed: ServerGroup, known: ServerGroupInfo?,
                                   me: UserID, store: Store) throws -> GroupAction? {
        // From before the switch and not sent up yet. Deleted here or not:
        // the server may still hold it as live.
        if known?.removedAt != nil {
            // Listed again after this person was removed: added back.
            return listed.deleted ? nil : .rejoin(listed)
        }
        if try store.hasSealedHistory(local.id), known?.movedAt == nil {
            if listed.founderID == me { return .moveAsCreator(local.id, level: listed.level) }
            return listed.importKey.isEmpty ? .waitForFounder(local.id) : .adopt(listed)
        }
        guard local.isDeleted else { return .sync(local.id, level: listed.level) }
        if try store.groupDeleteIsQueued(local.id) { return .sendDelete(local.id, level: listed.level) }
        // Deleted here by a member who may not delete it for everyone, who
        // asked to leave it instead. Only a delete made with readable sync
        // asks: one the sealed app made hid the group on that Mac only, and
        // stays that way. The founder cannot leave, so their copy is only
        // hidden.
        if try store.leaveRequested(local.id), !listed.deleted, listed.founderID != me {
            return .leave(local.id, level: listed.level)
        }
        if try store.outboxCount(in: local.id) > 0 { return .letGo(local.id, level: listed.level) }
        return nil
    }

    /// A group this Mac holds that the server does not list for this person.
    private static func unlistedAction(_ local: BudgetGroup, known: ServerGroupInfo?, me: UserID,
                                       store: Store) throws -> GroupAction? {
        // Sent up before, or listed before: this person is no longer in it,
        // unless they founded it, which nobody can undo.
        if let known {
            if known.founderID == me { return .missingOnServer(local.id) }
            // Noted even when deleted here already, so that if the group is
            // listed again it comes back (`.rejoin`) instead of being left a
            // second time: when they left it on another device, say, or this
            // device's leave went through and its reply was lost.
            if known.removedAt == nil { return .removed(local.id) }
            return try store.outboxCount(in: local.id) > 0 ? .dropQueue(local.id) : nil
        }
        // From before the switch, and not on this account's list: removed
        // before the switch, or another account's. Left as it is: hiding it
        // would drop what is queued, and nothing can be sent to it.
        if try store.hasSealedHistory(local.id) { return nil }
        if local.isDeleted {
            return try store.outboxCount(in: local.id) > 0 ? .dropQueue(local.id) : nil
        }
        return .create(local.id)
    }
}
