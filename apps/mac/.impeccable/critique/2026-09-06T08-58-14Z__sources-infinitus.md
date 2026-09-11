---
target: Settings (Sources/Infinitus)
total_score: 22
max_score: 40
na_heuristics: 
p0_count: 2
p1_count: 3
target_identity: "file:/Users/deathemperor/death/limitless-e2/Sources/Infinitus"
timestamp: 2026-09-06T08-58-14Z
slug: sources-infinitus
---
Method: dual-agent (A: design review with 17 live Mac captures + full source · B: mechanical scan + iOS simulator build)

Surface: Settings on both platforms. Mode: Operate. Reference: Apple System Settings (macOS) and iOS Settings.
Evidence caveat: the iOS build ran on a simulator but the Settings tab could not be driven (no named accessibility elements, taps did not register), so iOS findings are source-grounded plus one launch capture; Mac findings are screenshot-grounded.

## Design Health Score

### macOS Settings window — 22/40 (Acceptable, significant work needed)

| # | Heuristic | Score | Key issue |
|---|---|---|---|
| 1 | Visibility of system status | 3 | Live engine dot, chips, sample times are good. Window is titled "Infinitus", never "Settings" or the pane name (StatusItemController.swift:640). Search has no result count and no empty state. |
| 2 | Match system / real world | 2 | Engineer-speak ships: "Stars need a cswap with the autoswitch.preferred setting (claude-swap PR #312)" (AccountsPane.swift:784); "(CodexBar does the same)" (AboutPane.swift:441); backticks and `~/.cloudflared/config.yml` in Devices; Profiles' empty state is a man page; Utilization's emoji are un-legended column keys. |
| 3 | User control and freedom | 2 | Nothing undoable. "Randomize names" rewrites six aliases in one click (AccountsPane.swift:677). |
| 4 | Consistency and standards | 2 | Three explanation mechanisms used at random: 51 `.help()` tooltips, caption `Text` rows inside cards, real Section headers. Lowercase values where Apple title-cases: `no`, `active`, `held`, `all set`, `not set`. Button casing mixed: "Update Now", "Turn Off" vs sentence case elsewhere; "Chat id". |
| 5 | Error prevention | 2 | Confirmations are on the recoverable actions (Remove account, Leave team, Turn off lock) and missing on the unrecoverable ones: Regenerate pairing token (SyncPane.swift:72) un-pairs every phone with only a tooltip; Randomize names; Stop engine (EnginesPane.swift:118); Relogin (clobbers the active credential); Remove Slack/Telegram (NotifyPane.swift:138,154); Remove profile (ProfilesPane.swift:78); delete crash report (SyncPane.swift:581). |
| 6 | Recognition over recall | 2 | Themes is a 4: thirteen live previews. Everything else is recall: five icon-only actions per account row whose meaning lives in a tooltip; search cannot find a setting by its own label. |
| 7 | Flexibility and efficiency | 2 | Sidebar is a ScrollView of Buttons (InfinitusApp.swift:358): no arrow keys, no type-select, no focus ring, no ⌘F. Search matches 6–8 hand-written keywords per tab; "transparency", "checkpoint", "keep awake", "start at login" return nothing. Drag-to-reorder and "Re-roll name" are real accelerators. |
| 8 | Aesthetic and minimalist | 2 | A ~700pt column centred in an 1800pt window (Lock: one card, 96% empty). Display: two unlabeled cards of 8 and 13 controls (DisplayPane.swift:18–93, 104–166). Stats' 13-tile grid leaves an orphan tile. PickTile, theme cards and the About hero are beautifully made. |
| 9 | Error recovery | 2 | `"\(error)"` reaches the UI in NotifyPane.swift:88 and SettingsPane.swift:31,47,53: a CocoaError debug string in red with no next step. |
| 10 | Help and documentation | 3 | The help is plentiful and well written, and hidden in hover tooltips. No footers where Apple would put them. |

### iOS Settings tab — 23/40 (Acceptable, significant work needed)

| # | Heuristic | Score | Key issue |
|---|---|---|---|
| 1 | Visibility of system status | 3 | Transport status line and themed loading words are good; no progress while "Update the Mac" runs. |
| 2 | Match system / real world | 3 | Plainer copy than the Mac. Leaks: raw monospaced `host:port` rows; "from the Mac's Devices settings" as a placeholder. |
| 3 | User control and freedom | 2 | Swipe-to-Forget a paired Mac (SettingsScreen.swift:148) is destructive with no confirmation, while the harmless "Make primary" confirms (:202). Risk inverted. |
| 4 | Consistency and standards | 2 | Half the sections use a real footer, half fake it with a caption row inside the group (:34, :171, :178, :185); the first section has no header. Theme and Dictation pickers are navigationLink, Pace fire / Content entrance / Title flourish are menus. |
| 5 | Error prevention | 2 | The pairing token, a bearer credential for the whole fleet, is a plain TextField (:130), not a SecureField. Unconfirmed Forget. |
| 6 | Recognition over recall | 1 | The theme chooser (:43–49) is thirteen names; the preview appears only after choosing and shows two gauges of a theme that changes ~20 things. |
| 7 | Flexibility and efficiency | 2 | No search across 11 sections; delete is swipe-only. "Follow Mac" collapsing the cosmetics block is the best structural idea on either platform. |
| 8 | Aesthetic and minimalist | 3 | Default inset-grouped Form is right; 4–6-line caption blocks inside groups undermine it. |
| 9 | Error recovery | 2 | `error.localizedDescription` with no retry; a failed pairing means re-typing a token. |
| 10 | Help and documentation | 3 | Where footers exist they are excellent (Dictation adapts to OS version and language). |

## Design specificity verdict

Authored in three places, interchangeable everywhere else. RowTheme is a vocabulary system, not a palette: it renames gauges, statuses, placeholder copy and the phone's tab bar (the simulator capture shows "Posses · Ranch · Outfit · Saddlebag" under Wild West). The Mac Themes pane renders all thirteen as live rows; PickTile draws real miniatures of the popup shapes. Around those, the container is a generic menu-bar-app settings shell, and Settings itself never speaks the theme: an account "held" under Wild West still says "held".

Deterministic scan: the bundled detector is web-only and found no scannable files (exit 0). The native mechanical pass found: zero `accessibilityLabel` across all 21 Mac pane files, with six icon-only buttons (AccountsPane.swift:720,734,745,763; SyncPane.swift:575,581); `accessibilityReduceMotion` honoured in 0 Mac files vs 6 iOS files; the destructive-without-confirmation sites above; a stacked `.help()` bug in NotifyPane.swift:121–127 where the AWS-login tooltip lands on the wrong toggle. No false positives worth noting; no browser overlay applies to native.

## Overall impression

The product has a strong, unusual point of view, and Settings is where it goes quiet. The peak is the Mac Themes pane. The valley is the Accounts pane the user photographed: six identical "Relogin" buttons, six bordered name fields, thirty 13pt icon targets and a 59-word paragraph, for the screen that is the fleet. The single biggest opportunity is to make Settings speak the theme and to give every chooser the treatment Themes already has.

## What's working

- The Themes pane: thirteen live rows built from the real components, side by side. This is the model for every other chooser.
- Destructive copy where it exists: "The Claude account itself is untouched — you can add it back any time." That is HIG-grade writing.
- "Follow Mac" on iOS: one switch hides the whole cosmetics block. Textbook progressive disclosure.
- PickTile miniatures in Display and the About hero: hand-made, product-specific, correct.

## Priority issues

**[P0] The iOS theme chooser hides what is being chosen.** `Picker("Theme")` with `.pickerStyle(.navigationLink)` pushes thirteen `Text(theme.name)` rows; `ThemePreviewRow` shows two gauges, after the fact, on the previous screen. A theme changes labels, four colours, the cash icon, model aliases, status words, placeholder copy and motion, and the tab bar's names and icons. Fix: replace the picker with a pushed list whose every row is the preview, one per theme with a checkmark, exactly like the Mac; widen the preview to the credit line and cash icon, a live mock of the four tab-bar items, one session status word, and two names from the theme's pool ("Names like: Outlaw, Ranch hand"). Apply the same rule to Pace fire and Launch intro: an animated tile per option. Command: `/impeccable shape` then `/impeccable delight`.

**[P0] The Mac app has no accessibility labels and no keyboard path.** Live check: every sidebar row and every account-row action announces as "button". Fix: `.accessibilityLabel` on all 18 sidebar rows and the 6 icon buttons, naming the account ("Remove death2nd"); move tooltip text into `.accessibilityHint`; replace the hand-rolled sidebar ScrollView with `List(selection:)` for arrow keys, type-select and focus ring in one change. Command: `/impeccable audit`.

**[P1] Accounts has no hierarchy; its loudest element is its rarest action.** "Relogin" is a bordered button on every row (AccountsPane.swift:759); "Add account…" sits below "Randomize names" at equal weight (:830); the explainer paragraph is inside the section above the rows (:776–795); an account without an alias shows an empty "Name" box (:934); chips are lowercase; the first row is a Display setting ("Popup sorts rows by headroom", :645); row height is hard-coded at 30pt (:671). Fix: show "Sign In Again" only on rows where `usageStatus == "relogin_required"`, as the prominent button, and keep the always-available version in the row's context menu; promote "Add account…" to `.borderedProminent`; demote Randomize into a section menu; delete the paragraph (its content becomes hints and a one-clause footer); render the alias as text that edits on click, showing the email in primary type when there is none; Title Case the chips and map unknown engine states to one word; move the sort toggle to Display. Command: `/impeccable layout` then `/impeccable clarify`.

**[P1] Confirmation is inverted, and a credential is in the clear.** Unconfirmed: Regenerate pairing token, Randomize names, Stop engine, Relogin, Remove Slack/Telegram, Remove profile, delete crash report, iOS Forget. Confirmed: the recoverable ones. Plus the iOS pairing token in a plain TextField. Fix: `confirmationDialog` naming the consequence in the house voice on all eight; an Undo for Randomize instead of a dialog; `SecureField` with a reveal for the token. Command: `/impeccable harden`.

**[P1] The shell: decorative search, a flat 18-row sidebar, and a 700pt column in an 1800pt window.** Search never sees setting labels, has no clear button and no "No Results" state, and `current` reads from `tabs` not `filtered` (InfinitusApp.swift:320–330), so filtering out the selected pane leaves its content on screen with nothing highlighted. Five sidebar destinations (Usage, Utilization, Stats, Machine, Activity) are dashboards, not settings. Fix: index every pane's labels and show matching rows under their pane, scroll-and-highlight on select; move the dashboards behind the popup or their own window; group the remaining 13 into labeled sections; either cap the window width or use the width for a two-column form; title the window "Settings" with the pane as subtitle. Command: `/impeccable distill`.

**[P2] Explanations live in three containers.** 51 tooltips, caption rows inside cards, and headers with whole sentences ("Away push — tells your phone which account is live"). Fix: one rule, Apple's: header names the group, footer explains consequences, tooltip only for icon buttons. Same on iOS: convert the four caption rows to `Section(footer:)`. Command: `/impeccable clarify`.

**[P2] Copy that should not ship.** PR numbers, a competitor's name, backticked CLI in empty states, "osascript fallback", "no" for "Not Set Up", `"\(error)"` in four places. Command: `/impeccable clarify`.

## Persona red flags

- Alex (power user, six accounts): no keyboard navigation in the sidebar, no ⌘F; typing "transparency" blanks the sidebar and leaves Accounts on screen; holding account 5 means hovering five identical icons to read tooltips, so `infinitusctl hold` beats the GUI.
- Jordan (first day): lands on Display with 21 unexplained switches, two of which cost money or write to the repo; reads 59 words about dragging for an empty list; stars an account and is handed "claude-swap PR #312"; on the phone, Settings is called "Saddlebag" and opens on a theme picker before "Scan the Mac's QR code".
- Sam (VoiceOver): cannot use Mac Settings at all; on iOS the caption rows are announced as list items between controls.
- Minh (solo dev, phone from the couch): picks a theme blind thirteen times and never learns the tab bar changed; his fleet token is readable on the lock-less Settings screen; a swipe forgets the wrong Mac with no undo; "Regenerate" on the Mac un-pairs the phone in his pocket.

## Minor observations

- NotifyPane.swift:121–127: two stacked `.help()` on one toggle; the AWS-login tooltip shows on "An account comes back" and the AWS toggle has none.
- Push's webhook and bot-token SecureFields use the placeholder as the only label; empty rows read as static text (capture confirms).
- Push shows status as grey "no"; Team and Engines use a coloured dot. Pick one.
- About hosts Update channel and Notification delivery; neither is "about". The cswap pane shows Auto-switch twice.
- Devices is the densest pane in the app and the first a new user must succeed at: three URLs, a QR, four Copy buttons, two tunnel toggles, a hostname field and backticked footers.
- ThemeCard previews sit in a horizontal ScrollView that no one will discover; wide themes should wrap or scale. Previews never show the name pool "Randomize names" draws from.
- Stats: 13 tiles in a 4-column grid leaves an orphan.
- iOS endpoint rows are unlabeled monospaced strings with an invisible swipe-to-delete and no EditButton.
- Team shows the store URL raw and a leaderboard of one.
- Mac honours Reduce Motion nowhere; iOS does in six files.

## Questions to consider

1. Why isn't Settings themed, when the theme already knows the user's vocabulary?
2. Should Usage, Utilization, Stats, Machine and Activity be in Settings at all?
3. If a lapsed credential is already known, why is "Relogin" permanent on every row?
4. The Mac shows thirteen live previews and the phone thirteen words. What else is solved on one platform and a placeholder on the other?
5. If search indexed the ~120 real settings, would the sidebar still need grouping?
6. Fifty-one tooltips are better written than the labels. What does the window look like when a third of them become footers?
