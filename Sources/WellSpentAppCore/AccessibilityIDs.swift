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

    /// A group's line: its name, and the arrow at the end that hides or shows
    /// its budgets. The list makes the line one element, so this one name is
    /// all of it. A click opens the group's page, and a right-click shows its
    /// menu.
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
    /// ⋯ at the top right of a budget on a phone, with Edit and Delete.
    public static let budgetMenu = "budget.menu"
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
    public static let budgetEditorAmountProblem = "budgetEditor.amountProblem"
    /// The group picker, or the new group's name when there is none yet.
    public static let budgetEditorGroup = "budgetEditor.group"
    public static let budgetEditorSave = "budgetEditor.save"
    public static let budgetEditorCancel = "budgetEditor.cancel"
    public static let groupEditorName = "groupEditor.name"
    public static let groupEditorSave = "groupEditor.save"
    public static let groupEditorCancel = "groupEditor.cancel"

    // MARK: The budget's list

    /// An entry's row, by its merchant: the cell with the merchant and the
    /// note. A click on it opens the entry, and a right-click shows its menu.
    public static func entryRow(_ merchant: String) -> String { "entry.row.\(merchant)" }
    /// The bar at the top of the budget after a delete.
    public static let undoBar = "undo.bar"
    /// Undo, in that bar.
    public static let undoButton = "undo.button"

    // MARK: An entry, new or opened from the list

    public static let entryMerchant = "entry.merchant"
    public static let entryAmount = "entry.amount"
    public static let entryDate = "entry.date"
    public static let entryNote = "entry.note"
    /// Add, on a new entry.
    public static let entryAdd = "entry.add"
    public static let entryCancel = "entry.cancel"
    /// Save, on an opened entry.
    public static let entrySave = "entry.save"
    /// Delete…, on the left of an opened entry.
    public static let entryDelete = "entry.delete"
    /// The only button on an entry that can't be changed.
    public static let entryDone = "entry.done"
    /// The Budget list, on an opened entry.
    public static let entryBudget = "entry.budget"
    /// Above the details: who added it, where it came from, and Refund.
    public static let entryTopLine = "entry.topLine"
    /// When this computer's last change to it didn't go through.
    public static let entryNoticeLine = "entry.noticeLine"
    /// Under the date, when it moves the entry out of this period.
    public static let entryPeriodLine = "entry.periodLine"
    public static let entryAmountProblem = "entry.amountProblem"
    /// Why an entry can't be changed.
    public static let entryReadOnlyLine = "entry.readOnlyLine"
    /// One detail of an entry that can't be changed, as plain text, by its
    /// label: "Merchant", "Amount", "Date", "Note" or "Budget".
    public static func entryDetail(_ label: String) -> String { "entry.detail.\(label)" }

    // MARK: The import review

    /// A line's status, such as Already imported, by the bank's text.
    public static func importLineStatus(_ bankText: String) -> String { "import.status.\(bankText)" }
    /// The budget list on a line that needs one, by the bank's text.
    public static func importLineBudget(_ bankText: String) -> String { "import.budget.\(bankText)" }
    public static let importConfirm = "import.import"
    public static let importCancel = "import.cancel"

    // MARK: A group's page

    /// The line under the group's name: shared or not, how many people, and
    /// who made it.
    public static let groupSummary = "group.summary"
    /// Invite Someone…, which opens the Share sheet.
    public static let groupInvite = "group.invite"
    /// Leave Group…, for a member.
    public static let groupLeave = "group.leave"
    /// Remove… on a person's row, by the name the row shows.
    public static func groupRemove(_ name: String) -> String { "group.remove.\(name)" }
    /// The quiet line at the top after a removal.
    public static let groupRemoved = "group.removed"

    // MARK: The invitation page

    /// Your name, on the page a clicked invite link opens.
    public static let invitationName = "invitation.name"
    public static let invitationJoin = "invitation.join"
    /// Sign in…, in place of Join while signed out.
    public static let invitationSignIn = "invitation.signIn"
    /// Confirm your email…, in place of Join while the address is not
    /// confirmed yet.
    public static let invitationConfirmEmail = "invitation.confirmEmail"

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
