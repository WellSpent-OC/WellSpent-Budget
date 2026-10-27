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

    func attach(to gtkApp: UnsafeMutableRawPointer) {
        let teamName = screen.openGroup?.name ?? "Demo Team"
        let title = LinuxSetup.environment.appName

        let context = Unmanaged.passRetained(self).toOpaque()

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

    func handleAction(_ action: String) {
        guard let shellPtr else { return }

        if action.starts(with: "group:") {
            let groupIdStr = String(action.dropFirst("group:".count))
            if let u = UUID(uuidString: groupIdStr) {
                screen.toggle(GroupID(u))
                render()
            }
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
                wellspent_gtk_set_sync_state(shellPtr, 0)
                render()
            }
        } else if action == "action:account" {
            let context = Unmanaged.passRetained(self).toOpaque()
            let isSigned = workspace.sync.account != nil
            let email = workspace.sync.account ?? ""
            wellspent_gtk_show_account_dialog(
                shellPtr,
                email,
                isSigned ? 1 : 0,
                { ctx, act, em, pw in
                    guard let ctx, let act else { return }
                    let ctrl = Unmanaged<NativeShellController>.fromOpaque(ctx).takeRetainedValue()
                    let action = String(cString: act)
                    let emStr = em.map { String(cString: $0) } ?? ""
                    let pwStr = pw.map { String(cString: $0) } ?? ""
                    MainActor.assumeIsolated {
                        ctrl.handleAccountAction(action, email: emStr, password: pwStr)
                    }
                },
                context
            )
        } else if action == "action:add_budget" {
            let context = Unmanaged.passRetained(self).toOpaque()
            wellspent_gtk_show_new_budget_dialog(
                shellPtr,
                { ctx, name, limit in
                    guard let ctx, let name, let limit else { return }
                    let ctrl = Unmanaged<NativeShellController>.fromOpaque(ctx).takeRetainedValue()
                    let nameStr = String(cString: name)
                    let limitStr = String(cString: limit)
                    MainActor.assumeIsolated {
                        ctrl.handleNewBudget(name: nameStr, limit: limitStr)
                    }
                },
                context
            )
        } else if action == "action:new_transaction" {
            let context = Unmanaged.passRetained(self).toOpaque()
            wellspent_gtk_show_new_tx_dialog(
                shellPtr,
                { ctx, merch, amt, note in
                    guard let ctx, let amt else { return }
                    let ctrl = Unmanaged<NativeShellController>.fromOpaque(ctx).takeRetainedValue()
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

        // Clear and rebuild sidebar rows instantly
        wellspent_gtk_sidebar_clear(shellPtr)

        let sections = screen.sections
        for (i, section) in sections.enumerated() {
            wellspent_gtk_sidebar_add_group(
                shellPtr,
                section.id.uuid.uuidString,
                section.title.uppercased(),
                section.isCollapsed ? 1 : 0,
                i == 0 ? 1 : 0
            )

            for summary in section.budgets {
                let fill = RowFill(summary)
                let isSelected = screen.selectedBudget == summary.budget.id

                wellspent_gtk_sidebar_add_budget(
                    shellPtr,
                    summary.budget.id.uuid.uuidString,
                    summary.budget.name,
                    fill.amount,
                    fill.share,
                    fill.isOver ? 1 : 0,
                    isSelected ? 1 : 0
                )
            }
        }

        wellspent_gtk_sidebar_add_footer(shellPtr, screen.footer)

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
