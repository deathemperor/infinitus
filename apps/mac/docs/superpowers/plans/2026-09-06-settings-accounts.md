# Settings polish — Accounts, Push, Profiles, Devices, Engines (round 5, `settings-accounts`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The five panes a user actually operates — Accounts, Push, Profiles, Devices and the engine panes — reach Apple's System Settings bar. Every group is named by a header and explained by a footer instead of by 30 invisible tooltips; the loudest control on a row is the one you need (Sign In Again shows only on the row whose sign-in lapsed, Add Account is the prominent one); an account's name is text you click to edit, not six permanent boxes; every irreversible action asks first (or offers Undo); every icon-only button announces what it does and to which account; and no engine name, PR number, backtick or raw `Error` reaches the window.

**Architecture:** Six pane files plus one three-line hook in `FleetState`. `AccountsPane` loses its nested `List` (the reason its rows were hard-coded at 30 pt) and its 59-word caption; the section grows a real `header:`/`footer:` pair and an overflow `Menu`, and the add-account controls move to their own trailing Section, which is where System Settings puts a group's primary action. One new `EngineFailure.sentence(_:)` in `SettingsPane.swift` turns every `Error` the engine, the CLI or the network can throw into a sentence with a next step, and the five raw `"\(error)"` interpolations call it. `FleetState.randomizeNames()` returns the aliases it overwrites so the pane can offer Undo; `restoreNames(_:)` puts them back. Nothing else in the model layer moves — account policy stays in the engines.

**Tech Stack:** Swift 6 compiler in Swift 5 language mode (`swift-tools-version: 5.9`), SwiftUI on macOS 14+, AppKit, InfinitusCore. No new dependencies, no test target for the app product (verification is `swift build --product Infinitus` plus a `swift test` gate on the last task).

**Spec:** `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md` — the design critique this plan implements. Task 1 copies it into this worktree; read it before Task 2. The priority issues it names that belong to this stream are **[P1] Accounts has no hierarchy**, **[P1] Confirmation is inverted**, **[P2] Explanations live in three containers** and **[P2] Copy that should not ship**, plus the accessibility half of **[P0] no accessibility labels** for the six icon-only buttons in `AccountsPane` and `SyncPane`.

## Global Constraints

- **Apple's containers.** A `Section` `header:` NAMES the group (a noun phrase, never a sentence). A `Section` `footer:` EXPLAINS consequences (full sentences, `.font(.caption2).foregroundStyle(.secondary)` — the shape `UtilizationPane.swift:211` already uses). `.help()` tooltips survive only on icon-only buttons, and there they are paired with an `.accessibilityLabel`. No `Text(...).font(.caption)` row inside a Section pretending to be a footer. No sentence inside a header.
- **Casing.** Sentence case for labels, toggles, field labels and footers. Title Case for buttons and menu items that are commands ("Sign In Again…", "Add Account…", "Save Webhook", "Test Connection"). Title Case for status values ("Active", "On Hold", "Not Set Up", "Running"). The ellipsis is the single character `…` (`\u{2026}` in source, matching this repo), used ONLY when the action opens something else — a dialog, a sheet, a window, a file panel. A button that just does the thing has no ellipsis.
- **Copy.** No engine name for its own sake: "cswap" may appear only where it NAMES the engine the user chose (the Engines pane title, its version row, its repository link). No PR numbers, no competitor names, no backticked CLI in user-facing text, no file paths in body copy, no raw `"\(error)"`. Every error is a sentence with a next step. The voice is the Remove-account alert's: name the consequence, then name what survives ("The Claude account itself is untouched — you can add it back any time").
- **Destructive or hard-to-reverse actions confirm.** `confirmationDialog` by default; `.alert` when a message body is needed and the action is not a list-row deletion (macOS renders `confirmationDialog` message bodies inconsistently for pane-level actions — the repo's own `LockPane.swift:48` uses `confirmationDialog` with a message and `TeamPane.swift:39` uses `.alert`; follow the per-task instruction). The confirming button carries `role: .destructive`. Recoverable BULK actions get Undo instead of a dialog.
- **Accessibility.** Every icon-only button gets `.accessibilityLabel` naming its object ("Remove death2nd") and an `.accessibilityHint` carrying what its tooltip said. Non-interactive row detail (email, plan chip, status chip) is combined into one element with `.accessibilityElement(children: .combine)`; interactive controls are NEVER combined away. No hard-coded font sizes; no hard-coded row heights.
- **Motion.** This stream adds no animation. If you find yourself reaching for `withAnimation`, a `TimelineView` or a `repeatForever` `.animation`, stop — idle CPU with any window open must stay ~0% and continuous motion in this repo goes through `LayerEffect`/Core Animation only. Anything you do add must read `@Environment(\.accessibilityReduceMotion)`.
- **Theme.** Nothing hard-codes a theme's colours or words. Status chips use semantic colours (`.green` active, `.secondary` held, `.orange` needs-attention) because `RowTheme` carries no account-status vocabulary; do not invent new `RowTheme` fields in this stream.
- **Before editing any UI file, read `/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`.** Every UI task repeats this as its first step.
- **Verification.** `swift build --product Infinitus` after every task (ONE `--product` per invocation — with two flags SwiftPM builds only the last). A screenshot of the affected pane from a dev instance is OPTIONAL; if you take one, the dev instance MUST run with `INFINITUS_CONTROL_SOCKET=/tmp/sacct.sock` or it unlinks the real app's control socket. Full `swift test` before the last commit of the stream.
- **CHANGELOG:** one feature = one short line under `## 0.4.4 (unreleased)` → `### Mac`, added in the LAST task only.
- Every commit carries the trailer `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>` (the repo hook appends it; write it anyway). Stage by explicit path. **Never push.** No subagents from implementers.
- Surgical changes, match existing style, no speculative abstractions.

## File ownership

Three streams run in parallel in separate worktrees and merge into `main`.

| File | This stream's scope |
|---|---|
| `Sources/Infinitus/AccountsPane.swift` | Whole file. |
| `Sources/Infinitus/NotifyPane.swift` | Whole file. |
| `Sources/Infinitus/ProfilesPane.swift` | Whole file. |
| `Sources/Infinitus/SyncPane.swift` | Whole file. |
| `Sources/Infinitus/EnginesPane.swift` | Whole file. |
| `Sources/Infinitus/SettingsPane.swift` | Whole file (it is the cswap config form, not the settings shell). |
| `Sources/Infinitus/FleetState.swift` | ONLY `randomizeNames()` (line 230), a new `restoreNames(_:)` beside it, and the three `host.reorderError = "\(error)"` sites at lines 243, 267, 281. Nothing else in the file. |
| `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md` | New file, copied in Task 1. |
| `CHANGELOG.md` | ONLY the top of the `### Mac` list under `## 0.4.4 (unreleased)`, in the LAST task. |

**This stream MUST NOT edit** (every task's Files block repeats this as "Do not touch"): `Sources/Infinitus/InfinitusApp.swift`, `DisplayPane.swift`, `ThemesPane.swift`, `StatsPane.swift`, `UsagePane.swift`, `UtilizationPane.swift`, `MachinePane.swift`, `ActivityPane.swift`, `LockPane.swift`, `AboutPane.swift`, `CommunityThemes.swift`, `AppModel.swift`, `ControlServer.swift`, `SessionProfilesModel.swift`, `MirrorPairingCenter.swift`, anything under `ios/`, anything under `Sources/InfinitusCore/Team/`, `Sources/Infinitus/Team*.swift`, `Sources/Infinitus/MirrorServer.swift`, `tools/e2e.sh`, `site/`, `README.md`, `Sources/InfinitusCore/` (except reading it).

**Explicitly out of scope, do not "fix" in passing:**
- The headroom-sort toggle is DELETED from `AccountsPane` in Task 2 and re-added under Display by the shell stream. Do not add it to any pane in this worktree.
- `SyncPane`'s `TimelineView(.periodic(by: 5))` (line 261) and its 3 s `Timer.publish` (line 34) are pre-existing data refreshes, not motion. Leave them.
- `SyncPane.agentBrief` (lines 415–469) is written FOR an AI agent, not for the window. Its shell commands and paths stay verbatim.
- `SessionProfilesModel.write`'s error string is already a sentence and lives in a file this stream does not own. Leave it.

---

## File structure

| File | What changes |
|---|---|
| `Sources/Infinitus/SettingsPane.swift` | New `EngineFailure.sentence(_:)`; the three `"\(error)"` sites become sentences; `.help(entry.key)` dropped from the spec-driven rows. |
| `Sources/Infinitus/FleetState.swift` | `randomizeNames()` returns the overwritten aliases; new `restoreNames(_:)`; three error sites call `EngineFailure.sentence`. |
| `Sources/Infinitus/AccountsPane.swift` | Section header + overflow Menu + footer; the nested `List` un-nests; add-account moves to its own Section; alias becomes click-to-edit text; Title Case chips; six accessibility labels; Sign In Again gated on `relogin_required` and confirmed; Randomize Names + Undo. |
| `Sources/Infinitus/NotifyPane.swift` | Six toggles split into two footed sections (the stacked-`.help` bug disappears with it); `LabeledContent` labels on both secret fields; status dot + "Not Set Up"; two Remove confirmations; Title Case commands. |
| `Sources/Infinitus/ProfilesPane.swift` | Empty state becomes a footer sentence + an example prompt; the backticked CLI footer goes; Remove confirms. |
| `Sources/Infinitus/EnginesPane.swift` | "Auto-switch" row renamed "Rotation" (the duplicate); Stop confirms; caption rows become footers; Title Case commands; probe errors become sentences. |
| `Sources/Infinitus/SyncPane.swift` | "Phone companion" + "Pair a phone" merge into "Pairing" (one QR, one primary address, an "Other addresses" disclosure); "Anywhere" becomes "Tunnel"; footers replace caption rows and lose their backticks and the config-file path; Regenerate and crash-report delete confirm; icon buttons get labels. |
| `CHANGELOG.md` | Five lines under `### Mac`. |

---

### Task 1: The spec snapshot, and every error becomes a sentence

**Files:**
- Create: `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md` (copied, not authored)
- Modify: `Sources/Infinitus/SettingsPane.swift` (new `EngineFailure`; lines 33, 48, 56; the two `.help(entry.key)` at lines 140/147 and the one at 150)
- Modify: `Sources/Infinitus/NotifyPane.swift` (lines 31 and 90)
- Modify: `Sources/Infinitus/EnginesPane.swift` (lines 225, 227, 236, 315, 317, 327)
- Modify: `Sources/Infinitus/FleetState.swift` (lines 243, 267, 281 only)
- Do not touch: `InfinitusApp.swift`, `DisplayPane.swift`, `ThemesPane.swift`, `StatsPane.swift`, `UsagePane.swift`, `UtilizationPane.swift`, `MachinePane.swift`, `ActivityPane.swift`, `LockPane.swift`, `AboutPane.swift`, `CommunityThemes.swift`, `AppModel.swift`, `ControlServer.swift`, `SessionProfilesModel.swift`, `MirrorPairingCenter.swift`, `ios/`, `Sources/InfinitusCore/Team/`, `Sources/Infinitus/Team*.swift`, `MirrorServer.swift`, `tools/e2e.sh`, `site/`, `README.md`, `CHANGELOG.md`.

**Interfaces:**
- Produces:

```swift
/// Every engine failure a settings pane shows, as a sentence with a next step.
enum EngineFailure {
    static func sentence(_ error: Error) -> String
}
```

- Consumed by: `SettingsPane` (load + commit), `NotifyPane` (load + run), `EnginesPane` (both `test()` probes), `FleetState` (rename / randomize / reorder), and Task 4's `restoreNames`.

- [ ] **Step 1: Read the craft floor.** Read `/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md` before editing anything. The rule that bites here: *"Copy: the product's own language. Controls name their action; errors name the problem and the recovery."*

- [ ] **Step 2: Copy the spec into this worktree.** The critique snapshot is NOT committed on any branch — it exists only in the `limitless-e2` worktree. From this worktree's root:

```sh
mkdir -p .impeccable/critique
cp /Users/deathemperor/death/limitless-e2/.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md \
   .impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md
```

Read the copied file. It is the spec for Tasks 2–9; do not edit it.

- [ ] **Step 3: The mapper.** In `Sources/Infinitus/SettingsPane.swift`, insert between the `import InfinitusCore` line (line 2) and the `/// The cswap settings pane` doc comment (line 4):

```swift

/// Every engine failure a settings pane shows the user, as a sentence
/// with a next step. The raw `Error` never reaches the window: a
/// `CLIError`'s text carries the engine's argv ("cswap notify slack -
/// exited 1"), a `DecodingError` its coding path, and an `NSError` its
/// debug description — none of the three tells anyone what to do next
/// (the critique's [P2], four sites). Lives here because every pane in
/// this settings group calls it and they are all one module.
enum EngineFailure {
    static func sentence(_ error: Error) -> String {
        if let engine = error as? EngineError {
            switch engine {
            case .unsupported:
                return "This engine doesn't support that action. Nothing changed."
            case .unreachable:
                return "Infinitus can't reach the engine. Check it is running at the address above, then try again."
            case .unauthorized:
                return "The engine refused the key. Check the key and save it again."
            case .remote(let status, _):
                return "The engine answered with an error (\(status)). Check the engine, then try again."
            }
        }
        if error is CLIError {
            return "The engine refused that change. Check it is running, then try again."
        }
        if error is DecodingError {
            return "The engine answered in a form this version doesn't understand. Update the engine, then try again."
        }
        let ns = error as NSError
        switch (ns.domain, ns.code) {
        case (NSCocoaErrorDomain, NSFileNoSuchFileError), (NSPOSIXErrorDomain, Int(ENOENT)):
            return "The engine isn't where Infinitus expects it. Reinstall it, then try again."
        case (NSCocoaErrorDomain, NSFileWriteNoPermissionError), (NSPOSIXErrorDomain, Int(EACCES)):
            return "Infinitus isn't allowed to run the engine. Check its permissions, then try again."
        case (NSURLErrorDomain, NSURLErrorNotConnectedToInternet):
            return "No network connection \u{2014} reconnect, then try again."
        case (NSURLErrorDomain, NSURLErrorTimedOut):
            return "The engine didn't answer in time. Check it is running, then try again."
        case (NSURLErrorDomain, NSURLErrorCannotConnectToHost),
             (NSURLErrorDomain, NSURLErrorCannotFindHost):
            return "Nothing answered at that address. Check the address and that the engine is running."
        default:
            return "Couldn't save \u{2014} try again."
        }
    }
}
```

- [ ] **Step 4: The three `SettingsPane` sites.** Replace line 33 `} catch { loadError = "\(error)" }` with:

```swift
        } catch { loadError = EngineFailure.sentence(error) }
```

Replace line 48 `                } catch { errors[entry.key] = "\(error)" }` and line 56 (identical text, inside the `.unset` branch) with, each:

```swift
                } catch { errors[entry.key] = EngineFailure.sentence(error) }
```

- [ ] **Step 5: Drop the raw keys from the spec-driven rows.** The `.help(entry.key)` modifiers show the engineer-facing key ("autoswitch.limitScanIntervalSeconds") on hover of a labelled control — a tooltip on something that is not an icon-only button, showing a config key. Delete all three: line 140 (`.help(entry.key)` after the bool `Toggle`), line 147 (after the choice `Picker`'s `.onChange`), and the `.help(entry.key)` chained onto `Text(Self.humanLabel(entry.key))` on line 150 (leave the `Text` itself). The `Text(entry.help)` caption under each row already carries the explanation.

Then fix the doc comment that promised the tooltip — in `humanLabel`'s comment (lines 122–123), delete the sentence "The raw key stays reachable as the control's tooltip." and leave the first line ("`limitScanIntervalSeconds` → `Limit scan interval seconds`").

- [ ] **Step 6: `NotifyPane`.** Replace line 31 `        } catch { errorText = "\(error)" }` with:

```swift
        } catch { errorText = EngineFailure.sentence(error) }
```

Replace line 90 `            } catch { errorText = "\(error)" }` with:

```swift
            } catch { errorText = EngineFailure.sentence(error) }
```

- [ ] **Step 7: `EnginesPane`'s two probes.** In `CLIProxyEnginePane.test()`, replace line 225:

```swift
        guard let url = URL(string: urlString) else {
            probe = "That isn't a valid address \u{2014} it should look like \(CLIProxyEngine.defaultBaseURL.absoluteString)."
            return
        }
```

replace line 227:

```swift
        guard !k.isEmpty else { probe = "Enter the management key first, then test."; return }
```

and replace line 236 `                probe = (error as? EngineError)?.errorDescription ?? "\(error)"` with:

```swift
                probe = EngineFailure.sentence(error)
```

In `NineRouterEnginePane.test()`, replace line 315:

```swift
        guard let url = URL(string: urlString) else {
            probe = "That isn't a valid address \u{2014} it should look like \(NineRouterEngine.defaultBaseURL.absoluteString)."
            return
        }
```

and replace line 327 `                probe = (error as? EngineError)?.errorDescription ?? "\(error)"` with:

```swift
                probe = EngineFailure.sentence(error)
```

(The password probe at line 316–318 has no empty guard to fix — 9Router allows an empty password when "require login" is off.)

- [ ] **Step 8: `FleetState`'s three sites.** In `Sources/Infinitus/FleetState.swift`, replace each of the three occurrences of `} catch { host.reorderError = "\(error)" }` — inside `randomizeNames()` (line 243), `rename(_:to:)` (line 267) and `reorder(_:done:)` (line 281) — with:

```swift
            } catch { host.reorderError = EngineFailure.sentence(error) }
```

Change nothing else in this file; Task 4 comes back for `randomizeNames`'s signature.

- [ ] **Step 9: Build.** `swift build --product Infinitus` → succeeds. Then grep to prove the sites are gone:

```sh
grep -rn '"\\(error)"' Sources/Infinitus/SettingsPane.swift Sources/Infinitus/NotifyPane.swift \
    Sources/Infinitus/EnginesPane.swift Sources/Infinitus/FleetState.swift
```

→ no output.

- [ ] **Step 10: Commit.**

```sh
git add .impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md \
        Sources/Infinitus/SettingsPane.swift Sources/Infinitus/NotifyPane.swift \
        Sources/Infinitus/EnginesPane.swift Sources/Infinitus/FleetState.swift
git commit -m "settings: an engine failure reads as a sentence with a next step

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: Accounts — hierarchy

The critique's [P1]: "its loudest element is its rarest action". Six bordered **Relogin** buttons, an "Add account…" of equal weight sitting below "Randomize names", a 59-word paragraph inside the section, and a Display setting as the first row.

**Files:**
- Modify: `Sources/Infinitus/AccountsPane.swift` (`FleetAccountsSection` lines 628–818; `OAuthAddRow` lines 822–847; `CswapAddFlow.phases` `.idle` case lines 866–872)
- Do not touch: everything in the "MUST NOT edit" list, and — in this task — `RenameField` (lines 934–956), `statusChip` (lines 800–817) and `row(_:)`'s button bodies, which are Task 3's.

**Interfaces:** none new; this task is layout and copy only.

- [ ] **Step 1: Read the craft floor** (`/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`) and `.impeccable/critique/2026-09-06T08-58-14Z__sources-infinitus.md`. Then read `Sources/Infinitus/AccountsPane.swift` from line 569 to the end.

- [ ] **Step 2: Un-nest the rows.** The `List` at lines 656–671 is inside a `Form` `Section`; a nested `List` does not size to its content, which is the only reason line 672 hard-codes `CGFloat(fleet.accounts.count) * 30 + 16`. A grouped `Form` is List-backed on macOS 14, so a bare `ForEach` with `.onMove` reorders exactly the same way and sizes naturally. This is the only `.onMove` in `Sources/Infinitus`, so there is no in-repo precedent to copy — verify the drag in Step 10 and use the fallback below if it does not work.

- [ ] **Step 3: Replace the whole `FleetAccountsSection.body`.** Replace lines 638–688 (from `    var body: some View {` through the closing `    }` of `body`, i.e. everything up to but not including `    @ViewBuilder private func row(_ a: Account) -> some View {`) with:

```swift
    var body: some View {
        Section {
            if fleet.accounts.isEmpty {
                Text("No accounts yet \u{2014} add the first one below.")
                    .foregroundStyle(.secondary)
            }
            ForEach(fleet.accounts, id: \.number) { a in
                row(a).moveDisabled(!caps.contains(.reorder))
                    .contextMenu { rowMenu(a) }
            }
            .onMove { from, to in
                guard caps.contains(.reorder) else { return }
                var order = fleet.accounts.map(\.number)
                order.move(fromOffsets: from, toOffset: to)
                fleet.reorder(order)
            }
            if let err = model.reorderError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        } header: {
            HStack {
                Text("\(fleet.provider.displayName) \u{00B7} \(fleet.engine.displayName)")
                Spacer()
                if caps.contains(.rename), !fleet.accounts.isEmpty {
                    Menu {
                        Button("Randomize Names") { fleet.randomizeNames() }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel("More actions for \(fleet.engine.displayName)")
                }
            }
        } footer: {
            Text(footerText).font(.caption2).foregroundStyle(.secondary)
        }
        if isCswap || caps.contains(.addOAuth) {
            // A group's primary action sits in its own trailing group, the
            // way System Settings puts "Add Account…" under a Users list —
            // so it can be the prominent button without shouting over the
            // rows, and so it can carry its own one-clause footer.
            Section {
                if isCswap {
                    CswapAddFlow(model: model, flow: flow)
                } else {
                    OAuthAddRow(model: model, engineID: fleet.engineID, provider: fleet.provider)
                }
            } footer: {
                Text("Opens Claude's sign-in in a private in-app window \u{2014} your "
                     + "browser session is never touched.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    /// The context menu every row carries: the name re-roll, and the
    /// always-available sign-in (the prominent button on the row shows
    /// only when the engine says the sign-in lapsed — Task 3).
    @ViewBuilder private func rowMenu(_ a: Account) -> some View {
        if caps.contains(.rename) {
            Button("Re-roll Name") { fleet.randomizeName(a.number) }
        }
        if canRelogin {
            Button("Sign In Again\u{2026}") { fleet.startRelogin(a) }
        }
    }
```

Three things vanish in that replacement and must NOT come back anywhere in this worktree:
1. the `Toggle("Popup sorts rows by headroom (active and next first)", isOn: $model.sortByHeadroom)` and its `.help` (old lines 640–650) — it is a Display setting; the shell stream re-adds it under Display;
2. the `Text(caption)` row (old line 651);
3. the standalone `Button("Randomize names")` and its `.help` (old lines 676–681) — it is now the section's overflow menu item.

- [ ] **Step 4: Replace the caption with the footer.** Replace the whole `caption` computed property (lines 773–795, doc comment included) with:

```swift
    /// One line under the rows, one clause per control this fleet
    /// actually has. Everything the old four-sentence paragraph
    /// explained now lives where it is used: on the buttons, as
    /// tooltips and accessibility hints (Task 3).
    private var footerText: String {
        var parts: [String] = []
        if caps.contains(.reorder) {
            parts.append("Drag to set the rotation order.")
        }
        if caps.contains(.rename) {
            parts.append("Click a name to rename it.")
        }
        if caps.contains(.prefer), !fleet.accounts.contains(where: { $0.preferred != nil }) {
            parts.append("Starring needs the engine's preferred-account setting; "
                         + "update the engine to use it.")
        }
        return parts.joined(separator: " ")
    }
```

That deletes the last "cswap"/"PR #312" string in this pane. Verify with `grep -n "PR #312\|claude-swap\|cswap" Sources/Infinitus/AccountsPane.swift` — the only survivors must be the `CswapEngine.engineID` comparison, the `CswapAddFlow` type name and the doc comments, never a user-visible `Text` or `Button` label.

- [ ] **Step 5: The prominent Add Account button (OAuth engines).** Replace `OAuthAddRow.body` (lines 828–845) with:

```swift
    var body: some View {
        HStack(spacing: 8) {
            Button("Add Account\u{2026}") {
                model.addOAuthAccount(engineID: engineID, provider: provider)
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.addingFirstAccount || flow.running)
            if model.addingFirstAccount {
                ProgressView().controlSize(.small)
                Text("Sign in in the window that opened\u{2026}")
                    .font(.caption).foregroundStyle(.secondary)
            } else if let msg = model.firstAccountMessage {
                Text(msg).font(.caption).foregroundStyle(.orange)
            }
        }
    }
```

The explainer that used to trail the button is now the Section footer from Step 3 — it must not appear twice.

- [ ] **Step 6: The prominent Add Account button (cswap).** In `CswapAddFlow.phases`, replace the `.idle` case (lines 866–872) with:

```swift
        case .idle:
            Button("Add Account\u{2026}") { flow.start(model: model) }
                .buttonStyle(.borderedProminent)
```

- [ ] **Step 7: Title Case the rest of the add flow's commands, and stop naming a command that isn't run.** Still in `CswapAddFlow.phases`:
  - line 876 `Text("Starting claude setup-token\u{2026}")` → `Text("Starting Claude's sign-in\u{2026}")` (the flow runs `claude auth login`, not `setup-token` — `TokenFlow`'s own header says so, so the string was both wrong and engineer-facing);
  - line 877, 897, 906 `Button("Cancel")` → unchanged ("Cancel" is already Title Case);
  - line 890 `Button("Reopen login window")` → `Button("Reopen Login Window")`;
  - line 891 `TextField("Paste code", text: $flow.code)` → `TextField("Paste the code", text: $flow.code)`;
  - line 894 `Button("Submit")` → unchanged;
  - line 914 `Button("Add another")` → `Button("Add Another\u{2026}")` (it opens the sign-in window);
  - line 915 `Button("Done")` → unchanged;
  - line 923 `Button("Try again")` → `Button("Try Again\u{2026}")` (same window);
  - line 924 `Button("Dismiss")` → unchanged.

- [ ] **Step 8: The fleetless-engine section keeps its shape.** In `AccountsPane.body` (lines 595–600) the fleetless branch renders its own Section with `OAuthAddRow`. Give it the same footer so the two paths read alike — replace lines 595–600 with:

```swift
            ForEach(fleetlessOAuthEngines) { engine in
                Section {
                    Text("No accounts yet \u{2014} add the first one below.")
                        .foregroundStyle(.secondary)
                    OAuthAddRow(model: model, engineID: engine.id, provider: .claude)
                } header: {
                    Text("Claude \u{00B7} \(engine.name)")
                } footer: {
                    Text("Opens Claude's sign-in in a private in-app window \u{2014} your "
                         + "browser session is never touched.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
```

- [ ] **Step 9: The empty-app case.** Replace lines 601–606 with:

```swift
            if model.fleets.isEmpty && fleetlessOAuthEngines.isEmpty {
                Section {
                    Text("No engine is on. Turn one on in an engine's tab to add "
                         + "your first account.")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Accounts")
                }
            }
```

(The old string named the CLIProxyAPI tab specifically, which is wrong on a Mac whose only engine is cswap or 9Router.)

- [ ] **Step 10: Build and verify the drag.** `swift build --product Infinitus` → succeeds. Then run a dev instance and drag an account row:

```sh
INFINITUS_CONTROL_SOCKET=/tmp/sacct.sock .build/debug/Infinitus &
```

Open Settings → Accounts, drag row 2 above row 1, confirm the order changes and that the section is as tall as its rows (no clipping, no empty gap). Kill the dev instance when done (`pkill -f 'INFINITUS_CONTROL_SOCKET=/tmp/sacct.sock'` or kill the job) — it must never run against the real app's socket.

**If the un-nested `ForEach` will not drag**, restore the `List { … }` wrapper exactly as it was but replace the hard-coded height with a scaled metric — add to `FleetAccountsSection`'s stored properties `@ScaledMetric private var rowHeight: CGFloat = 30` and write `.frame(minHeight: CGFloat(fleet.accounts.count) * rowHeight + 16)`. Record which branch you took in the commit body.

- [ ] **Step 11: Commit.**

```sh
git add Sources/Infinitus/AccountsPane.swift
git commit -m "accounts: the section names itself, the primary action is Add Account

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Accounts — the row

The row is where the critique's noise lives: six permanent "Name" boxes, an empty one for the account with no alias, lowercase chips that echo raw engine states, a bordered Relogin on every row, and five icon buttons that announce as "button".

**Files:**
- Modify: `Sources/Infinitus/AccountsPane.swift` (`FleetAccountsSection.row(_:)`, `statusChip(_:)`, and `RenameField`)
- Do not touch: everything in the "MUST NOT edit" list. Anchor your edits on the code strings quoted below, not on HEAD line numbers — Task 2 moved this file.

**Interfaces:**
- Produces (all `private` inside `AccountsPane.swift`):

```swift
private func accountLabel(_ a: Account) -> String            // file scope: alias, or the email when there is none
extension FleetAccountsSection {
    private static func statusWord(_ status: String) -> String   // Title Case chip word
    private static func statusHelp(_ status: String) -> String   // the sentence behind the chip
}
```

- [ ] **Step 1: Read the craft floor** (`/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`). The rules that bite here: contrast on secondary text, and "Controls name their action".

- [ ] **Step 2: The row's name helper and the identity block.** Add at FILE scope (not inside a type), immediately above `private struct FleetAccountsSection: View {`:

```swift
/// What an account is called in a sentence: its name if it has one,
/// otherwise its email. Every accessibility label and every dialog in
/// this pane says the account this way, so the window never refers to
/// one account by two different words. File scope because both
/// `AccountsPane` (which owns the dialogs) and `FleetAccountsSection`
/// (which owns the rows) need it.
private func accountLabel(_ a: Account) -> String {
    let alias = a.alias ?? ""
    return alias.isEmpty ? a.email : alias
}
```

Then add to `FleetAccountsSection`, immediately above `@ViewBuilder private func row(_ a: Account) -> some View {`:

```swift
    /// The non-interactive detail of a row — email, plan, status — as
    /// ONE accessibility element, so VoiceOver reads "death2nd@…, Max
    /// 20x, Active" after the slot and the name instead of three
    /// unlabelled fragments. The name and the action buttons stay
    /// separate: combining them away would make them unreachable.
    @ViewBuilder private func detail(_ a: Account) -> some View {
        HStack(spacing: 8) {
            Text(a.email).lineLimit(1)
                .font(.caption).foregroundStyle(.secondary)
            if let plan = a.plan {
                Text(plan)
                    .font(.caption2)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    .foregroundStyle(.secondary)
            }
            statusChip(a)
        }
        .accessibilityElement(children: .combine)
    }
```

- [ ] **Step 3: Replace `row(_:)` wholesale.** Replace the entire `@ViewBuilder private func row(_ a: Account) -> some View { … }` body (it currently starts with `        HStack(spacing: 8) {` and ends with the closing brace before the `caption`/`footerText` property) with:

```swift
    @ViewBuilder private func row(_ a: Account) -> some View {
        HStack(spacing: 8) {
            if caps.contains(.reorder) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            Text("\(a.number)").monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("Slot \(a.number)")
            if caps.contains(.rename) {
                RenameField(fleet: fleet, account: a)
            } else {
                Text(accountLabel(a)).lineLimit(1)
            }
            detail(a)
            Spacer()
            // The recovery action appears on the row that needs it, and
            // nowhere else — every row's context menu still has it.
            if canRelogin, a.usageStatus == "relogin_required" {
                Button("Sign In Again\u{2026}") { confirmRelogin = (fleet, a) }
                    .buttonStyle(.borderedProminent)
                    .disabled(flow.running)
            }
            if caps.contains(.prefer), let confirmed = a.preferred {
                // Pick-first (#15) is the engine's knob: nil `preferred`
                // means this engine build has none, so no star at all.
                // A pending flip shows at once, dimmed until the engine
                // confirms it.
                let pending = fleet.pendingPreferred[a.number]
                let starred = pending ?? confirmed
                Button { fleet.setPreferred(a.number, !starred) } label: {
                    Image(systemName: starred ? "star.fill" : "star")
                        .foregroundStyle(starred ? Color.yellow : Color.secondary)
                        .opacity(pending == nil ? 1 : 0.5)
                }
                .buttonStyle(.borderless)
                .disabled(flow.running || pending != nil)
                .accessibilityLabel(starred ? "Stop preferring \(accountLabel(a))"
                                            : "Prefer \(accountLabel(a))")
                .accessibilityHint(preferHint(starred: starred))
                .help(preferHint(starred: starred))
            }
            if caps.contains(.switch), !a.active {
                Button { fleet.switchTo(a.number) } label: {
                    Image(systemName: "arrow.right.circle")
                }
                .buttonStyle(.borderless)
                .disabled(flow.running)
                .accessibilityLabel("Switch to \(accountLabel(a))")
                .accessibilityHint(switchHint)
                .help(switchHint)
            }
            if caps.contains(.hold) {
                // Rotation hold (todo 2026-09-01): the row stays listed,
                // auto-rotation (or the proxy's routing) skips it.
                let held = a.disabled ?? false
                Button {
                    fleet.setRotation(a.number, enabled: held)
                } label: {
                    Image(systemName: held ? "play.circle" : "pause.circle")
                }
                .buttonStyle(.borderless)
                .disabled(flow.running)
                .accessibilityLabel(held ? "Return \(accountLabel(a)) to rotation"
                                         : "Hold \(accountLabel(a)) out of rotation")
                .accessibilityHint(held
                                   ? "Rotation starts using this account again."
                                   : "The account stays listed; rotation skips it.")
                .help(held
                      ? "Return this account to rotation."
                      : "Hold this account out of rotation \u{2014} it stays listed, "
                        + "rotation skips it.")
            }
            if caps.contains(.remove) {
                Button(role: .destructive) {
                    confirmDelete = (fleet, a)
                } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(flow.running)
                .accessibilityLabel("Remove \(accountLabel(a))")
                .accessibilityHint("Asks first. \(fleet.engine.displayName) forgets its stored sign-in.")
                .help("Remove \(accountLabel(a)) from \(fleet.engine.displayName).")
            }
        }
    }

    /// The star's tooltip — one sentence, no knob names. Each engine
    /// spends the preference differently, so the wording follows it.
    private func preferHint(starred: Bool) -> String {
        if starred {
            return "The engine lands on this account first when it switches."
        }
        return isCswap
            ? "Switches to this account now, and the engine lands on it first from then on."
            : "Switches to this account now, and the engine drains it before unstarred ones."
    }

    private var switchHint: String {
        isCswap ? "Makes this the account Claude Code uses, right now."
                : "Makes this the credential the engine serves first."
    }
```

Note the two behaviour changes hidden in that block: the tooltips no longer say "autoswitch.preferred" or "priority tier", and the "Relogin" button is gone from the general case (its label moved to the context menu in Task 2 and to the gated prominent button here).

- [ ] **Step 4: Declare the confirmation state where the existing one lives.** A presentation modifier on a `Section` fires once per row — `Section` distributes modifiers to its children the way `Group` does. The repo already dodged this for Remove: `confirmDelete` is `@State` on `AccountsPane`, a `@Binding` on `FleetAccountsSection`, and the `.alert` sits on the `Form`. Do exactly the same here.

In `AccountsPane`, add after `@State private var confirmDelete: (fleet: FleetState, account: Account)?`:

```swift
    /// Signing in again clobbers the ACTIVE credential for the duration
    /// of the flow, so it asks first (the critique's [P1] inverted
    /// confirmations). Same shape as `confirmDelete`: the state lives
    /// here, the dialog sits on the Form, the rows only set it.
    @State private var confirmRelogin: (fleet: FleetState, account: Account)?
```

and pass it down — in `AccountsPane.body`, the `FleetAccountsSection(...)` call becomes:

```swift
                FleetAccountsSection(fleet: fleet, model: model, flow: flow,
                                     confirmDelete: $confirmDelete,
                                     confirmRelogin: $confirmRelogin)
```

In `FleetAccountsSection`, add after `@Binding var confirmDelete: (fleet: FleetState, account: Account)?`:

```swift
    @Binding var confirmRelogin: (fleet: FleetState, account: Account)?
```

- [ ] **Step 5: The dialog goes on the Form.** In `AccountsPane.body`, chain it onto the existing `.alert(...)` for Remove — that is, immediately after that alert's closing `}`:

```swift
        .confirmationDialog("Sign in again as \(confirmRelogin.map { accountLabel($0.account) } ?? "this account")?",
                            isPresented: Binding(get: { confirmRelogin != nil },
                                                 set: { if !$0 { confirmRelogin = nil } })) {
            Button("Sign In Again") {
                if let target = confirmRelogin { target.fleet.startRelogin(target.account) }
                confirmRelogin = nil
            }
            Button("Cancel", role: .cancel) { confirmRelogin = nil }
        } message: {
            Text("Signing in again temporarily makes "
                 + "\(confirmRelogin.map { accountLabel($0.account) } ?? "this account") "
                 + "the active one; Infinitus switches back to "
                 + "\(activeLabel(confirmRelogin?.fleet)) when it finishes.")
        }
```

(No `presenting:` overload here, for the same reason the Remove alert has none: the tuple is not `Identifiable`.) Add the helper at file scope, next to `accountLabel`:

```swift
/// The account the sign-in flow will hand control back to.
private func activeLabel(_ fleet: FleetState?) -> String {
    fleet?.accounts.first(where: \.active).map(accountLabel) ?? "the active account"
}
```

- [ ] **Step 6: Route the context menu through the same dialog.** In `rowMenu(_:)` from Task 2, replace `Button("Sign In Again\u{2026}") { fleet.startRelogin(a) }` with:

```swift
            Button("Sign In Again\u{2026}") { confirmRelogin = (fleet, a) }
```

- [ ] **Step 7: Title Case the chips and stop echoing raw engine states.** Replace the whole `statusChip(_:)` function (doc comment included) with:

```swift
    /// Active and health are separate facts, so both chips can show:
    /// the proxy's active credential with a stalled usage read is still
    /// the active one. Colours are semantic (green = fine, orange =
    /// needs you), never a theme's — `RowTheme` has no vocabulary for
    /// account health.
    @ViewBuilder private func statusChip(_ a: Account) -> some View {
        if a.active {
            chip("Active", .green)
        }
        if a.disabled ?? false {
            chip("On Hold", .secondary)
                .help("Rotation skips this account until you return it.")
        } else if a.usageStatus != "ok" {
            chip(Self.statusWord(a.usageStatus), .orange)
                .help(Self.statusHelp(a.usageStatus))
                .accessibilityHint(Self.statusHelp(a.usageStatus))
        }
    }

    private func chip(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    /// The chip's word. Every state the engine can report has one;
    /// anything a newer engine invents reads "Unavailable" rather than
    /// leaking `foreign_credential` into the window with its underscore
    /// swapped for a space.
    private static func statusWord(_ status: String) -> String {
        switch status {
        case "relogin_required": return "Sign-In Needed"
        case "token_expired": return "Refreshing"
        case "foreign_credential": return "Needs a Switch"
        case "keychain_unavailable": return "Keychain Locked"
        case "api_key": return "API Key"
        case "no_credentials": return "Not Signed In"
        default: return "Unavailable"
        }
    }

    /// The sentence behind the chip. Deliberately not
    /// `SentinelNotes.note(for:)`: those are the engine's own words,
    /// down to the shell command to type.
    private static func statusHelp(_ status: String) -> String {
        switch status {
        case "relogin_required":
            return "The stored sign-in expired. Sign in again to bring this account back."
        case "token_expired":
            return "The sign-in is being refreshed; this clears itself."
        case "foreign_credential":
            return "The live credential belongs to another account \u{2014} switching to this one repairs it."
        case "keychain_unavailable":
            return "The keychain is locked or busy. Unlock it, then try again."
        case "api_key":
            return "This account signs in with an API key, so there is no plan quota to track."
        case "no_credentials":
            return "This slot has no stored sign-in yet."
        default:
            return "The engine reported a state this version doesn't recognise. Updating the engine usually explains it."
        }
    }
```

- [ ] **Step 8: The name edits in place.** Replace the whole `RenameField` struct (doc comment included, the last declaration in the file) with:

```swift
/// One account's display name: text until it is clicked, then a field —
/// the pattern System Settings uses to rename a network. A plain-styled
/// `Button` rather than a tap gesture, so it takes keyboard focus and
/// VoiceOver reaches it. An account with no alias shows its EMAIL here,
/// in primary type: an empty bordered box reads as missing data.
/// The commit is on Enter or focus loss, never per keystroke — each one
/// is an engine subprocess plus a snapshot refresh.
private struct RenameField: View {
    @ObservedObject var fleet: FleetState
    let account: Account
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var display: String {
        let alias = account.alias ?? ""
        return alias.isEmpty ? account.email : alias
    }

    var body: some View {
        if editing {
            TextField("Name", text: $draft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .focused($focused)
                .onAppear { focused = true }
                .onSubmit { commit() }
                .onChange(of: focused) { if !focused { commit() } }
                .onExitCommand { editing = false }
        } else {
            Button {
                draft = account.alias ?? ""
                editing = true
            } label: {
                Text(display).lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(display)
            .accessibilityHint("Renames this account. Clearing the name goes back to the email.")
            .help("Click to rename \(display).")
        }
    }

    private func commit() {
        editing = false
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard trimmed != (account.alias ?? "") else { return }
        fleet.rename(account.number, to: trimmed)
    }
}
```

Because `detail(_:)` always shows the email in caption type and the name now falls back to the email, an aliasless account shows its address twice. Fix it in `detail(_:)` — replace its `Text(a.email)` line with:

```swift
            if let alias = a.alias, !alias.isEmpty {
                Text(a.email).lineLimit(1)
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 9: Build and look.** `swift build --product Infinitus` → succeeds. Optional dev instance (`INFINITUS_CONTROL_SOCKET=/tmp/sacct.sock`): confirm that a row with no alias shows its email once in primary type, that clicking a name turns it into a field and Escape cancels, and that only a row whose engine reports `relogin_required` carries the blue button.

- [ ] **Step 10: Commit.**

```sh
git add Sources/Infinitus/AccountsPane.swift
git commit -m "accounts: names edit in place, chips read as words, every action says its account

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Randomize Names offers Undo

Six aliases overwritten in one click with no way back is the critique's [P1] "nothing is undoable". A dialog would be the wrong fix: the action is cheap and reversible, so it gets Undo, the way Apple does for a bulk rename.

**Files:**
- Modify: `Sources/Infinitus/FleetState.swift` (ONLY `randomizeNames()` at line 230 and a new `restoreNames(_:)` immediately after it)
- Modify: `Sources/Infinitus/AccountsPane.swift` (`FleetAccountsSection` — the overflow `Menu` action from Task 2, plus new state and an undo row)
- Do not touch: everything in the "MUST NOT edit" list, and the rest of `FleetState.swift`.

**Interfaces:**
- Produces:

```swift
extension FleetState {
    @discardableResult func randomizeNames() -> [Int: String]  // number → the alias it overwrote ("" = none)
    func restoreNames(_ previous: [Int: String])
}
```

`@discardableResult` keeps the existing call sites compiling unchanged. (There are two: the overflow menu in `AccountsPane`, which now uses the value, and none elsewhere — `infinitusctl randomize-names` goes through `ControlServer.swift:377`, which calls the engine directly and does not touch this method.)

- [ ] **Step 1: Read the craft floor** (`/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`).

- [ ] **Step 2: `FleetState.randomizeNames` returns what it overwrote.** Replace the function at `Sources/Infinitus/FleetState.swift:230` (doc comment included) with:

```swift
    /// Every account gets a fresh name from the theme's pool, in one
    /// pass (user 2026-09-04 "randomize account names"). Returns the
    /// aliases it is about to overwrite — an empty string where an
    /// account had none — so the pane can offer Undo instead of asking
    /// first for something this cheap to reverse.
    @discardableResult
    func randomizeNames() -> [Int: String] {
        let previous = Dictionary(uniqueKeysWithValues:
            accounts.map { ($0.number, $0.alias ?? "") })
        let engine = engine, provider = provider
        let names = rowTheme.randomAccountNames(count: accounts.count)
        let pairs = Array(zip(accounts.map(\.number), names))
        Task {
            do {
                for (number, name) in pairs {
                    try await engine.rename(fleet: provider, number: number, name)
                }
                host.reorderError = nil
            } catch { host.reorderError = EngineFailure.sentence(error) }
            await host.refreshSnapshot()
        }
        return previous
    }

    /// Put the aliases back after a Randomize Names. An empty string
    /// clears the alias, which is exactly what the engine's rename does
    /// with one — so an account that had no name gets none back.
    func restoreNames(_ previous: [Int: String]) {
        let engine = engine, provider = provider
        let pairs = previous.sorted { $0.key < $1.key }
        Task {
            do {
                for (number, name) in pairs {
                    try await engine.rename(fleet: provider, number: number, name)
                }
                host.reorderError = nil
            } catch { host.reorderError = EngineFailure.sentence(error) }
            await host.refreshSnapshot()
        }
    }
```

- [ ] **Step 3: The pane's undo state.** In `Sources/Infinitus/AccountsPane.swift`, add to `FleetAccountsSection`'s stored properties, after `@Binding var confirmRelogin: (fleet: FleetState, account: Account)?`:

```swift
    /// The aliases the last Randomize Names overwrote, and the one-shot
    /// task that retires the offer 30 s later. A single `Task.sleep`,
    /// not a timer: nothing ticks, so an open pane still idles at ~0%.
    @State private var undoNames: [Int: String]?
    @State private var undoTask: Task<Void, Never>?
```

- [ ] **Step 4: The menu item calls through the helpers.** In `body`'s `header:`, replace `Button("Randomize Names") { fleet.randomizeNames() }` with:

```swift
                        Button("Randomize Names") { randomize() }
```

and add both helpers to `FleetAccountsSection`, next to `detail(_:)`:

```swift
    private func randomize() {
        undoTask?.cancel()
        undoNames = fleet.randomizeNames()
        undoTask = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled else { return }
            undoNames = nil
        }
    }

    private func undoRandomize() {
        undoTask?.cancel()
        undoTask = nil
        if let previous = undoNames { fleet.restoreNames(previous) }
        undoNames = nil
    }
```

- [ ] **Step 5: The undo row.** In `body`'s rows `Section`, immediately after the `if let err = model.reorderError { … }` block and before the closing `} header: {`:

```swift
            if undoNames != nil {
                HStack {
                    Text("Names randomized.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Undo") { undoRandomize() }
                }
            }
```

No animation on the appearance or the disappearance — the row is state, not motion, and this stream adds none.

- [ ] **Step 6: Build and exercise.** `swift build --product Infinitus` → succeeds. In a dev instance (`INFINITUS_CONTROL_SOCKET=/tmp/sacct.sock`, ideally with `-mock_mode` so the demo fleet takes the renames): open the section menu, Randomize Names, confirm every row's name changed and the "Names randomized. — Undo" row appeared; press Undo and confirm the previous names come back (including an account that had none going back to its email). Wait 30 s without pressing Undo and confirm the row goes away by itself.

- [ ] **Step 7: Commit.**

```sh
git add Sources/Infinitus/FleetState.swift Sources/Infinitus/AccountsPane.swift
git commit -m "accounts: Randomize Names offers Undo for 30 seconds

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Push — headers name, footers explain, secrets are labelled

The critique on this pane: a whole sentence inside a header, a caption row pretending to be a footer, two `.help()` stacked on one toggle so the AWS tooltip lands on the wrong control, two `SecureField`s whose only label is a placeholder (so an empty row reads as prose), "Configured: no" where Apple writes "Not Set Up", "Chat id", and two unconfirmed Removes.

**Files:**
- Modify: `Sources/Infinitus/NotifyPane.swift` (`NotifyPane.body`, lines 99–172; the `NotifyModel` above it changes only where noted)
- Do not touch: everything in the "MUST NOT edit" list.

**Interfaces:** none exported; one new `private struct StatusDot` local to this file.

- [ ] **Step 1: Read the craft floor** (`/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`).

- [ ] **Step 2: The status dot.** Append to the end of `Sources/Infinitus/NotifyPane.swift`:

```swift
/// Binary status the way Team and Devices already draw it: a coloured
/// dot and a word. Push showed a grey "no" (the critique's "pick one").
private struct StatusDot: View {
    let on: Bool
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(on ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(text).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 3: Declare the confirmation state.** Add to `NotifyPane`, after `@ObservedObject var app: AppModel`:

```swift
    /// "slack" or "telegram" while its Remove is being confirmed.
    @State private var confirmRemove: String?
```

- [ ] **Step 4: Replace `NotifyPane.body` wholesale** (lines 99–172):

```swift
    var body: some View {
        Form {
            Section {
                Toggle("All sessions finish working", isOn: $app.pushSessionsDone)
                Toggle("A session waits on you", isOn: $app.pushWaiting)
                Toggle("A session needs an AWS sign-in", isOn: $app.pushAwsLogin)
            } header: {
                Text("Push about sessions")
            } footer: {
                Text("Finish: one push when every live session has been idle for two "
                     + "refresh passes \u{2014} turn gaps don't count. Waits on you: one "
                     + "push per session when it stops at a permission prompt or a "
                     + "question. AWS: one push per session and profile when a command "
                     + "fails on an expired sign-in \u{2014} sign in from the phone's "
                     + "sessions list.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Toggle("All accounts are exhausted", isOn: $app.pushAllDead)
                Toggle("The last alive account nears its limit", isOn: $app.pushLastAlive)
                Toggle("An account comes back", isOn: $app.pushRevived)
            } header: {
                Text("Push about accounts")
            } footer: {
                Text("Every switch is pushed already. Last alive: one push when only one "
                     + "account still has quota and it crosses \(Int(PushTriggers.warnPct))%. "
                     + "Comes back: when an exhausted account's windows reset, named, and "
                     + "flagged when Anthropic reset it before the advertised time.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status") {
                    StatusDot(on: model.slackStatus != nil,
                              text: model.slackStatus ?? "Not Set Up")
                }
                LabeledContent("Webhook URL") {
                    SecureField("https://hooks.slack.com/\u{2026}", text: $model.webhookDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveSlack() }
                }
                HStack {
                    Button("Save Webhook") { model.saveSlack() }
                        .disabled(model.webhookDraft.isEmpty)
                    if model.slackStatus != nil {
                        Button("Remove\u{2026}", role: .destructive) { confirmRemove = "slack" }
                    }
                }
            } header: {
                Text("Slack")
            } footer: {
                Text("Infinitus posts to the incoming webhook you paste here. The URL is "
                     + "stored on this Mac, readable only by you, and shown masked.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Status") {
                    StatusDot(on: model.telegramStatus != nil,
                              text: model.telegramStatus.map {
                                  "\($0)  chat \(model.telegramChat ?? "?")"
                              } ?? "Not Set Up")
                }
                LabeledContent("Bot token") {
                    SecureField("the token BotFather gave you", text: $model.tokenDraft)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Chat ID") {
                    TextField("-1001234567890", text: $model.chatIdDraft)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Button("Save Bot") { model.saveTelegram() }
                        .disabled(model.tokenDraft.isEmpty || model.chatIdDraft.isEmpty)
                    if model.telegramStatus != nil {
                        Button("Remove\u{2026}", role: .destructive) { confirmRemove = "telegram" }
                    }
                }
            } header: {
                Text("Telegram")
            } footer: {
                Text("The bot posts into the chat whose ID you give it. Both are stored on "
                     + "this Mac, readable only by you, and shown masked.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Section {
                Button("Send Test Push") { model.test() }
                    .disabled(model.slackStatus == nil && model.telegramStatus == nil
                              && model.webhookDraft.isEmpty)
                if let message = model.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                if let err = model.errorText {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            } footer: {
                Text("Sends one push to every channel above, so you can check it arrives "
                     + "on the phone before it matters.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(confirmRemove == "slack" ? "Remove the Slack webhook?"
                                                     : "Remove the Telegram bot?",
                            isPresented: Binding(get: { confirmRemove != nil },
                                                 set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { channel in
            Button("Remove", role: .destructive) {
                model.remove(channel)
                confirmRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: { channel in
            Text(channel == "slack"
                 ? "Away pushes stop going to Slack. The webhook itself keeps working "
                   + "\u{2014} you can paste it back any time."
                 : "Away pushes stop going to Telegram. The bot and the chat are "
                   + "untouched \u{2014} you can paste the token back any time.")
        }
        .task { await model.load() }
    }
```

What that replacement fixes, so you can check each one off: the header-sentence ("Away push — tells your phone which account is live") and the caption row under it are gone, replaced by two named groups with real footers; the six toggles are split 3/3 so one footer can honestly explain each group; the stacked `.help()` bug at the old lines 121–127 disappears with the tooltips (do not re-add either one); both secret fields have a visible `LabeledContent` label; "Chat id" is "Chat ID"; "no" is "Not Set Up" with a dot; and both Removes confirm.

- [ ] **Step 5: One string in the model.** In `NotifyModel.saveTelegram()`, replace line 49 with a sentence naming the field the way the pane now does:

```swift
            errorText = "Telegram needs both a bot token and a chat ID."
```

- [ ] **Step 6: Build.** `swift build --product Infinitus` → succeeds. Then confirm the tooltips are gone from this pane: `grep -n "\.help(" Sources/Infinitus/NotifyPane.swift` → no output.

- [ ] **Step 7: Commit.**

```sh
git add Sources/Infinitus/NotifyPane.swift
git commit -m "push: named groups with footers, labelled secret fields, confirmed removes

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Profiles — an empty state that shows, not tells

The critique's "Valley 3": the first-run experience of this feature is a man page — a prose paragraph, an unlabelled field, and a footer of literal backticked shell.

**Files:**
- Modify: `Sources/Infinitus/ProfilesPane.swift` (whole file)
- Do not touch: everything in the "MUST NOT edit" list, `SessionProfilesModel.swift` included.

**Interfaces:** none new.

- [ ] **Step 1: Read the craft floor** (`/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`).

- [ ] **Step 2: Replace `ProfilesPane.body` and its state** (lines 8–43) with:

```swift
    @ObservedObject var profiles: SessionProfilesModel
    @State private var newName = ""
    @State private var expanded: Set<String> = []
    /// The profile whose Remove is being confirmed.
    @State private var confirmRemove: SessionProfile?

    var body: some View {
        Form {
            if !profiles.profiles.isEmpty {
                Section {
                    ForEach(profiles.profiles) { profile in
                        ProfileRow(profile: profile, profiles: profiles,
                                   confirmRemove: $confirmRemove,
                                   expanded: Binding(get: { expanded.contains(profile.name) },
                                                     set: { open in if open { expanded.insert(profile.name) } else { expanded.remove(profile.name) } }))
                    }
                } header: {
                    Text("Profiles")
                }
            }
            Section {
                HStack {
                    TextField("New profile name", text: $newName, prompt: Text("Review PRs"))
                        .onSubmit(add)
                    Button("Add") { add() }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let err = profiles.lastError {
                    Text(err).font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("New profile")
            } footer: {
                Text("A profile is a named way to start a session \u{2014} folder, engine, "
                     + "permissions, model, an appended system prompt and a first prompt. "
                     + "The phone offers each one as a chip in Start a session.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove \(confirmRemove?.name ?? "this profile")?",
                            isPresented: Binding(get: { confirmRemove != nil },
                                                 set: { if !$0 { confirmRemove = nil } }),
                            presenting: confirmRemove) { profile in
            Button("Remove", role: .destructive) {
                profiles.remove(profile.name)
                confirmRemove = nil
            }
            Button("Cancel", role: .cancel) { confirmRemove = nil }
        } message: { profile in
            Text("Start a session stops offering \(profile.name) on the phone and on this "
                 + "Mac. Sessions already started keep running \u{2014} you can make the "
                 + "profile again any time.")
        }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        profiles.set(SessionProfile(name: name))
        expanded.insert(name)
        newName = ""
    }
```

Both deletions matter: the prose paragraph that used to sit inside the empty group is now the New-profile footer (so it explains the field the reader is looking at), and the backticked `` `infinitusctl profiles` `` footer is gone entirely — the CLI is documented in the README, not in the window.

- [ ] **Step 3: `ProfileRow` takes the binding and asks first.** In `private struct ProfileRow`, add after `@ObservedObject var profiles: SessionProfilesModel`:

```swift
    @Binding var confirmRemove: SessionProfile?
```

and replace its Remove button (line 80) with:

```swift
                Button("Remove\u{2026}", role: .destructive) { confirmRemove = profile }
```

- [ ] **Step 4: One field label loses its parenthetical.** Replace line 71:

```swift
            TextField("Model", text: field(\.model), prompt: Text("the engine's default"))
```

(Same shape as the New-profile field two steps up — a label and a prompt, not a label carrying a parenthetical. "(e.g. opus, sonnet — blank = default)" inside the label was doing a footer's job in a label's slot.)

- [ ] **Step 5: Build.** `swift build --product Infinitus` → succeeds. Confirm the backticks are gone: `grep -n '`' Sources/Infinitus/ProfilesPane.swift` → no output.

- [ ] **Step 6: Commit.**

```sh
git add Sources/Infinitus/ProfilesPane.swift
git commit -m "profiles: the empty state explains the field instead of quoting the CLI

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Engines — Auto-switch once, Stop asks, footers explain

The critique: the cswap pane shows "Auto-switch" twice (once as a status row in the top card, once as the section the config keys generate), Stop halts rotation with no warning, "Update Now" is the only Title Case button among sentence-case peers, and five caption rows do a footer's job.

**Files:**
- Modify: `Sources/Infinitus/EnginesPane.swift` (`ClaudeEnginePane`, `CLIProxyEnginePane`, `NineRouterEnginePane`, `EngineToggleNotes`)
- Do not touch: everything in the "MUST NOT edit" list. `SettingsFormBody` lives in `SettingsPane.swift` and is not edited here.

**Interfaces:** none new.

- [ ] **Step 1: Read the craft floor** (`/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`).

- [ ] **Step 2: Declare the confirmation state.** Add to `ClaudeEnginePane`, after `@ObservedObject var reliability: ResumeReliabilityModel`:

```swift
    /// Stopping halts rotation while sessions are running, so it asks.
    @State private var confirmStop = false
```

- [ ] **Step 3: One "Auto-switch", and a Stop that asks.** Replace lines 15–27 (the first `Section`) with:

```swift
            Section {
                Toggle("Engine on (credential swap under Claude Code)", isOn: $model.cswapEnabled)
                EngineToggleNotes(model: model)
                LabeledContent("Rotation") {
                    HStack {
                        stateText
                        Button(toggleTitle) {
                            if toggleTitle == "Stop" { confirmStop = true } else { model.toggleEngine() }
                        }
                        .disabled(!togglable)
                    }
                }
            } header: {
                Text("Claude \u{2014} cswap engine")
            } footer: {
                Text("Rotating swaps the Claude account under Claude Code before a limit "
                     + "stalls a session. When it is stopped, the account in use stays put.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
```

The row is renamed "Rotation" because the section the config keys generate is already titled "Auto-switch" (`SettingsFormBody.sectionTitle`) and two groups with one name is the duplicate the critique found; "Rotation" is also what the row actually reports — whether the supervisor is running.

- [ ] **Step 4: Title Case the state words.** Replace `stateText` (lines 105–115) with:

```swift
    private var stateText: some View {
        Group {
            switch model.cswapState {
            case .running: Text("Running").foregroundStyle(.green)
            case .stopped: Text("Stopped").foregroundStyle(.secondary)
            case .refused: Text("Held Elsewhere").foregroundStyle(.orange)
            case .backingOff(let s): Text("Retrying in \(Int(s))s")
            case .schemaMismatch: Text("Update the App")
            }
        }.font(.caption)
    }
```

- [ ] **Step 5: The dialog.** Chain onto `ClaudeEnginePane.body`, after `.onAppear { … }` (line 94):

```swift
        .confirmationDialog("Stop rotating Claude accounts?", isPresented: $confirmStop) {
            Button("Stop", role: .destructive) { model.toggleEngine(); confirmStop = false }
            Button("Keep Rotating", role: .cancel) { confirmStop = false }
        } message: {
            Text("Sessions stall at their limits until you start it again. The account in "
                 + "use keeps working, and your accounts are untouched \u{2014} Start puts "
                 + "rotation back exactly as it was.")
        }
```

- [ ] **Step 6: Mock data and Engine updates get footers.** Replace the `Section("Mock data")` block (lines 28–35) with:

```swift
            Section {
                Toggle("Demo fleet (fabricated accounts)", isOn: $model.mockMode)
            } header: {
                Text("Mock data")
            } footer: {
                Text("Five made-up accounts standing in for the engine \u{2014} one burns "
                     + "ahead of pace, one is dead, rotate and reorder play along. Nothing "
                     + "reads or touches your real accounts; flipping this restarts the app.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
```

Then in the `Section("Engine updates")` block: change the opening line 41 to `            Section {` and, after the section's last statement (the `if let output = update.upgradeOutput` block ending at line 88), close it with:

```swift
            } header: {
                Text("Engine updates")
            } footer: {
                Text("Automatic updates check daily for a newer engine release, install it "
                     + "unattended and restart the engine. Nothing else changes.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
```

and delete the `.help(...)` on the "Update automatically" toggle (lines 45–47) — its backticked `cswap upgrade` is now the footer's plain sentence.

- [ ] **Step 7: Button casing in this file.** Every command button becomes Title Case, and the ellipsis stays only where something opens:
  - line 51 `Button("Update Now")` — already correct, leave.
  - line 55 `Button(update.busy ? "Checking…" : "Check for Updates…")` → `Button(update.busy ? "Checking\u{2026}" : "Check for Updates")`. A check opens nothing; the ellipsis was wrong. ("Checking…" keeps its ellipsis: it is a progress label, not a command.)
  - line 79 `DisclosureGroup("upgrade output")` → `DisclosureGroup("Upgrade output")` (a disclosure label is a noun phrase, sentence case).
  - lines 166, 269 `Button(probing ? "Testing…" : "Test connection")` → `Button(probing ? "Testing\u{2026}" : "Test Connection")`.
  - lines 168, 271 `Button("Save & restart")` → `Button("Save & Restart")`.
  - line 174 `Button("Forget key")` → `Button("Forget Key")`.
  - line 280 `Button("Forget password")` → `Button("Forget Password")`.
  - line 301 `Button("Open 9Router dashboard")` → `Button("Open 9Router Dashboard")`.

- [ ] **Step 8: The proxy and 9Router caption rows become footers.** In `CLIProxyEnginePane`, the `Section("Management API")` (line 159) becomes `Section {` … `} header: { Text("Management API") } footer: {` with the text from lines 187–190 moved into the footer as:

```swift
                Text("The key is the proxy's own management secret. It is kept in the "
                     + "keychain and sent as a bearer header; Infinitus never reads the "
                     + "proxy's config or credential files.")
                    .font(.caption2).foregroundStyle(.secondary)
```

Keep the `probe`, `engineErrors`, `fleetCaveats` and `DetectionLines.proxyLine` rows INSIDE the section — they are live state, not explanation.

Do the same to `NineRouterEnginePane`'s `Section("Dashboard API")` (line 262) with the text from lines 289–293 as:

```swift
                Text("The password is the one the 9Router dashboard asks for. It is kept in "
                     + "the keychain and exchanged for a session cookie on demand; leave it "
                     + "empty if 9Router's require-login is off. Infinitus never reads "
                     + "9Router's database or config.")
                    .font(.caption2).foregroundStyle(.secondary)
```

and to both `Section("Accounts")` blocks (lines 212 and 296): the single caption row in each becomes the footer, and the section keeps its header plus (for 9Router) the button:

```swift
                Section {
                    Button("Open 9Router Dashboard") { … unchanged … }
                } header: {
                    Text("Accounts")
                } footer: {
                    Text("9Router's connections are managed in the Accounts tab, next to "
                         + "the other engines'. Adding one is done in the 9Router dashboard "
                         + "under Providers \u{2192} Connect Claude Code.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
```

The CLIProxy one has no button, so it becomes an empty-content section — instead, delete that `Section` entirely and put its sentence in the `Routing` section's footer. Change `Section("Routing") {` (line 197) to `Section {` and close it with:

```swift
                } header: {
                    Text("Routing")
                } footer: {
                    Text("The proxy's credentials are managed in the Accounts tab, next to "
                         + "the other engines'.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
```

Keep `RoutingNotes` where it is, inside the Routing section: it is conditional live guidance, not a static footer.

- [ ] **Step 9: Build.** `swift build --product Infinitus` → succeeds. Confirm the duplicate is gone by opening Settings → the cswap engine pane in a dev instance (`INFINITUS_CONTROL_SOCKET=/tmp/sacct.sock`) and checking that "Auto-switch" appears exactly once, as the config section's title.

- [ ] **Step 10: Commit.**

```sh
git add Sources/Infinitus/EnginesPane.swift
git commit -m "engines: Auto-switch appears once, Stop asks first, tooltips become footers

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Devices — one QR, one address, three named groups

"Devices is the densest pane in the app and the first a new user must succeed at": three URLs, a QR, four Copy buttons, a masked token, two tunnel toggles, a hostname field and footers containing literal backticks and `~/.cloudflared/config.yml`.

**Files:**
- Modify: `Sources/Infinitus/SyncPane.swift` (`body` lines 45–204, `namedTunnelRows` lines 287–337, `tailscaleRow` lines 485–520)
- Do not touch: everything in the "MUST NOT edit" list; inside this file, leave `walkthrough`, `steps`, `agentBrief`, `connectedDevices`, `relative`, `probeTailscale`, `runExportPanel`, `runImportPanel` and `CrashReportsSection` alone (Task 9 takes the crash section).

**Interfaces:** none new.

- [ ] **Step 1: Read the craft floor** (`/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`).

- [ ] **Step 2: State for the disclosure and for Task 9's alert.** Add to `SyncPane`, after `@State private var walkthroughOpen = true`:

```swift
    /// The secondary addresses stay folded: one scan pairs every route,
    /// so the other two are for typing by hand, which is rare.
    @State private var otherAddressesOpen = false
    /// Regenerating un-pairs every phone, so it asks (Task 9 adds the
    /// alert itself; the button below already sets this).
    @State private var confirmRegenerate = false
```

- [ ] **Step 3: Merge "Phone companion" and "Pair a phone" into one "Pairing" section.** Replace lines 52–130 — from `            Section("Phone companion") {` through the closing `                }` of the `Section("Pair a phone")` block, i.e. up to but not including `                Section("Anywhere") {`. Note what those 79 lines contain: BOTH sections **and** the `if app.mirrorLANEnabled {` opener at line 89 that still gates the Tunnel section. The replacement therefore ends by re-opening that gate, so the `}` at line 173 still closes it:

```swift
            Section {
                Toggle("Serve the fleet to my phone", isOn: $app.mirrorLANEnabled)
                if let status = server.status {
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Pairing token") {
                    HStack(spacing: 8) {
                        Text(revealToken ? app.mirrorPairToken
                             : MirrorPairing.mask(app.mirrorPairToken))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                        Button(revealToken ? "Hide" : "Reveal") { revealToken.toggle() }
                        Button("Copy") { copy(app.mirrorPairToken) }
                        Button("Regenerate\u{2026}") { confirmRegenerate = true }
                    }
                }
                TextField("This Mac's name", text: $app.machineNameOverride,
                          prompt: Text(MachineName.system()))
                if app.mirrorLANEnabled {
                    if app.pairRoutes.isEmpty {
                        Text("Waiting for the listener to come up\u{2026}")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .top, spacing: 12) {
                            if let image = PairQR.image(for: app.pairURL) {
                                Image(nsImage: image)
                                    .interpolation(.none)
                                    .resizable()
                                    .frame(width: 110, height: 110)
                                    .padding(4)
                                    .background(.white)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                                    .accessibilityLabel("Pairing QR code")
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                if let primary = app.pairRoutes.first {
                                    addressRow(primary)
                                }
                                Button("Copy Pair Link") { copy(app.pairURL) }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 2)
                        if app.pairRoutes.count > 1 {
                            DisclosureGroup("Other addresses", isExpanded: $otherAddressesOpen) {
                                ForEach(app.pairRoutes.dropFirst()) { route in
                                    addressRow(route)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Pairing")
            } footer: {
                Text("The phone scans the code once and keeps every address in it, trying "
                     + "them in order \u{2014} so a tunnel address that changes on restart "
                     + "falls through to Wi-Fi or Tailscale. Every request must carry the "
                     + "pairing token; the snapshot it answers with carries account names, "
                     + "emails and usage estimates, never tokens or push secrets.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            // Re-opens the gate the old line 89 had: everything below
            // (Tunnel, and only Tunnel) shows once this Mac is serving.
            // The `}` at old line 173 still closes it.
            if app.mirrorLANEnabled {
```

That drops the two `.help()` tooltips on the serve toggle and the Mac-name field (their content is in the footer and in the field's own prompt), the backticked `Authorization: Bearer <token>` sentence, and the four-Copy-button route list.

- [ ] **Step 4: The address row.** Add to `SyncPane`, immediately above `private func copy(_ text: String)`:

```swift
    /// One route: its name, its address, and a Copy that says what it
    /// copies. `PairRoute.title` is already the human name ("On this
    /// Wi-Fi", "Anywhere via Tailscale").
    private func addressRow(_ route: PairRoute) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(route.title).font(.callout).bold()
            HStack {
                Text(route.endpoint)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                Button { copy(route.endpoint) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy the \(route.title) address")
                    .help("Copy the \(route.title) address.")
            }
        }
    }
```

- [ ] **Step 5: "Anywhere" becomes "Tunnel", with footers.** Replace the `Section("Anywhere") { … }` opening (line 131) with `            Section {`, and replace its closing `                }` (line 170, before `.onAppear { probeTailscale(); … }`) with:

```swift
                } header: {
                    Text("Tunnel")
                } footer: {
                    Text("Same Wi-Fi needs none of this. From anywhere, pick one: Tailscale "
                         + "on both devices, a quick tunnel (a random public address that "
                         + "changes every start), or your own Cloudflare tunnel (a hostname "
                         + "that never changes). The pairing token is what keeps the "
                         + "snapshot private in every case.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
```

Inside that section, delete the three caption `Text` blocks now covered by the footer — lines 143–147 ("The URL is public and changes every start…"), lines 155–159 ("Without this, a phone with no other route…") and the `.help(...)` on both toggles (lines 136–139 and 151–154) — but KEEP the live `tunnel.status` row (lines 140–142). Replace the "Publish the current URL" toggle's lost explanation by appending one clause to the section footer above: after "…in every case.", add:

```
Publishing the current address to infinitus.run stores only a hash of the token and the address, so a paired phone finds the new one instead of rescanning.
```

- [ ] **Step 6: The not-installed branch loses its backticks.** Replace lines 161–169 (the `} else { LabeledContent("Cloudflare quick tunnel") … }` branch) with:

```swift
                    } else {
                        LabeledContent("Cloudflare quick tunnel") {
                            Button("Copy Install Command") { copy("brew install cloudflared") }
                                .help("Copies: brew install cloudflared")
                        }
                        Text("Not installed. Paste the copied command into Terminal and a "
                             + "toggle appears here to reach this Mac through a random "
                             + "public address \u{2014} no Cloudflare account needed.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
```

- [ ] **Step 7: The named tunnel loses the config path from its body copy.** In `namedTunnelRows`, replace line 298:

```swift
                Text("Not needed \u{2014} Cloudflare's config file on this Mac already "
                     + "routes this hostname.")
                    .font(.caption).foregroundStyle(.secondary)
```

replace the `.help(...)` on the toggle (lines 290–292) with nothing (its content is in the footer below), replace `Button("Save")` (line 308) with `Button("Save Tunnel")`, `Button("Forget token")` (line 316) with `Button("Forget Token")`, and replace the closing explainer at lines 330–336 with:

```swift
        Text("Both ways need a Cloudflare account with your domain on it. In the "
             + "dashboard: Zero Trust \u{2192} Networks \u{2192} Tunnels \u{2192} Create "
             + "\u{2192} Cloudflared, name it, paste its token above, and point its public "
             + "hostname at this Mac's port \(MirrorTransport.defaultPort). In Terminal: "
             + "create and route a tunnel with cloudflared, add this hostname to its config "
             + "file, and no token is needed here.")
            .font(.caption).foregroundStyle(.secondary)
        HStack {
            Button("Copy the Config File Path") { copy("~/.cloudflared/config.yml") }
                .help("Copies: ~/.cloudflared/config.yml")
            Spacer()
        }
```

The path is still one click away, in the place a person who needs it will look — and no longer in a sentence a first-time reader has to step over.

- [ ] **Step 8: Tailscale's caption rows keep their shape but lose their tooltip voice.** In `tailscaleRow`, change line 490 `Button("Get Tailscale…")` to `Button("Get Tailscale\u{2026}")` (already correct — it opens a web page, keep the ellipsis) and line 500 `Button("Open Tailscale")` (no ellipsis, it opens an app — leave). Change line 504 `Text("installed, not connected")` to `Text("Installed, not connected")` and line 512 `Text("connected \u{00B7} \(ip)")` to `Text("Connected \u{00B7} \(ip)")`. The three caption `Text`s under the rows stay as they are: they are per-state guidance inside a section whose footer already covers the general case.

- [ ] **Step 9: The remaining three sections get footers instead of captions.** `Section("Phone lock screen")` (line 175) becomes `Section { liveActivityRows } header: { Text("Phone lock screen") } footer: { … }` with the first paragraph of `liveActivityRows` (lines 222–227) moved into the footer verbatim and deleted from the body. `Section("iCloud")` (line 178) keeps its live `sync.status` row and moves the toggle's `.help` (lines 180–183) into a footer:

```swift
            } header: {
                Text("iCloud")
            } footer: {
                Text("Display preferences, custom themes and engine settings travel through "
                     + "one file in your iCloud Drive. Never credentials, never push "
                     + "secrets. The last Mac to write wins.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
```

`Section("File")` (line 190) keeps its buttons and turns its caption (lines 197–200) into the same shape of footer, with `Button("Export…")` / `Button("Import…")` unchanged (both open a panel, so both keep the ellipsis).

Inside `liveActivityRows`, finish the casing sweep for this file:
- line 231 `Button(pusher.keyStored ? "Replace .p8 from clipboard" : "Paste .p8 from clipboard")` → `Button(pusher.keyStored ? "Replace Key from Clipboard" : "Paste Key from Clipboard")`;
- line 235 `Button("Forget key")` → `Button("Forget Key")`;
- line 237 `Text(pusher.keyStored ? "key in the keychain" : "no key yet")` → `Text(pusher.keyStored ? "In the keychain" : "Not Set Up")` — the same two words Push now uses for the same fact.

And one line inside the walkthrough, which is otherwise untouched by this stream: line 394 `Button("Copy for an AI agent")` → `Button("Copy for an AI Agent")`. Change nothing else in `walkthrough`, `steps` or `agentBrief`.

- [ ] **Step 10: Build and look.** `swift build --product Infinitus` → succeeds. In a dev instance (`INFINITUS_CONTROL_SOCKET=/tmp/sacct.sock`) open Settings → Devices: one QR, one named address with one Copy, "Other addresses" folded, three named groups below it. Then prove the copy is clean:

```sh
grep -n '`\|cloudflared\|config\.yml' Sources/Infinitus/SyncPane.swift
```

Every remaining hit must be inside `agentBrief` (lines ~415–469, agent-facing by design) or a `.help(...)` on a Copy button.

- [ ] **Step 11: Commit.**

```sh
git add Sources/Infinitus/SyncPane.swift
git commit -m "devices: one QR and one address up front, the rest behind a disclosure

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: Devices — Regenerate asks, and the crash rows announce themselves

`SyncPane.swift:72` un-pairs every phone on a click, warned only by a hover tooltip; `SyncPane.swift:581` deletes a crash report with no confirmation, no `.help()` and no label — the weakest of the six icon-only buttons the mechanical pass found.

**Files:**
- Modify: `Sources/Infinitus/SyncPane.swift` (`SyncPane` state + `body`'s modifiers; `CrashReportsSection` lines 547–587)
- Do not touch: everything in the "MUST NOT edit" list; inside this file, `agentBrief`, `steps`, `walkthrough` and `connectedDevices`.

**Interfaces:** none new.

- [ ] **Step 1: Read the craft floor** (`/Users/deathemperor/.claude/skills/impeccable/reference/craft-floor.md`).

- [ ] **Step 2: The Regenerate alert.** Task 8 declared `@State private var confirmRegenerate = false` and wired the button to it; this step adds the alert. It is an `.alert` rather than a `confirmationDialog` because it needs a message body on a pane-level action, the way `TeamPane.swift:39` does. Chain it onto `body`, right after `.formStyle(.grouped)` (line 203):

```swift
        .alert("Regenerate the pairing token?", isPresented: $confirmRegenerate) {
            Button("Regenerate", role: .destructive) { app.regeneratePairToken() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every phone paired with this Mac stops working until it scans the new "
                 + "code. Nothing else changes \u{2014} this Mac keeps serving, and one "
                 + "scan pairs a phone again.")
        }
```

and delete the `.help("Every paired phone must scan again.")` that used to hang off the Regenerate button — the alert says it, at the moment it matters.

- [ ] **Step 3: The crash rows.** Replace the two buttons in `CrashReportsSection` (lines 575–583) with:

```swift
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report.transcript, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Copy the report from \(crashWhen(report))")
                    .help("Copy the report.")
                    Button(role: .destructive) { confirmDelete = report } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Delete the report from \(crashWhen(report))")
                    .help("Delete this report from this Mac.")
```

The state must NOT live on `CrashReportsSection`: a presentation modifier on a `Section` fires once per row, because `Section` distributes modifiers to its children. Put it on `SyncPane`, exactly as `AccountsPane` does with `confirmDelete`.

Add the helper at file scope in `SyncPane.swift`, immediately above `private struct CrashReportsSection: View {`:

```swift
/// How a crash report is named in a sentence: the moment it happened.
private func crashWhen(_ report: CrashReport) -> String {
    report.at.formatted(date: .abbreviated, time: .shortened)
}
```

(Confirm the element type: the `ForEach(app.crashReports.prefix(10))` rows are `CrashReport` from `Sources/InfinitusCore/CrashReport.swift`. If the concrete type differs, use whatever `app.crashReports`'s `Element` is — do not change the model.)

Add to `SyncPane`, after `@State private var confirmRegenerate = false`:

```swift
    /// The crash report whose Delete is being confirmed. Lives here, not
    /// on CrashReportsSection, so the dialog can sit on the Form.
    @State private var confirmCrashDelete: CrashReport?
```

pass it down — replace `CrashReportsSection(app: app)` (line 174) with:

```swift
            CrashReportsSection(app: app, confirmDelete: $confirmCrashDelete)
```

and declare the binding on `CrashReportsSection`, after `@ObservedObject var app: AppModel`:

```swift
    @Binding var confirmDelete: CrashReport?
```

Then give the section its header and footer — replace its `Section("Crash reports") {` opening with `        Section {` and its closing `        }` with:

```swift
        } header: {
            Text("Crash reports")
        } footer: {
            Text("Nothing leaves this Mac. Send one into a live session to have it looked "
                 + "at, or copy it to read yourself.")
                .font(.caption2).foregroundStyle(.secondary)
        }
```

and put the dialog on the Form, in `SyncPane.body`, chained after the Regenerate `.alert` from Step 2:

```swift
        .confirmationDialog("Delete this crash report?",
                            isPresented: Binding(get: { confirmCrashDelete != nil },
                                                 set: { if !$0 { confirmCrashDelete = nil } }),
                            presenting: confirmCrashDelete) { report in
            Button("Delete", role: .destructive) {
                app.removeCrash(report.id)
                confirmCrashDelete = nil
            }
            Button("Cancel", role: .cancel) { confirmCrashDelete = nil }
        } message: { report in
            Text("The report from \(crashWhen(report)) is gone from this Mac for good. The "
                 + "crash it describes has already happened \u{2014} deleting it changes "
                 + "nothing else.")
        }
```

(`CrashReport` is `Identifiable`, so the `presenting:` overload applies here even though the Accounts tuple could not use it.)

- [ ] **Step 4: The "Send to session" menu says what it does.** Replace line 566 `Menu("Send to session") {` with:

```swift
                    Menu("Send to Session") {
```

Leave the `if sessions.isEmpty { Text("No live sessions") }` row below it exactly as it is.

- [ ] **Step 5: Build.** `swift build --product Infinitus` → succeeds. Then prove every icon-only button in this file is labelled:

```sh
grep -n 'Image(systemName:' Sources/Infinitus/SyncPane.swift
```

Each hit inside a `Button` label must have an `.accessibilityLabel` within the following five lines (the QR `Image` is not a button and carries its own label from Task 8).

- [ ] **Step 6: Commit.**

```sh
git add Sources/Infinitus/SyncPane.swift
git commit -m "devices: regenerating the token and deleting a report both ask first

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: CHANGELOG and the full gate (last task)

**Files:**
- Modify: `CHANGELOG.md` (the `### Mac` list under `## 0.4.4 (unreleased)`)
- Do not touch: everything in the "MUST NOT edit" list, `site/` and `README.md` included.

- [ ] **Step 1: The lines.** Insert at the TOP of the `### Mac` list — immediately after the `### Mac` header line and before the existing "Machine: the pip retry-loop warning…" line. One short sentence each, no `Settings:` prefix (the section is already named, and none of the lines under it carries one):

```
- Settings › Accounts leads with Add Account, shows Sign In Again only on the account that needs it, and renames an account by clicking its name.
- Randomize Names can be undone for 30 seconds.
- Regenerating the pairing token, stopping rotation, signing in again, and removing a push channel, a profile or a crash report all ask first.
- Settings › Devices puts one QR code and one address up front, with the rest behind Other addresses.
- Every icon button in Settings says what it does and to which account, and an engine error now reads as a sentence with a next step.
```

- [ ] **Step 2: The full gate**, in this order, from the worktree root:

```sh
swift test
swift build --product Infinitus
```

Both must succeed. (`swift build` takes ONE `--product` per invocation — with two flags SwiftPM builds only the last.) There is no app test target, so the pane changes are gated by the build plus the per-task dev-instance checks; `tools/e2e.sh` belongs to another round and is not run here.

- [ ] **Step 3: Commit.**

```sh
git add CHANGELOG.md
git commit -m "changelog: settings polish for accounts, push, profiles, devices and engines (0.4.4)

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## Self-review

- **Coverage against the stream brief.** (1) Accounts hierarchy — Tasks 2 and 3 cover every clause: gated `Sign In Again…` with the context-menu fallback, prominent `Add Account…` in its own footed Section, `Randomize Names` in the section `Menu` with `Re-roll Name` in the row menu, the paragraph deleted into hints and a one-clause footer, click-to-edit alias with the email in primary type when there is none, Title Case chips with `Unavailable` for unknown states, the plan chip kept, the headroom toggle deleted here and re-added by the shell stream, the hard-coded row height gone (with a `@ScaledMetric` fallback if the un-nesting cannot drag), and `.accessibilityLabel` on all five row controls. (2) Confirmations — Regenerate (T9, `.alert`), Randomize → Undo (T4), Stop engine (T7), Sign In Again with the brief's exact sentence (T3), Remove Slack / Remove Telegram (T5), Remove profile (T6), delete crash report with label and help (T9). (3) Copy — PR #312 and every user-visible "cswap" gone from these panes (T2), Devices footers without backticks and with the config path behind a Copy tooltip (T8), Profiles' empty state as a footer plus an example prompt (T6), "Not Set Up" with a status dot (T5), `LabeledContent` on both secret fields (T5), "Chat ID" (T5), five `"\(error)"` sites mapped (T1), the stacked `.help` bug removed with the tooltips (T5), Title Case commands enumerated per file (T2 step 7, T5, T7 step 7, T8, T9), Auto-switch once (T7). (4) Devices density — Pairing / Tunnel / Crash reports with footers, one QR, one primary address, an "Other addresses" disclosure, token masked with Reveal (T8, T9).
- **Ordering.** Task 1 lands `EngineFailure` before Tasks 4 and 7 call it. Task 2 restructures `AccountsPane` before Tasks 3 and 4 edit inside it, and Tasks 3 and 4 anchor on code strings rather than HEAD line numbers for that reason. Task 8 declares BOTH `@State` lines (`otherAddressesOpen` and `confirmRegenerate`) so its own build check passes; Task 9 only adds the alert that reads the second one.
- **Presentation modifiers never sit on a `Section`.** `Section` distributes modifiers to its children, so a `.alert`/`.confirmationDialog` on one fires per row. All four dialogs this stream adds to a multi-row pane follow the repo's existing `confirmDelete` precedent: `@State` on the pane, `@Binding` into the section, the modifier on the `Form` (Accounts sign-in, T3; crash-report delete, T9). The single-instance ones (Push's Remove, Profiles' Remove, Engines' Stop, Devices' Regenerate) are already on their `Form`.
- **Perf.** Nothing added ticks: the Undo offer is one `Task.sleep`, cancelled on re-randomize; no `TimelineView`, no `repeatForever`, no animation of any kind is introduced, so there is nothing for `accessibilityReduceMotion` to gate in this stream.
- **Ownership.** No edit outside the table. `FleetState.swift` is touched in exactly two places (three error strings in T1, the randomize pair in T4) and `CHANGELOG.md` only in T10.

## Design decisions made while writing this plan

The orchestrator rules on these; each is implemented as described above.

1. **`Add Account…` gets its own trailing `Section` per fleet.** One `Section` cannot carry two footers, and the brief asks for both "Drag to set the rotation order." on the rows and a one-clause footer on the add button. A trailing action group is what System Settings does under a Users list.
2. **The nested `List` un-nests rather than keeping a computed height.** "Row height is no longer hard-coded" cannot be met by deleting the literal alone — the `List` is why the literal exists. A verified fallback (`@ScaledMetric` row height) is written into Task 2 Step 10 in case the drag does not survive.
3. **Row accessibility uses `.combine` on the non-interactive detail only**, not on the whole row: combining a row that contains four buttons and an editable name would make all five unreachable. The name is a `.plain` `Button` (focusable, VoiceOver-reachable) rather than a tap gesture, and the slot number keeps its own `.accessibilityLabel("Slot 3")` rather than being hidden.
4. **Status chip vocabulary is authored here, not taken from `SentinelNotes`.** The engine's own notes end in "run: cswap add". Words: Sign-In Needed / Refreshing / Needs a Switch / Keychain Locked / API Key / Not Signed In / Unavailable.
5. **Chips stay semantically coloured, not themed.** `RowTheme` has no account-status vocabulary and this stream does not invent new `RowTheme` fields.
6. **The duplicate "Auto-switch" is resolved by renaming the status row to "Rotation"**, keeping the config-generated section's title, because that section is literally the `autoswitch.*` keys.
7. **"Check for Updates…" loses its ellipsis** (it opens nothing); "Add Another…" and "Try Again…" gain one (they open the sign-in window); "Remove…" gains one everywhere it now opens a dialog.
8. **`"Starting claude setup-token…"` is corrected to "Starting Claude's sign-in…"** — the flow runs `claude auth login`, so the old string was factually wrong as well as engineer-facing.
9. **Push's six toggles split into two named sections** ("Push about sessions", "Push about accounts") because one footer cannot honestly explain six unrelated triggers. The stacked-`.help` bug disappears with the tooltips rather than being separately patched.
10. **`.help(entry.key)` is dropped from the cswap config rows** — a tooltip showing a config key on a labelled control is the wrong container for the wrong content.
11. **`EngineFailure` lives in `SettingsPane.swift`.** Five call sites across five files in one module need it; every file this stream owns is a pane, and `SettingsPane.swift` is the least surprising home. It maps `EngineError`, `CLIError`, `DecodingError`, the two Cocoa/POSIX file cases and four `URLError`s, with "Couldn't save — try again." as the fallback the brief asked for.
12. **`FleetState`'s three `"\(error)"` sites are fixed in Task 1**, slightly beyond "the minimal hook for Undo": they are the source of the red text `AccountsPane` renders, so leaving them would leave a raw `CLIError` on the pane this stream is polishing. Three single-line changes, no signature change.
13. **"Copy Pair Link" survives the Devices reduction** (one QR + one address + a disclosure): it is the manual-entry path, and it copies something none of the address rows do.
14. **The Cloudflare config path moves to a "Copy the Config File Path" button's tooltip**, per the brief, rather than being deleted — a person setting up a named tunnel does need it.
15. **`SyncPane`'s `agentBrief`, its 5 s `TimelineView` and its 3 s tailnet re-probe are left alone**, as is `SessionProfilesModel`'s already-sentence error string: all pre-existing, none in the brief's must-cover list.
16. **One line inside the otherwise-untouched Devices walkthrough is changed** — `Button("Copy for an AI agent")` → `"Copy for an AI Agent"` — so the file's casing sweep is complete. Everything else in `walkthrough`, `steps` and `agentBrief` stays byte-for-byte.
17. **The Live Activity key status reuses Push's words** ("In the keychain" / "Not Set Up") rather than inventing a third spelling of the same binary fact.
