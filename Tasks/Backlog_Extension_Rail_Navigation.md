# Backlog Task: Extension Rail Navigation and WarTable Catalog Installation

## 1. Overview and Objective

This task implements the VS Code style Activity Rail navigation and Extensions Catalog flow on the Linux desktop app.

Product decision on 2026-10-24:
- The desktop app uses a far-left vertical Activity Rail (50px wide).
- **Budgets** is the default built-in extension, added to every build for free. Clicking its icon shows the budget groups and categories sidebar and financial detail pane.
- **Extensions** is the second built-in extension, always present to discover and manage add-ons. Clicking it opens the full Extensions Catalog in the main workspace.
- **WarTable** lives inside the Extensions catalog with an "Install" or "Turn on" button. It must not appear on the rail or clutter the budget sidebar until a person turns it on.
- Once installed, the WarTable icon joins the left rail. Clicking it opens the WarTable channels and AI collaboration board.
- Turning WarTable off removes its icon from the rail without affecting budget data.

## 2. Key Design Files and References

All design files are located in the design workspace:

- **Concept PDF:** `Design/Extensions/WellSpent_Extension_Rail_Concept_2026-10-24.pdf`
- **Design Specification:** `Design/Extensions/Extension_Rail_Design_2026-10-24.md`
- **Interactive HTML:** `Design/Extensions/WellSpent_Extension_Rail_Concept_2026-10-24.html`
- **Render Script:** `Design/Extensions/make_extension_rail_pdf.py`
- **High-Resolution Page Previews:** `Design/Extensions/previews_rail/`
- **WarTable Base Design:** `Design/AI_Chat/WarTable_Linux_Design_2026-10-23.md`
- **WarTable Base Concept PDF:** `Design/AI_Chat/WarTable_Linux_Concept_2026-10-23.pdf`
- **Feature Scenario Definitions:** `Features/WarTable.md`
- **Product Design Backlog:** `Design Backlog Item 5: Extension Rail and Catalog Navigation`

## 3. Source Code Files

- **Linux Root View:** `Linux/Sources/WellSpentLinux/RootView.swift`
- **Activity Rail View:** `Linux/Sources/WellSpentLinux/ActivityRailView.swift`
- **Extensions Catalog View:** `Linux/Sources/WellSpentLinux/ExtensionsCatalogView.swift`
- **Shared Catalog Data Model:** `Sources/WellSpentAppCore/Extensions/ExtensionCatalog.swift`
- **WarTable Screen:** `Sources/WellSpentAppCore/Extensions/WarTableScreen.swift`
- **WarTable Linux View:** `Linux/Sources/WellSpentLinux/WarTableView.swift`
- **Unit Tests:** `Tests/WellSpentAppCoreTests/ExtensionCatalogTests.swift`

## 4. UI Architecture and Layout Rules

1. **Zone 1: Activity Rail (50-54px wide)**
   - Dark background (`Palette.sidebar`).
   - Top button: `Budget` (wallet icon `◧`), switches `activeExtension = .budgets`.
   - Conditional button: `WarTable` (table/swords icon `⚔`), only rendered if `isWarTableInstalled` is true. Switches `activeExtension = .warTable`.
   - Bottom-top button: `Extensions` (blocks icon `⬚`), switches `activeExtension = .catalog`.
   - Bottom button: `Account` (gear icon `⚙`), opens `showingAccount = true`.
2. **Zone 2: Secondary Sidebar**
   - For `budgets`: Shows `SidebarView` with groups and budgets. No uninstalled extension entries.
   - For `warTable`: Shows conversations and work channels.
   - For `catalog`: Collapsed, allowing full width for extension cards.
3. **Zone 3: Main Workspace**
   - Displays budget detail (wheel, transactions) or the active extension screen.

## 5. Build, Test, and Packaging Verification

1. **Build Guard:** Ensure `wsr-guard` is active before any build:
   ```sh
   systemctl --user is-active wsr-guard
   ```
2. **Run Package Unit Tests and Measure Line Coverage:**
   ```sh
   docker run --rm --name wsr-test-catalog -u $(id -u):$(id -g) \
     -v "$PWD":/src:ro \
     -v "$HOME/.cache/wellspent-work/scratch-builder":/scratch \
     wellspent-linux-builder:6.2 sh -c \
     'swift test --package-path /src --scratch-path /scratch --enable-code-coverage --filter ExtensionCatalogTests && \
      llvm-cov report /scratch/x86_64-unknown-linux-gnu/debug/WellSpentBudgetPackageTests.xctest \
      -instr-profile=/scratch/x86_64-unknown-linux-gnu/debug/codecov/default.profdata \
      /src/Sources/WellSpentAppCore/Extensions/ExtensionCatalog.swift'
   ```
   *Quality Gate:* Must maintain 100 percent line coverage on `ExtensionCatalog.swift` and meet the 90 percent floor.

3. **Build Linux Debug App:**
   ```sh
   docker run --rm --name wsr-build-app -u $(id -u):$(id -g) \
     -v "$PWD":/src:ro \
     -v "$HOME/.cache/wellspent-work/scratch-builder":/scratch \
     wellspent-linux-builder:6.2 \
     swift build --package-path /src/Linux --scratch-path /scratch/linux -j 8
   ```

4. **Package Staging Release (Static Swift stdlib):**
   ```sh
   docker run --rm --name wsr-pkg-app -u $(id -u):$(id -g) -w /src \
     -v "$PWD":/src:ro \
     -v "$HOME/.cache/wellspent-work/scratch-builder":/scratch \
     -v "$PWD/Linux/dist":/dist \
     -e OUT=/dist -e SWIFT_SCRATCH_PATH=/scratch/linux-pkg -e SWIFT_BUILD_JOBS=8 \
     wellspent-linux-builder:6.2 /src/Linux/scripts/package.sh
   ```

## 6. Constraints and Style Rules

- No em dashes and no double hyphens anywhere.
- Plain words, short sentences with one idea each.
- Say only what evidence supports.
- Container names must start with `wsr-`.
