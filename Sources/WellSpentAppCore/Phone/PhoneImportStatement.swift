// The iPhone's screens, built the iPhone's way. Layout only.
#if os(iOS)
import SwiftUI
import WellSpentModel

/// How Import statement starts: the Files picker, then the review of the file
/// picked. A budget's menu holds the item. The root view holds the picker and
/// the review, as it holds every other sheet, and hands the item its action
/// through the environment.
struct PhoneImportAction: Sendable {
    private let start: @MainActor @Sendable () -> Void

    init(_ start: @escaping @MainActor @Sendable () -> Void) {
        self.start = start
    }

    @MainActor
    func callAsFunction() { start() }
}

private struct PhoneImportActionKey: EnvironmentKey {
    static let defaultValue: PhoneImportAction? = nil
}

extension EnvironmentValues {
    /// Import statement. Nil outside the root view, where there is no picker.
    var importStatement: PhoneImportAction? {
        get { self[PhoneImportActionKey.self] }
        set { self[PhoneImportActionKey.self] = newValue }
    }
}

/// The Files picker and the review it opens. Draws `ImportReviewScreen`.
struct PhoneStatementImport: ViewModifier {
    let model: AppModel
    @State private var picking = false

    func body(content: Content) -> some View {
        let screen = ImportReviewScreen(model: model)
        let picking = $picking
        content
            .environment(\.importStatement, PhoneImportAction {
                // A staging build run by a UI test reads the file the test
                // names, since a test cannot reach the Files picker. A live
                // build always shows the picker.
                if let file = UITestStatement.requested() {
                    screen.open(.success([file]))
                } else {
                    picking.wrappedValue = true
                }
            })
            .fileImporter(isPresented: $picking, allowedContentTypes: ImportReviewScreen.fileTypes,
                          allowsMultipleSelection: false) { screen.open($0) }
            // Swiping the review down is the same as Cancel: nothing is added.
            .sheet(item: Binding(get: { model.pendingImport }, set: { model.pendingImport = $0 })) { _ in
                PhoneImportReviewSheet(model: model)
            }
    }
}

extension View {
    /// Import statement for every budget below: the Files picker and the
    /// review.
    func phoneStatementImport(model: AppModel) -> some View {
        modifier(PhoneStatementImport(model: model))
    }
}

/// Import statement, in its own part at the top of a budget's ⋯, apart from
/// Edit and Delete. Shown only to someone who may add to the group.
struct PhoneImportMenuItem: View {
    @Environment(\.importStatement) private var importStatement

    var body: some View {
        Section {
            Button(BudgetScreen.Words.importStatement) { importStatement?() }
        }
    }
}

#endif
