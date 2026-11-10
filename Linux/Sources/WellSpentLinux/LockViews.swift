import Foundation
import SwiftCrossUI
import WellSpentAppCore
import WellSpentExtensionKitLinux
import WellSpentPlans

/// In place of a locked group's page, or a budget in it (LOCK-01, LOCK-02).
/// What it says and offers is LockedScreen's. Layout only.
struct LockedCardView: View {
    let screen: LockedScreen
    let act: (LockedScreen.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("🔒").font(.system(size: 17))
                Text(screen.title)
                    .font(.system(size: 17, weight: .semibold))
            }
            ForEach(screen.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                ForEach(Array(screen.actions.enumerated()), id: \.offset) { index, action in
                    if index == screen.actions.count - 1 {
                        Button(action.title) { act(action) }
                            .defaultAction()
                    } else {
                        Button(action.title) { act(action) }
                    }
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Palette.sidebar))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
    }
}

/// Pick what stays open (LOCK-04, LOCK-05, LOCK-07): the group, the person in
/// it, and the properties. What it lists, ticks and saves is
/// PickOpenScreen's. Layout only.
struct PickOpenView: View {
    @State var screen: PickOpenScreen
    let plans: PurchaseCoordinator
    var close: () -> Void

    @State private var failure: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(screen.title)
                .font(.system(size: 17, weight: .semibold))
            Text(screen.intro)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            if !screen.groups.isEmpty {
                list(screen.groupsHeading, items: screen.groups, chosen: { $0 == screen.group },
                     enabled: screen.canChangeGroup) { screen.choose(group: $0) }
                note(screen.groupNote)
            }
            if !screen.people.isEmpty {
                list(screen.peopleHeading, items: screen.people, chosen: { $0 == screen.person }) {
                    screen.choose(person: $0)
                }
            }
            if !screen.propertyItems.isEmpty {
                list(screen.propertiesHeading, items: screen.propertyItems, chosen: screen.isChosen(property:)) {
                    screen.toggle(property: $0)
                }
            }
            note(screen.skipNote)
            if let failure {
                Text(failure)
                    .font(.system(size: 12))
                    .foregroundColor(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button(screen.skip) { save(screen.skipPick) }
                Button(screen.keep) { save(screen.pick) }
                    .defaultAction()
            }
            .disabled(isSaving)
        }
        .padding(20)
        .frame(width: 460)
        .foregroundColor(Palette.ink)
        .background(Palette.surface)
    }

    /// One heading and its rows. A row is a button that says whether it's
    /// picked, to the eye and to a screen reader.
    private func list(_ heading: String, items: [PlanItem], chosen: @escaping (UUID) -> Bool,
                      enabled: Bool = true, choose: @escaping (UUID) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Palette.muted)
            ForEach(items, id: \.id) { item in
                Button(action: { choose(item.id) }) {
                    HStack(spacing: 8) {
                        Text(chosen(item.id) ? "●" : "○")
                        Text(item.name).font(.system(size: 13))
                        Spacer()
                    }
                    .frame(maxWidth: 10_000)
                }
                // The name before the style: SwiftCrossUI hands a wrapper another widget.
                .accessibility(label: item.name, selected: chosen(item.id))
                .buttonStyle(.plain)
                .disabled(!enabled)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundColor(Palette.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func save(_ pick: PlanPick) {
        isSaving = true
        failure = nil
        Task { @MainActor in
            defer { isSaving = false }
            do {
                try await plans.save(pick)
                close()
            } catch {
                failure = PickWording.failure(error)
            }
        }
    }
}
