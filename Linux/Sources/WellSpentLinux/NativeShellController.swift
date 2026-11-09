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
    /// A group's menu, or More, as `NativeMenu` holds it: the spec C draws and
    /// the item a reported index means come from the same list.
    private static func menu(_ parts: [[MainScreen.MenuItem]]) -> NativeMenu<MainScreen.MenuItem> {
        NativeMenu(parts, title: \.title)
    }

    private func groupMenuItem(_ group: GroupID, index: Int) -> MainScreen.MenuItem? {
        guard let section = screen.sections.first(where: { $0.id == group }) else { return nil }
        return Self.menu(screen.groupMenu(section.group)).item(at: index)
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
            if let index = Int(action.dropFirst("menu:add:".count)),
               let item = Self.menu([screen.addMenu]).item(at: index) {
                perform(item.action)
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
        } else if action.starts(with: "menu:budget:") {
            if let index = Int(action.dropFirst("menu:budget:".count)),
               case .budget(let summary) = screen.detail,
               let item = Self.menu(screen.budgetMenu(summary.budget)).item(at: index) {
                perform(item.action)
            }
        } else if action == "page:add" {
            handleAction("action:new_transaction")
        } else if action == "page:undo" {
            workspace.model.undoDelete()
            render()
        } else if action == "page:edit_budget" {
            if case .budget(let summary) = screen.detail {
                perform(.editBudget(summary.budget))
            }
        } else if action == "page:import" || action == "page:repeats" || action.starts(with: "entry:") {
            // The file chooser and import review, a repeat's list and the
            // entry editor are sheets: Phase 3.
            FileHandle.standardError.write(Data("native shell: no sheet yet for \(action)\n".utf8))
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
                Self.menu(screen.groupMenu(section.group)).spec)
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
            shellPtr, screen.addButton.title, Self.menu([screen.addMenu]).spec,
            screen.footer, screen.syncFailure)

        drawPage()
    }

    // MARK: - A budget's page

    private typealias Words = BudgetScreen.Words

    /// The right side, from the shared screen: the open budget's page, or the
    /// words for no budgets or none picked. Everything the SwiftCrossUI page
    /// shows, in the same words and order.
    private func drawPage() {
        guard let shellPtr else { return }
        wellspent_gtk_page_clear(shellPtr)
        switch screen.detail {
        case .budget(let summary):
            drawBudget(BudgetScreen(summary: summary, model: workspace.model, me: workspace.sync.userID),
                       on: shellPtr)
        case .noBudgets:
            wellspent_gtk_page_show_message(shellPtr, MainScreen.Words.noBudgetsTitle,
                                            MainScreen.Words.noBudgetsText, screen.addButton.title)
        case .noneSelected:
            wellspent_gtk_page_show_message(shellPtr, MainScreen.Words.noneSelectedTitle,
                                            MainScreen.Words.noneSelectedText, nil)
        }
    }

    private func drawBudget(_ page: BudgetScreen, on shellPtr: UnsafeMutableRawPointer) {
        let budget = page.summary.budget
        wellspent_gtk_page_add_head(shellPtr, page.title, page.mayAdd ? 1 : 0, Words.importStatement, Words.add,
                                    Self.menu(screen.budgetMenu(budget)).spec)
        if let undo = page.undo {
            wellspent_gtk_page_add_undo(shellPtr, undo.message, undo.button)
        }

        let wheel = page.wheel
        var shape = Self.shape(wheel, .budgetDesktop)
        let pace = page.pace
        wellspent_gtk_page_add_wheel(shellPtr, page.dayLine, &shape, wheel.middleKey, wheel.middleAmount,
                                     wheel.middleOf, Self.rgb(wheel.amountColor), wheel.spokenSummary,
                                     pace?.text, pace?.offersEdit == true ? BudgetPace.Words.editBudget(onPhone: false) : nil)
        for figure in wheel.figures {
            wellspent_gtk_page_add_figure(shellPtr, figure.label, figure.amount, figure.description,
                                          figure.isWarning ? 1 : 0)
        }
        wellspent_gtk_page_add_count(shellPtr, page.countLine, page.repeatsWords)

        wellspent_gtk_page_add_columns(shellPtr, Words.date, Words.description,
                                       page.showsAddedBy ? Words.addedBy : nil, Words.source, Words.amount)
        if page.rows.isEmpty {
            wellspent_gtk_page_add_empty(shellPtr, Words.empty)
        }
        for row in page.rows {
            wellspent_gtk_page_add_entry(
                shellPtr, row.id.uuid.uuidString, BudgetScreen.shortDate(row.date), row.merchant, row.note,
                row.notice, page.showsAddedBy ? row.addedBy : nil, row.source, row.amount, Words.rowHelp)
        }
    }

    /// The wheel's shapes where the shared WheelGeometry puts them, for C to draw.
    private static func shape(_ wheel: MoneyWheel, _ g: WheelGeometry) -> wellspent_gtk_wheel {
        let tick = wheel.tick.map { g.tick(at: $0) }
        return wellspent_gtk_wheel(
            size: g.size, radius: g.radius, band: g.band, outer_edge: g.outerEdge, inner_edge: g.innerEdge,
            edge_width: WheelGeometry.edgeWidth, tick_width: WheelGeometry.tickWidth, arc: wheel.arc,
            has_tick: tick == nil ? 0 : 1,
            tick_from_x: tick?.from.x ?? 0, tick_from_y: tick?.from.y ?? 0,
            tick_to_x: tick?.to.x ?? 0, tick_to_y: tick?.to.y ?? 0,
            track: rgb(PaletteValues.wheelTrack), edge: rgb(PaletteValues.wheelEdge), arc_color: rgb(wheel.arcColor))
    }

    /// A shared colour's light value, as Palette.swift draws every colour.
    private static func rgb(_ pair: ColorPair) -> wellspent_rgb {
        wellspent_rgb(red: pair.light.red, green: pair.light.green, blue: pair.light.blue)
    }
}
