// The Mac's lock card and Pick what stays open. The words and choices are
// the shared screens' (LockScreens); this is layout only.
#if canImport(SwiftUI) && os(macOS)
import SwiftUI
import WellSpentCrypto
import WellSpentPlans

/// In place of a locked group's page, or a budget in it.
struct LockedCardView: View {
    let screen: LockedScreen
    let act: (LockedScreen.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(screen.title)
                    .font(.system(size: 17, weight: .semibold))
                    .accessibilityIdentifier(AccessibilityID.lockedTitle)
            } icon: {
                Image(systemName: "lock.fill").foregroundStyle(Palette.muted)
            }
            ForEach(screen.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                ForEach(Array(screen.actions.enumerated()), id: \.offset) { index, action in
                    let isMain = index == screen.actions.count - 1
                    Group {
                        if isMain {
                            Button(action.title) { act(action) }.buttonStyle(.borderedProminent)
                        } else {
                            Button(action.title) { act(action) }.buttonStyle(.bordered)
                        }
                    }
                    .accessibilityIdentifier(AccessibilityID.lockedAction(action))
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.muted.opacity(0.5), lineWidth: 1.5))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.lockedCard)
    }
}

/// Pick what stays open: the group, the person in it, and the properties.
struct PickOpenSheet: View {
    @State var screen: PickOpenScreen
    let plans: PurchaseCoordinator

    @State private var failure: String?
    @State private var isSaving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(screen.title).font(.system(size: 17, weight: .semibold))
            Text(screen.intro).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            if !screen.groups.isEmpty {
                list(screen.groupsHeading, items: screen.groups, chosen: { $0 == screen.group },
                     id: AccessibilityID.pickGroup) { screen.choose(group: $0) }
                    .disabled(!screen.canChangeGroup)
                note(screen.groupNote)
            }
            if !screen.people.isEmpty {
                list(screen.peopleHeading, items: screen.people, chosen: { $0 == screen.person },
                     id: AccessibilityID.pickPerson) { screen.choose(person: $0) }
            }
            if !screen.propertyItems.isEmpty {
                list(screen.propertiesHeading, items: screen.propertyItems, chosen: screen.isChosen(property:),
                     id: AccessibilityID.pickProperty) { screen.toggle(property: $0) }
            }
            note(screen.skipNote)
            if let failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(screen.skip) { save(screen.skipPick) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier(AccessibilityID.pickSkip)
                Button(screen.keep) { save(screen.pick) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(AccessibilityID.pickKeep)
            }
            .disabled(isSaving)
        }
        .padding(20)
        .frame(width: 460)
        // Contain, so the rows and buttons keep their own identifiers: without
        // it the Mac gives every child the sheet's identifier.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.pickSheet)
    }

    private func list(_ heading: String, items: [PlanItem], chosen: @escaping (UUID) -> Bool,
                      id: @escaping (UUID) -> String, choose: @escaping (UUID) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.system(size: 12, weight: .semibold)).foregroundStyle(Palette.muted)
            ForEach(items, id: \.id) { item in
                Button { choose(item.id) } label: {
                    HStack {
                        Image(systemName: chosen(item.id) ? "checkmark.circle.fill" : "circle")
                        Text(item.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(id(item.id))
                .accessibilityAddTraits(chosen(item.id) ? .isSelected : [])
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
    }

    private func save(_ pick: PlanPick) {
        isSaving = true
        failure = nil
        Task {
            defer { isSaving = false }
            do {
                try await plans.save(pick)
                dismiss()
            } catch {
                failure = PickWording.failure(error)
            }
        }
    }
}
/// One showing of the pick sheet.
struct PickRequest: Identifiable {
    let id = UUID()
    let screen: PickOpenScreen
}

/// One showing of Choose a plan. With `payFor`, buying then takes over paying
/// for that locked group.
struct ChoosePlanRequest: Identifiable {
    let id = UUID()
    let payFor: GroupID?
}

#endif
