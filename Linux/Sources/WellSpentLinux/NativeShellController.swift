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

        // Pass self pointer as context to C
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
                render()
            }
        } else if action == "action:sync" {
            Task {
                await screen.syncNow()
                render()
            }
        } else if action == "action:account" {
            print("Account clicked")
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

        // Update detail area if a budget is selected
        if let selectedId = screen.selectedBudget,
           let summary = workspace.model.summaries.values.flatMap({ $0 }).first(where: { $0.budget.id == selectedId }) {
            let fill = RowFill(summary)
            let leftText = fill.isOver ? "Over budget: \(fill.amount)" : "Left this month: \(fill.amount)"
            let spentText = "Spent: \(summary.spent.display). Native GTK 4 active."

            wellspent_gtk_update_detail(
                shellPtr,
                summary.budget.name,
                spentText,
                leftText,
                nil,
                fill.share,
                fill.isOver ? 1 : 0
            )
        }
    }
}
