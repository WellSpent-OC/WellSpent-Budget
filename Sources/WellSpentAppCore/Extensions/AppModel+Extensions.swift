import Foundation
import WellSpentCrypto
import WellSpentExtensionKit
import WellSpentModel
import WellSpentStore

/// What the app's model does for an extension: its records, and what it adds
/// to the app's own screens.
public extension AppModel {
    /// Sets what an extension adds, or nil for nothing. Its link choices
    /// reach the entry sheet here, so the sheet needs no extension of its own.
    func install(_ slots: (any ExtensionSlots)?) {
        setExtensionSlots(slots)
        linkChoices = { [weak self] group in
            guard let offered = self?.extensionSlots?.linkChoices(in: group.uuid.uuidString) else { return nil }
            return EntryLinkChoices(label: offered.label, choices: offered.choices.compactMap { choice in
                UUID(uuidString: choice.id).map { .init(id: RecordID($0), name: choice.name) }
            })
        }
    }

    func extensionRecords<V>(in group: GroupID, extensionID: String, kind: String) -> [ExtensionRecord<V>] {
        (try? store.extensionRecords(in: group, extensionID: extensionID, kind: kind)) ?? []
    }

    /// The record's ID, or nil when this person may not change the group's
    /// records, or it could not be saved. Below Manage, the server would refuse it.
    func save<V>(_ record: ExtensionRecord<V>) -> RecordID? {
        guard mayManageEntries(record.groupID) else { return nil }
        do {
            try store.save(record)
            changed()
            return record.id
        } catch {
            errorMessage = String(describing: error)
            return nil
        }
    }

    /// Who else is in the group, by the names they gave it, for "In Home, shared
    /// with Leslie". Nil for a group of one.
    func sharingLine(of group: GroupID) -> String? {
        guard isShared(group) else { return nil }
        let others = ((try? store.members(in: group)) ?? [:]).keys.filter { $0 != me() }
        let names = others.compactMap { memberName($0, in: group) }.sorted()
        return names.isEmpty ? SharingWords.shared : SharingWords.sharedWith(names.joined(separator: ", "))
    }

    enum SharingWords {
        /// Placeholder words until the word check.
        public static let shared = "Shared"
        public static func sharedWith(_ names: String) -> String { "Shared with \(names)" }
    }
}
