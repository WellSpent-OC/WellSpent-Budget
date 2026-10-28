import CGtk4
import Foundation
import Observation
import WellSpentAppCore
import WellSpentCrypto
import WellSpentLinuxNative
import WellSpentModel

@MainActor
final class NativeShellController {
    let workspace: Workspace
    let screen: MainScreen
    var shellPtr: UnsafeMutableRawPointer?

    init(workspace: Workspace) {
        self.workspace = workspace
        self.screen = MainScreen(workspace: workspace)
    }

    /// Builds the window the first time "activate" fires. A second launch that
    /// hands over a link fires it again; then the window that exists comes to
    /// the front, and nothing is built or leaked.
    func attach(to gtkApp: UnsafeMutableRawPointer) {
        if let shellPtr {
            wellspent_gtk_window_present(shellPtr)
            return
        }
        Self.loadLook()
        let teamName = screen.openGroup?.name ?? "Demo Team"
        let title = LinuxSetup.environment.appName

        // Unretained: the app holds this controller for as long as it runs,
        // which is longer than any window.
        let context = Unmanaged.passUnretained(self).toOpaque()

        let onAction: wellspent_gtk_action_cb = { ctx, actionId in
            guard let ctx, let actionId else { return }
            let controller = Unmanaged<NativeShellController>.fromOpaque(ctx).takeUnretainedValue()
            let action = String(cString: actionId)
            MainActor.assumeIsolated {
                controller.handleAction(action)
            }
        }

        shellPtr = wellspent_gtk_create_shell_window(gtkApp, title, teamName, onAction, context)
        render()
        if let shellPtr {
            wellspent_gtk_window_present(shellPtr)
        }
    }

    /// The makeover's look: the two bundled fonts go to fontconfig, then the
    /// style sheet loads. Once per process; a missing file leaves the inline
    /// fallback sheet in place.
    private static var lookLoaded = false
    private static func loadLook() {
        guard !lookLoaded else { return }
        lookLoaded = true
        if let fonts = Bundle.module.url(forResource: "Fonts", withExtension: nil),
           let files = try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "ttf" {
                _ = wellspent_fonts_add_file(file.path)
            }
        }
        if let css = Bundle.module.url(forResource: "app_style", withExtension: "css") {
            _ = wellspent_gtk_init_css_file(css.path)
        }
    }

    /// A menu's items as the shell takes them: one title per line, "-" between
    /// the parts. The flattened items match "<prefix>:<index>" by position.
    private static func menuSpec(_ parts: [[MainScreen.MenuItem]]) -> String {
        parts.map { $0.map(\.title).joined(separator: "\n") }.joined(separator: "\n-\n")
    }

    private func groupMenuItem(_ group: GroupID, index: Int) -> MainScreen.MenuItem? {
        guard let section = screen.sections.first(where: { $0.id == group }) else { return nil }
        let items = screen.groupMenu(section.group).flatMap { $0 }
        return items.indices.contains(index) ? items[index] : nil
    }

    /// What a menu item or button asks for. The sheets that open from here
    /// are the next pull requests (Phase 3); until then an action without a
    /// native sheet says so on stderr and does nothing, since the shell is
    /// opt-in.
    func perform(_ action: MainScreen.Action) {
        guard let shellPtr else { return }
        switch action {
        case .newBudget:
            handleAction("action:add_budget_sheet")
        case .deleteBudget, .deleteGroup:
            screen.ask(action)
            askPendingDelete()
        default:
            FileHandle.standardError.write(Data("native shell: no sheet yet for \(action)\n".utf8))
        }
        _ = shellPtr
    }

    /// A delete's question, with the shared words, then the shared rule.
    private func askPendingDelete() {
        guard let shellPtr, let pending = screen.pendingDelete else { return }
        let message = screen.message(for: pending)
        let context = Unmanaged.passUnretained(self).toOpaque()
        wellspent_gtk_ask(shellPtr, pending.title, message, pending.confirmLabel, MainScreen.Words.cancel,
                          { ctx, confirmed in
                              guard let ctx else { return }
                              let ctrl = Unmanaged<NativeShellController>.fromOpaque(ctx).takeUnretainedValue()
                              MainActor.assumeIsolated {
                                  if confirmed == 1, let pending = ctrl.screen.pendingDelete {
                                      ctrl.screen.confirm(pending)
                                  } else {
                                      ctrl.screen.keepIt()
                                  }
                                  ctrl.render()
                              }
                          }, context)
    }

    func handleAction(_ action: String) {
        if action == "window:destroyed" {
            // The window and every widget in it are gone. Free the struct and
            // forget it, so nothing in flight reaches it.
            if let shellPtr {
                wellspent_gtk_free_shell(shellPtr)
            }
            shellPtr = nil
            return
        }
        guard let shellPtr else { return }

        if action.starts(with: "group:") {
            let groupIdStr = String(action.dropFirst("group:".count))
            if let u = UUID(uuidString: groupIdStr) {
                screen.toggle(GroupID(u))
                render()
            }
        } else if action.starts(with: "menu:group:") {
            // "menu:group:<uuid>:<index>"
            let rest = action.dropFirst("menu:group:".count)
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let u = UUID(uuidString: parts[0]), let index = Int(parts[1]),
               let item = groupMenuItem(GroupID(u), index: index) {
                perform(item.action)
            }
        } else if action.starts(with: "menu:add:") {
            if let index = Int(action.dropFirst("menu:add:".count)), screen.addMenu.indices.contains(index) {
                perform(screen.addMenu[index].action)
            }
        } else if action.starts(with: "invite:") {
            // "invite:accept:<uuid>" or "invite:reject:<uuid>"
            let rest = action.dropFirst("invite:".count)
            let parts = rest.split(separator: ":", maxSplits: 1).map(String.init)
            if parts.count == 2, let u = UUID(uuidString: parts[1]),
               let invitation = screen.incomingInvitations.first(where: { $0.id == u }) {
                let accepting = parts[0] == "accept"
                render()
                Task {
                    if accepting { _ = await screen.acceptInvitation(invitation) }
                    else { _ = await screen.rejectInvitation(invitation) }
                    render()
                }
            }
        } else if action == "action:add_budget" {
            perform(screen.addButton.action)
        } else if action.starts(with: "budget:") {
            let budgetIdStr = String(action.dropFirst("budget:".count))
            if let u = UUID(uuidString: budgetIdStr) {
                screen.selectedBudget = BudgetID(u)
                wellspent_gtk_set_active_tab(shellPtr, "budgets")
                render()
            }
        } else if action == "tab:budgets" {
            wellspent_gtk_set_active_tab(shellPtr, "budgets")
        } else if action == "tab:catalog" {
            wellspent_gtk_set_active_tab(shellPtr, "catalog")
        } else if action == "tab:runway" {
            wellspent_gtk_set_active_tab(shellPtr, "catalog")
        } else if action == "tab:wartable" {
            wellspent_gtk_set_active_tab(shellPtr, "catalog")
        } else if action == "action:sync" {
            wellspent_gtk_set_sync_state(shellPtr, 1)
            Task {
                await screen.syncNow()
                // Read again after the wait: the window may have closed meanwhile.
                if let shellPtr = self.shellPtr {
                    wellspent_gtk_set_sync_state(shellPtr, 0)
                }
                render()
            }
        } else if action == "action:account" {
            let context = Unmanaged.passUnretained(self).toOpaque()
            let isSigned = workspace.sync.account != nil
            let email = workspace.sync.account ?? ""
            wellspent_gtk_show_account_dialog(
                shellPtr,
                email,
                isSigned ? 1 : 0,
                { ctx, act, em, pw in
                    guard let ctx, let act else { return }
                    let ctrl = Unmanaged<NativeShellController>.fromOpaque(ctx).takeUnretainedValue()
                    let action = String(cString: act)
                    let emStr = em.map { String(cString: $0) } ?? ""
                    let pwStr = pw.map { String(cString: $0) } ?? ""
                    MainActor.assumeIsolated {
                        ctrl.handleAccountAction(action, email: emStr, password: pwStr)
                    }
                },
                context
            )
        } else if action == "action:add_budget_sheet" {
            let context = Unmanaged.passUnretained(self).toOpaque()
            wellspent_gtk_show_new_budget_dialog(
                shellPtr,
                { ctx, name, limit in
                    guard let ctx, let name, let limit else { return }
                    let ctrl = Unmanaged<NativeShellController>.fromOpaque(ctx).takeUnretainedValue()
                    let nameStr = String(cString: name)
                    let limitStr = String(cString: limit)
                    MainActor.assumeIsolated {
                        ctrl.handleNewBudget(name: nameStr, limit: limitStr)
                    }
                },
                context
            )
        } else if action == "action:new_transaction" {
            let context = Unmanaged.passUnretained(self).toOpaque()
            wellspent_gtk_show_new_tx_dialog(
                shellPtr,
                { ctx, merch, amt, note in
                    guard let ctx, let amt else { return }
                    let ctrl = Unmanaged<NativeShellController>.fromOpaque(ctx).takeUnretainedValue()
                    let merchStr = merch.map { String(cString: $0) } ?? ""
                    let amtStr = String(cString: amt)
                    let noteStr = note.map { String(cString: $0) } ?? ""
                    MainActor.assumeIsolated {
                        ctrl.handleNewTransaction(merchant: merchStr, amount: amtStr, note: noteStr)
                    }
                },
                context
            )
        }
    }

    func handleAccountAction(_ action: String, email: String, password: String) {
        if action == "sign_out" {
            Task {
                await workspace.sync.signOut()
                render()
            }
        } else if action == "sign_in" {
            Task {
                do {
                    try await workspace.sync.signIn(email: email, password: password)
                    await workspace.sync.syncAll()
                    render()
                } catch {
                    print("Sign in error: \(error)")
                }
            }
        }
    }

    func handleNewBudget(name: String, limit: String) {
        let firstGroup = screen.groupsForNewBudget.first
        let editor = BudgetEditor(
            model: workspace.model,
            editing: nil,
            group: firstGroup?.id,
            groups: screen.groupsForNewBudget
        )
        editor.name = name
        editor.amountText = limit
        if editor.needsNewGroup {
            editor.newGroupName = "Personal"
        }
        if editor.save() {
            render()
        }
    }

    func handleNewTransaction(merchant: String, amount: String, note: String) {
        let editor = EntryEditor(model: workspace.model)
        editor.merchant = merchant
        editor.amountText = amount
        editor.note = note
        if editor.add() {
            render()
        }
    }

    func render() {
        guard let shellPtr else { return }

        // The sidebar, rebuilt from the shared screen: invitations, each
        // group's name and menu, its note and budgets, the waiting note,
        // then Add Budget, More and the footer. Everything the SwiftCrossUI
        // sidebar shows, in the same words.
        wellspent_gtk_sidebar_clear(shellPtr)

        typealias InviteWords = EmailInvitationWords
        for invitation in screen.incomingInvitations {
            wellspent_gtk_sidebar_add_invitation(
                shellPtr, invitation.id.uuidString, invitation.groupName.uppercased(),
                InviteWords.invited, InviteWords.from(invitation.inviterName), InviteWords.terms(invitation),
                InviteWords.accept, InviteWords.reject,
                screen.isResponding(to: invitation.id) ? 1 : 0,
                screen.invitationFailure(for: invitation.id))
        }

        let sections = screen.sections
        for (i, section) in sections.enumerated() {
            wellspent_gtk_sidebar_add_group(
                shellPtr, section.id.uuid.uuidString, section.title.uppercased(), section.toggleHelp,
                section.isPageOpen ? 1 : 0, i == 0 ? 1 : 0,
                Self.menuSpec(screen.groupMenu(section.group)))
            if let note = section.note {
                wellspent_gtk_sidebar_add_note(shellPtr, note)
            }
            for summary in section.budgets {
                let fill = RowFill(summary)
                wellspent_gtk_sidebar_add_budget(
                    shellPtr, summary.budget.id.uuid.uuidString, summary.budget.name,
                    fill.amount, fill.spokenValue, fill.share, fill.isOver ? 1 : 0,
                    screen.selectedBudget == summary.budget.id ? 1 : 0)
            }
        }
        if let waiting = screen.waitingNote {
            wellspent_gtk_sidebar_add_note(shellPtr, waiting)
        }

        wellspent_gtk_sidebar_add_footer(
            shellPtr, screen.addButton.title, Self.menuSpec([screen.addMenu]),
            screen.footer, screen.syncFailure)

        // Select first budget if none selected
        if screen.selectedBudget == nil {
            if let firstBudgetId = sections.lazy.compactMap({ $0.budgets.first?.budget.id }).first {
                screen.selectedBudget = firstBudgetId
            }
        }

        // Update detail area and transactions if a budget is selected
        if let selectedId = screen.selectedBudget,
           let summary = workspace.model.summaries.values.flatMap({ $0 }).first(where: { $0.budget.id == selectedId }) {
            let bScreen = BudgetScreen(summary: summary, model: workspace.model, me: workspace.sync.userID)
            let wheel = bScreen.wheel
            let dayLine = bScreen.dayLine ?? "Current period"
            let midKey = wheel.middleKey
            let midAmt = wheel.middleAmount
            let midOf = wheel.middleOf
            let pace = bScreen.pace?.text ?? (summary.isOverspent ? "Over budget" : "On track to stay within budget")

            wellspent_gtk_update_detail_wheel(
                shellPtr,
                summary.budget.name,
                dayLine,
                midKey,
                midAmt,
                midOf,
                pace,
                wheel.arc,
                wheel.tick ?? -1.0,
                summary.isOverspent ? 1 : 0
            )

            wellspent_gtk_clear_transactions(shellPtr)
            for row in bScreen.rows {
                wellspent_gtk_add_transaction_row(
                    shellPtr,
                    BudgetScreen.shortDate(row.date),
                    row.merchant,
                    row.source,
                    row.amount
                )
            }
        }
    }
}
