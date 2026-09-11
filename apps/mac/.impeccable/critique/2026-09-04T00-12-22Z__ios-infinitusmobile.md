---
target: the mobile UIs
total_score: 22
max_score: 40
na_heuristics: 
p0_count: 1
p1_count: 4
timestamp: 2026-09-04T00-12-22Z
slug: ios-infinitusmobile
---
Method: dual-agent (A: design review sub-agent over the SwiftUI sources + the user's phone screenshot · B: static-evidence sub-agent; simulator build succeeded, screenshots not taken). Detector: `[]` — the web-markup scanner has nothing to read in SwiftUI, so B's evidence is grep-level counts with file:line.

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|---|---|---|
| 1 | Visibility of System Status | 3 | Offline/error text lives as a caption at the bottom of the feed list, off-screen when scrolled up; no loading state on a feed's first load |
| 2 | Match System / Real World | 2 | `pid 41231` in every session row; `Kind: interactive`, `Status: busy` raw enums; "sent as a message (no terminal)"; dev strings (INFINITUS_MIRROR_PATH, Bonjour, tunnel) shown to end users |
| 3 | User Control and Freedom | 2 | Permission Yes/No fires on one tap, no undo; sent message can't be recalled; AWS Close mid-flow leaves the Mac CLI running with no cancel |
| 4 | Consistency and Standards | 2 | Three status-word systems; two settings surfaces plus a shell-replacing "Show as Mac popup" toggle; Outlook reachable two ways |
| 5 | Error Prevention | 1 | Prominent blue `Yes` beside `No`, command not restated next to the buttons, buttons attached only to the last item so auto-scroll moves them; question options are bare buttons with no selection state |
| 6 | Recognition Rather Than Recall | 2 | Session detail is reachable only by tapping the three-line nav title (caption2 text as a tap target); who's next is a theme glyph |
| 7 | Flexibility and Efficiency | 3 | Copy-path/email context menus, pull-to-refresh, scroll-to-newest, Paste Image; no waiting filter, no badge, no quick answer from the Live Activity |
| 8 | Aesthetic and Minimalist Design | 2 | One capsule per tool call with ~35 pt of dead space each; the nav title stacks three lines and the third clips; session rows pack four lines |
| 9 | Error Recovery | 2 | Result strings are grey captions in the same style as success; up to three red error lines can stack under the composer; no retry affordance outside AWS |
| 10 | Help and Documentation | 3 | Good explainer footers but 55–60 words each; the empty state describes a path in prose instead of offering the QR scanner |
| **Total** | | **22/40** | **Acceptable (55%)** |

## Design Specificity Verdict

**LLM assessment:** two apps in one skin. The session feed and the Live Activities are authored for this product — tool capsules, permission and question cards, sub-agent cards, themed gauge rows, the revival countdown. The shell around them (Fleet tab, Sessions list, Session detail, Outlook, Settings) is a stock inset-grouped List/Form whose only identity is imported from the Mac's row vocabulary. The lock screen is the most phone-native surface in the codebase; the Fleet tab it feeds is less glanceable than the lock screen.

**Deterministic scan:** the detector returned `[]` (no scannable web files). Static evidence from B over 22 files / 4,452 lines: 2 fixed font sizes (AwsLoginScreen 213, 273) against 82 Dynamic Type styles; 3 accessibility labels and 0 hints across 37 buttons, with 3 image-only buttons unlabeled (FleetScreen 31 gear, SessionFeedScreen 292 send, 354 attachment remove); 39 hard-coded system-color lines, the status→color map hand-written at SessionsScreen 167–171; 0 reduce-motion checks against 4 `withAnimation` sites; sub-44 pt hit areas on the gear, send and remove buttons; no empty/loading state on SessionFeedScreen or SessionDetailScreen; jargon strings at SessionDetailScreen 71/76 (pid), SessionsScreen 195 (pid), SessionFeedScreen 500 ("no terminal"), FleetScreen 94–97 and NativeFleetScreen 71–73 (mirror-snapshot.json, INFINITUS_MIRROR_PATH), SettingsScreen 121–128 (Bonjour/tunnel/route); 8 interpolated numbers without monospaced digits in lists. Agreement: A and B both land on the unlabeled send button, the pid leak, the missing reduce-motion gate and the feed's missing states. Stale finding: A's "errors are not coalesced" in tool runs reads the screenshot, which predates f7cb11e; the Core now folds error results into the run with a count, so the phone gets it on its next build.

**Visual overlays:** none (native app). Simulator screenshots were not taken because I stopped B after its build succeeded; the build itself is green. B's note for a rerun: `SIMCTL_CHILD_INFINITUS_TAB=sessions xcrun simctl launch booted com.huuloc.infinitus.mobile` reaches each tab without taps.

## Overall Impression
The parts that only a phone can do — the lock-screen activities, the AWS sign-in from the couch, the chat with attachments and dictation — are well built. The parts a phone should do best — a one-second glance at who's working and who needs me — are buried under Mac-density rows and a tool-call feed that spends 85% of the screen on truncated shell lines. The biggest single risk is the permission approval: a real shell command on the Mac, approved by one thumb tap on a prominent blue button that can move under the thumb when the feed auto-scrolls.

## What's Working
1. **Live Activities and the revival countdown.** Pre-themed data from the shared builder, a native ticking countdown, compact and minimal island states with the binding window's headroom. Glanceable in under a second with zero navigation, and it can never disagree with the Mac.
2. **The AWS login flow.** Three flows collapsed into one CTA, the passkey wall detected and routed to Safari plus a code, a Paste button for a 1.8k-char code, distinct done/failed outcome screens that name the session and profile.
3. **Feed mechanics.** Long-poll with a 2 s floor, interactive keyboard dismissal, the scroll-to-newest button gated on the last row's visibility, client-side downscaling with quality stepping and honest cap errors. The transport realities were designed in.

## Priority Issues
1. **[P0] Permission approval is one unguarded tap.** `Button("Yes") { sendKey("1") }` styled borderedProminent beside `No`, appended only to the last item, no confirmation or haptic, and the feed's auto-scroll on new items moves it. **Fix:** a pinned bottom card (safeAreaInset above the composer) showing tool + full command, `Allow` as a plain bordered button with a confirmationDialog or press-and-hold, `Deny` neutral-prominent, sensoryFeedback on delivery, card kept until `feed.waiting` clears. `/impeccable harden`
2. **[P1] Feed density: tool noise drowns the conversation.** One capsule per call, one line each, ~35 pt of dead space per row; seven of ten visible items in the screenshot were `Bash · …`. **Fix:** consecutive tool items as one collapsed DisclosureGroup labelled "Bash ×6 · 3 errors" (the Core grouping now supplies the counts), tighter row insets for tool rows, a red glyph tint on error items, and the offline/error text moved to a top banner beside the AWS bar. `/impeccable distill`
3. **[P1] The Fleet tab is Mac rows in a table, not a phone glance.** Every account renders the full header plus gauges; with 11 accounts the active/next/waiting answer is scattered across 11 rows. **Fix:** a hero section at the top with the same data the working activity shows (active account + binding gauge, next, busy/total/waiting linking to Sessions filtered to waiting), non-active rows collapsed to one line. `/impeccable layout`
4. **[P1] The session header is a three-line tap target nobody finds.** The principal toolbar item stacks headline/caption2/caption2; the third line clips in the screenshot; it is the only route to SessionDetailScreen; VoiceOver reads one unlabeled button. **Fix:** name as title, one caption line, an explicit `info.circle` trailing toolbar item to the detail screen, the account/usage line as a slim bar in the top inset. `/impeccable adapt`
5. **[P1] Pairing has no beginning and no end.** Scan QR sits third in Settings after a status caption; success is a caption change; the empty state describes the path in prose. **Fix:** the Fleet empty state gets an actions button that presents the scanner directly; on success an alert or toast "Paired with <machine>" with a success haptic and a switch to Fleet; Scan QR first in its section, prominent. `/impeccable onboard`

## Persona Red Flags
**Alex (impatient, on the couch):** the app opens on Fleet every launch, never the waiting session; no badge on the Sessions tab for the waiting count; the Live Activity tap lands on Fleet; raw lowercase status words; no swipe to open the waiting session.
**Jordan (first pairing):** pairing is Settings › third section; the token field autocapitalises; "Camera scanning isn't available here (it needs a real device)" is dev copy; no confirmation; the URL-scheme route is never mentioned.
**Sam (accessibility):** fixed 34/44 pt fonts in AwsLoginScreen; caption2 metadata and title lines around 11 pt; status carried by a colour dot with the word tertiary; no reduce-motion check anywhere while row flashes, pulses and the intro replay on every foreground; question options with no "n of m"; the paperclip menu and the send button unlabeled; the assistant bubble edge at ~1.2:1 against black.
**Casey (one thumb, 5G, distracted):** Yes/No at the feed's bottom under auto-scroll; the paperclip needs two taps then a system picker; the vertical-axis composer grows unbounded and already pushes the send button at two lines; no draft persistence when the screen is popped; result and failure captions in the same grey.

## Minor Observations
- Session age prints "0m" for a fresh session; say "now".
- The metadata line truncates the branch name before `pid`, so the least useful token survives.
- SessionDetailScreen mixes LabeledContent and bare Text rows; `Kind: interactive` and `Status: busy` are raw enums.
- "Compact popup (one-line accounts, icon controls)" is Mac copy; icon controls don't exist on the phone.
- FleetScreen's Mac-popup mode hardcodes a black background and mentions INFINITUS_MIRROR_PATH to end users.
- MarkdownText: no tables or nested lists; the numbered-list regex will misfire on "3.5 sonnet"; 2,000-char replies render with no "show more".
- Widgets: fixed dark activity tint regardless of wallpaper; the 120 pt gauge frame will clip at large Dynamic Type sizes.
- The floating tab bar stays under the composer on the feed screen; hiding it there gives the composer the bottom edge.
- Eight interpolated numbers in lists lack monospaced digits (SessionDetailScreen 71/164/167/170, SessionsScreen 195–196, OutlookScreen clock labels, SessionFeedScreen 58).

## Questions to Consider
1. If the lock-screen activity already answers "who's working, who's next, who's waiting on me", why does the app's home tab make the user scroll past 11 gauge rows to learn the same thing? Should Sessions be home and Fleet the detail?
2. Is a chat metaphor right for an agent transcript at all, at one user message per ~20 tool calls? Would a status card + last assistant message + pending prompt, with the transcript one tap deeper, serve the glance better?
3. Why can the phone approve a permission with less friction than the Mac terminal, where the user at least sees the whole command? Full command plus a hold, or risky tools Mac-only until opted in?
