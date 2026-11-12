// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentPlans

/// Pick what stays open on the free plan: one group, one person in it, and
/// the properties the plan keeps. Draws `PickOpenScreen`; Keep and Skip each
/// hand back what to save. A save that fails says why and keeps the sheet
/// open, as on the Mac.
struct PhonePickSheet: View {
    @State var screen: PickOpenScreen
    let save: (PlanPick) async throws -> Void
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section { Text(screen.intro).font(.subheadline) }
                    .listRowBackground(Color.clear)

                if !screen.groups.isEmpty {
                    Section {
                        ForEach(screen.groups, id: \.id) { item in
                            choice(item.name, chosen: item.id == screen.group,
                                   id: AccessibilityID.pickGroup(item.id)) { screen.choose(group: item.id) }
                                .disabled(!screen.canChangeGroup)
                        }
                    } header: {
                        Text(screen.groupsHeading)
                    } footer: {
                        Text(screen.groupNote)
                    }
                    .listRowBackground(Palette.surface)
                }

                if !screen.people.isEmpty {
                    Section(screen.peopleHeading) {
                        ForEach(screen.people, id: \.id) { item in
                            choice(item.name, chosen: item.id == screen.person,
                                   id: AccessibilityID.pickPerson(item.id)) { screen.choose(person: item.id) }
                        }
                    }
                    .listRowBackground(Palette.surface)
                }

                if !screen.propertyItems.isEmpty {
                    Section(screen.propertiesHeading) {
                        ForEach(screen.propertyItems, id: \.id) { item in
                            choice(item.name, chosen: screen.isChosen(property: item.id),
                                   id: AccessibilityID.pickProperty(item.id), multiple: screen.propertyLimit > 1) {
                                screen.toggle(property: item.id)
                            }
                        }
                    }
                    .listRowBackground(Palette.surface)
                }

                Section { Text(screen.skipNote).font(.footnote).foregroundStyle(Palette.muted) }
                    .listRowBackground(Color.clear)

                if let failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Palette.warning)
                    }
                    .listRowBackground(Palette.surface)
                }
            }
            .phoneSheet(title: screen.title)
            .disabled(saving)
            .accessibilityIdentifier(AccessibilityID.pickSheet)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(screen.skip) { finish(screen.skipPick) }
                        .accessibilityIdentifier(AccessibilityID.pickSkip)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(PhoneWording.button(screen.keep)) { finish(screen.pick) }
                        .accessibilityIdentifier(AccessibilityID.pickKeep)
                }
            }
        }
        .interactiveDismissDisabled(saving)
    }

    private func finish(_ pick: PlanPick) {
        saving = true
        failure = nil
        Task {
            defer { saving = false }
            do {
                try await save(pick)
                dismiss()
            } catch {
                failure = PickWording.failure(error)
            }
        }
    }

    private func choice(_ name: String, chosen: Bool, id: String, multiple: Bool = false,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: multiple ? (chosen ? "checkmark.square.fill" : "square")
                                           : (chosen ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(Palette.ink)
                    .accessibilityHidden(true)
                Text(name).foregroundStyle(Palette.ink)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }
}

/// The card in place of something locked: a property, a group the person
/// kept locked, or a group someone else pays for. Draws `LockedScreen`.
struct PhoneLockedCard: View {
    let screen: LockedScreen
    let run: (LockedScreen.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.title)
                .foregroundStyle(Palette.accent)
                .accessibilityHidden(true)
            Text(screen.title)
                .font(.title3.weight(.bold))
                .foregroundStyle(Palette.ink)
                .accessibilityIdentifier(AccessibilityID.lockedTitle)
            ForEach(screen.lines, id: \.self) { line in
                Text(line).foregroundStyle(Palette.ink)
            }
            HStack(spacing: 12) {
                ForEach(Array(screen.actions.enumerated()), id: \.offset) { index, action in
                    let button = Button(PhoneWording.button(action.title)) { run(action) }
                        .accessibilityIdentifier(AccessibilityID.lockedAction(action))
                    if index == screen.actions.count - 1 {
                        button.buttonStyle(.borderedProminent)
                    } else {
                        button.buttonStyle(.bordered)
                    }
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(Palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Palette.ink, lineWidth: 2))
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.lockedCard)
    }
}

/// "Locked" beside a locked group, person or property in a list.
struct PhoneLockedMark: View {
    let id: UUID

    var body: some View {
        Label(PlanLocks.mark, systemImage: "lock.fill")
            .font(.caption)
            .foregroundStyle(Palette.muted)
            .accessibilityIdentifier(AccessibilityID.lockedMark(id))
    }
}

#endif
