// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentCrypto
import WellSpentModel

/// What a budget's list does with its entries: a tap on a row opens it in
/// its sheet, and after a delete a bar at the top offers Undo. Put on the
/// list with `phoneEntryEditing(model:undo:)`. Each row takes its tap, its
/// swipe and its long press from `phoneEntryActions(_:main:)`.
struct PhoneEntryEditing: ViewModifier {
    let model: AppModel
    /// The bar after a delete, while it stays.
    let undo: UndoOffer?
    /// The entry open in its sheet.
    @State private var opened: EntryEditor?

    func body(content: Content) -> some View {
        content
            .environment(\.openEntry, OpenEntryAction(open: open))
            .sheet(item: $opened) { PhoneOpenedEntrySheet(editor: $0) }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let undo {
                    PhoneUndoBar(offer: undo) { model.undoDelete() }
                }
            }
    }

    /// Opens an entry in its sheet, unless one is open already. Making the
    /// editor is what opens it, and what marks its note seen.
    private func open(_ id: RecordID) {
        guard opened == nil, let editor = EntryEditor(model: model, entry: id) else { return }
        opened = editor
    }
}

/// One entry's row: a tap opens it, and a swipe to the left or a long press
/// offers Edit and Delete, the same two the Mac's right-click offers. They
/// are other ways to the same actions, and do nothing of their own: Edit
/// opens the sheet, and Delete asks the window's question, whose Delete puts
/// up the same Undo bar. A row this person may not change has no swipe and
/// no menu, and looks like every other row.
struct PhoneEntryActions: ViewModifier {
    let row: BudgetScreen.Row
    /// The window's rules: the row's menu and the question a delete asks.
    let main: MainScreen
    @Environment(\.openEntry) private var openEntry

    @ViewBuilder
    func body(content: Content) -> some View {
        let parts = main.entryMenu(row)
        let tappable = content
            .contentShape(Rectangle())
            .onTapGesture { openEntry(row.id) }
            // VoiceOver reads the row as one button, as Home's group names.
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(BudgetScreen.Words.rowHelp)
        if parts.isEmpty {
            tappable
        } else {
            tappable
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // The first is outermost: Delete at the edge, then Edit.
                    ForEach(parts.reversed().flatMap { $0 }) { item in
                        Button(PhoneWording.button(item.title)) { perform(item.action) }
                            .tint(Color(item.isDestructive ? PaletteValues.swipeDelete : PaletteValues.swipeEdit))
                    }
                }
                .contextMenu {
                    ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                        if index > 0 { Divider() }
                        ForEach(part) { item in
                            Button(PhoneWording.button(item.title), role: item.isDestructive ? .destructive : nil) {
                                perform(item.action)
                            }
                        }
                    }
                }
        }
    }

    /// Delete asks first. Edit opens the sheet.
    private func perform(_ action: MainScreen.EntryAction) {
        if action.asksFirst {
            main.ask(action)
        } else if case .open(let id) = action {
            openEntry(id)
        }
    }
}

/// The bar at the top of a budget after a delete: what went, and Undo. A
/// card in the design's dark band with white words, the same in light and
/// dark, and Undo a gold button on it.
struct PhoneUndoBar: View {
    let offer: UndoOffer
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(offer.message)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: undo) {
                Text(offer.button)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color(PaletteValues.undoButtonWords))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color(PaletteValues.undoButton),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    // It takes a tap at least 44 by 44 points around the
                    // gold, as the iPhone asks of every button.
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(AccessibilityID.undoButton)
        }
        .foregroundStyle(Color(PaletteValues.undoBarWords))
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 2)
        .background(Color(PaletteValues.undoBar), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(AccessibilityID.undoBar)
    }
}

/// Opens an entry in its sheet. A budget's list hands it to its rows.
/// Anywhere else it does nothing.
struct OpenEntryAction {
    let open: @MainActor (RecordID) -> Void

    @MainActor
    func callAsFunction(_ id: RecordID) { open(id) }
}

extension EnvironmentValues {
    @Entry var openEntry = OpenEntryAction(open: { _ in })
}

/// A sheet opens for one editor, and a new one is a new sheet.
extension EntryEditor: Identifiable {}

extension View {
    /// A budget's list, whose rows open their entries, with the Undo bar
    /// at the top after a delete.
    func phoneEntryEditing(model: AppModel, undo: UndoOffer?) -> some View {
        modifier(PhoneEntryEditing(model: model, undo: undo))
    }

    /// An entry's row: a tap opens it, and a swipe or a long press offers
    /// Edit and Delete where this person may change it.
    func phoneEntryActions(_ row: BudgetScreen.Row, main: MainScreen) -> some View {
        modifier(PhoneEntryActions(row: row, main: main))
    }
}

#endif
