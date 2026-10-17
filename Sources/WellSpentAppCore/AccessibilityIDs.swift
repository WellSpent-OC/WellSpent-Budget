// The Mac screens. SwiftUI exists only on Apple systems; the Linux app draws
// the same shared logic with its own screens.
#if canImport(SwiftUI)

/// The names the UI test finds the Mac screens' controls by.
///
/// Each view sets its own with `.accessibilityIdentifier`, and the test bundle
/// imports this module and uses the same constants, so no name is written
/// twice. Menu items, context menu items and dialog buttons have none: the
/// test finds those by title, from the screens' `Words`.
public enum AccessibilityID {
    // MARK: The main window

    /// Across the top of a staging window. A live build has none, so a test
    /// that finds it knows what it is driving.
    public static let stagingBanner = "banner.staging"

    // MARK: The sidebar

    /// A group's header, which hides or shows its budgets and holds its menu.
    public static func sidebarGroup(_ name: String) -> String { "sidebar.group.\(name)" }
    /// A budget's row.
    public static func sidebarBudget(_ name: String) -> String { "sidebar.budget.\(name)" }
    /// Add Budget, with New Group and Join a Group in its menu.
    public static let sidebarAdd = "sidebar.add"
    /// Sign in, in the footer, shown only while signed out.
    public static let sidebarSignIn = "sidebar.signIn"

    // MARK: The budget's toolbar

    public static let budgetImport = "budget.import"
    public static let budgetAdd = "budget.add"
    public static let toolbarSync = "toolbar.sync"
    public static let toolbarAccount = "toolbar.account"

    // MARK: The account sheet

    public static let accountEmail = "account.email"
    public static let accountPassword = "account.password"
    public static let accountConfirmation = "account.confirmation"
    public static let accountCurrentPassword = "account.currentPassword"
    public static let accountNewPassword = "account.newPassword"
    public static let accountCode = "account.code"
    public static let accountServer = "account.server"
    /// The main button, whatever it says on the step shown.
    public static let accountSubmit = "account.submit"
    /// Cancel, Not now or Done.
    public static let accountClose = "account.close"
    public static let accountBack = "account.back"
    public static let accountCreateAccount = "account.createAccount"
    public static let accountForgotPassword = "account.forgotPassword"
    public static let accountStartOver = "account.startOver"
    public static let accountSendCode = "account.sendCode"
    public static let accountConfirmEmail = "account.confirmEmail"
    public static let accountSignOut = "account.signOut"
    public static let accountSignOutEverywhere = "account.signOutEverywhere"
    public static let accountChangePassword = "account.changePassword"

    // MARK: Budgets and groups

    public static let budgetEditorName = "budgetEditor.name"
    public static let budgetEditorAmount = "budgetEditor.amount"
    /// The group picker, or the new group's name when there is none yet.
    public static let budgetEditorGroup = "budgetEditor.group"
    public static let budgetEditorSave = "budgetEditor.save"
    public static let budgetEditorCancel = "budgetEditor.cancel"
    public static let groupEditorName = "groupEditor.name"
    public static let groupEditorSave = "groupEditor.save"
    public static let groupEditorCancel = "groupEditor.cancel"

    // MARK: A new entry

    public static let entryMerchant = "entry.merchant"
    public static let entryAmount = "entry.amount"
    public static let entryDate = "entry.date"
    public static let entryNote = "entry.note"
    public static let entryAdd = "entry.add"
    public static let entryCancel = "entry.cancel"

    // MARK: Sharing

    public static let shareName = "share.name"
    public static let shareRole = "share.role"
    public static let shareHistory = "share.history"
    public static let shareCreate = "share.create"
    public static let shareCancel = "share.cancel"
    /// The link once made, as text.
    public static let shareLink = "share.link"
    public static let shareCopyLink = "share.copyLink"
    public static let shareDone = "share.done"
    public static let joinLink = "join.link"
    public static let joinName = "join.name"
    public static let joinJoin = "join.join"
    public static let joinCancel = "join.cancel"
}

#endif
