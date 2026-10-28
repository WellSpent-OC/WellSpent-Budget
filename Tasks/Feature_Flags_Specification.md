# Feature Flags Specification

Written 2026-10-26 for all contributors and agents working on WellSpent Budget.

## 1. Purpose and Philosophy

WellSpent Budget is preparing for its public beta release. Experimental, in-progress, or platform-specific additions (such as App Extensions, the desktop Activity Rail, and WarTable AI chat) must never leak into production builds or touch live budget data.

Feature flags give all agents a single, unified mechanism to:
1. Develop and test new features on staging builds without branch divergence.
2. Keep production code clean, uncluttered, and strictly limited to approved features.
3. Allow automated tests to verify both enabled and disabled states.

## 2. Core Architecture

All feature flag definitions and resolution logic live in the shared core module `WellSpentAppCore`. Every client target (Mac, iPhone, Linux, and future Android) links to this module.

### The FeatureFlags Type

The `FeatureFlags` struct is located in `Sources/WellSpentAppCore/FeatureFlags.swift`:

- **Immutable:** A running `Workspace` holds an immutable `features` property determined at launch.
- **Dependency Aware:** Dependent flags enforce their hierarchy. For example, WarTable is an extension; if extensions are disabled, WarTable is automatically forced to false.
- **Environment Driven:** Resolution reads the build environment (`AppEnvironment.live` vs `AppEnvironment.staging`), user defaults, and process environment variables.

### Workspace Integration

The running app context `Workspace` exposes `workspace.features`:

- `Workspace.launch(...)` resolves `FeatureFlags` during startup.
- `Workspace.init(...)` takes an optional `FeatureFlags` instance, defaulting to resolving from the active environment.
- Tests can supply custom `FeatureFlags` directly or set test environment variables.

## 3. Environment Resolution Rules

The resolution priority separates live safety from developer flexibility:

### Live Builds (`AppEnvironment.live`)

1. **Default:** Every unreleased feature flag defaults to `false`.
2. **Process Environment:** Live builds completely ignore process environment variables. An accidental variable in a terminal never alters production behavior.
3. **Defaults:** Explicit settings in the live suite's user defaults can enable a flag for internal testing, but unconfigured keys evaluate to `false`.

In a production release, the app is purely a personal finance manager. The Activity Rail, Extensions catalog, and WarTable do not appear.

### Staging Builds (`AppEnvironment.staging`)

1. **Default:** Unreleased features default to `true` so developers, testers, and CI test suites exercise current work.
2. **Environment Variables:** Process environment variables take highest priority:
   - `WELLSPENT_FEATURE_EXTENSIONS`: `"0"`, `"false"`, `"no"`, or `"off"` disables extensions. `"1"`, `"true"`, `"yes"`, or `"on"` enables extensions.
   - `WELLSPENT_FEATURE_WARTABLE`: Controls WarTable availability in staging.
3. **User Defaults:** Staging defaults (`feature.extensions`, `feature.wartable`) apply when no environment variable is present.

## 4. Current Feature Flags

| Flag | Property | Variable | Defaults Key | Default (Live) | Default (Staging) | Description |
|---|---|---|---|---|---|---|
| Extensions | `areExtensionsEnabled` | `WELLSPENT_FEATURE_EXTENSIONS` | `feature.extensions` | `false` | `true` | Enables the Activity Rail and the Extensions Catalog. |
| WarTable | `isWarTableEnabled` | `WELLSPENT_FEATURE_WARTABLE` | `feature.wartable` | `false` | `true` | Enables the WarTable extension card and rail destination. |
| Properties | `isPropertiesEnabled` | `WELLSPENT_FEATURE_PROPERTIES` | `feature.properties` | `false` | `false` | Enables the Properties extension card and the Houses rail item (desktop) or tab (iPhone). Runway is a page inside Properties, not a rail destination. |

### Hierarchical Coercion Rule

WarTable requires App Extensions. In code:

```swift
self.areExtensionsEnabled = areExtensionsEnabled
self.isWarTableEnabled = areExtensionsEnabled && isWarTableEnabled
```

If `areExtensionsEnabled` is false, `isWarTableEnabled` is always false, regardless of inputs.

## 5. UI Gating Behavior

### Linux Desktop (`WellSpentLinux`)

1. **When App Extensions are disabled (`areExtensionsEnabled == false`):**
   - The Activity Rail (54 pixel column on the far left) is completely omitted.
   - The root window renders `NavigationSplitView` with the Budgets sidebar directly.
   - Account settings remain reachable via the Account button at the bottom of the sidebar.
   - Neither the Extensions Catalog nor WarTable can be opened.
2. **When App Extensions are enabled, but WarTable is disabled (`isWarTableEnabled == false`):**
   - The Activity Rail shows `Budget`, `Extensions`, and `Account`.
   - The WarTable button is omitted from the Activity Rail.
   - The Extensions Catalog (`ExtensionCatalog.items`) filters out WarTable.
   - Attempting to switch to `.warTable` falls back safely to the Budgets view.
3. **When both are enabled:**
   - The full Activity Rail and WarTable workroom function as designed.

### Apple Platforms (`macOS` and `iOS`)

The Mac and iPhone interfaces currently display pure budget views. When extensions or future capabilities land on Apple platforms, they must check `workspace.features.areExtensionsEnabled` and respective sub-flags before rendering new navigation bars or catalog entries.

## 6. How to Add a New Feature Flag

Follow this five-step recipe whenever adding a feature:

1. **Add properties to `FeatureFlags.swift`:**
   - Define the environment variable string constant.
   - Define the defaults key string constant.
   - Add the boolean property to `FeatureFlags`.
   - Add resolution logic in `FeatureFlags.resolve(...)`. Remember: Live must default to `false`.
2. **Add unit tests in `FeatureFlagsTests.swift`:**
   - Test default live behavior (must be false).
   - Test default staging behavior (must be true or expected default).
   - Test environment variable overrides.
   - Test user defaults overrides.
3. **Gate the UI and services:**
   - In views, check `workspace.features.<yourFlag>`.
   - If gating catalog items, pass `features: workspace.features` into `ExtensionCatalog.items(...)`.
4. **Update UI tests:**
   - Pass flag overrides in `launch_fresh(self, ...)` to verify both enabled and disabled views.
5. **Update this document:**
   - Add the flag to the table in Section 4.

## 7. Quality Gates and Verification

1. **Line coverage:** Every line and branch in `FeatureFlags.swift` must maintain 100 percent test coverage.
2. **Shared core floor:** The overall client library test suite must stay above the 90.00 percent coverage floor (`./scripts/coverage.sh`).
3. **Local verification:** Run tests in Docker before pushing any branch. Do not rely on GitHub Actions to discover broken tests.
4. **Scenario check:** Run `python3 scripts/scenario-check.py` to confirm all feature tags and platform tables remain synchronized.
