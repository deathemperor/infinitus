---
target: site/
total_score: 19
max_score: 36
na_heuristics: 7
p0_count: 1
p1_count: 4
timestamp: 2026-09-03T15-38-42Z
slug: site-public-index-html
---
Method: dual-agent (A: design review sub-agent · B: detector/browser sub-agent). Browser overlay: Chrome extension not connected; B ran the detector in headless Chrome on a byte-identical copy — no user-visible overlay tab exists.

## Design Health Score

| # | Heuristic | Score | Key Issue |
|---|---|---|---|
| 1 | Visibility of System Status | 3 | Copy feedback + live demo good; the unsigned-build fact only surfaces in the install fineprint |
| 2 | Match System / Real World | 3 | "consume-first", "evidence-gated nudges", "capacity verdict", "switch storms" are internal vocabulary |
| 3 | User Control and Freedom | 1 | Autoplaying looped video with no controls and no reduced-motion gate; nav hidden ≤640 with no replacement |
| 4 | Consistency and Standards | 2 | Hero/fleet blocks 24 px off the rest of the page; FAQ says the iOS app is "in progress" next to four shipped phone cards; "MIT-spirited" vs "MIT licensed" |
| 5 | Error Prevention | 2 | `--no-quarantine` in the hero command unexplained; Gatekeeper recovery and the claude-swap requirement five screens below the CTA |
| 6 | Recognition Rather Than Recall | 2 | 15 theme tiles at ~300 px render the 1600 px popup as illegible strips; cards cite "the smart engine" before it's introduced |
| 7 | Flexibility and Efficiency | n/a | Static landing page; the brew/zip/source choice is the one accelerator |
| 8 | Aesthetic and Minimalist Design | 2 | 19 equal-weight feature cards, 15 equal-weight tiles, 7 hero actions |
| 9 | Error Recovery | 2 | Recovery text exists only at failing contrast in the install fineprint |
| 10 | Help and Documentation | 2 | claude-swap named 3×, linked 0×; no getting-started link; how accounts are added is never said |
| **Total** | | **19/36** | **Acceptable (53%)** |

## Design Specificity Verdict

**LLM assessment:** authored in content, templated in skeleton. The fake macOS menubar with the live `∞ 64%` pill, the fleet-frame rotation demo ("limit hit — switched papaya → banyan · resume nudge sent to 3 sessions"), the one-paragraph MP/HP/Dragon explainer and "it's dark, on purpose" could not belong to another product. Everything around them is the 2025–26 dev-tool default: Instrument Serif + IBM Plex Mono on near-black, orange accent, hero → 3 steps → card grid → gallery → install → FAQ → footer. Specificity 6/10, carried by the two demo blocks, not the system.

**Deterministic scan:** CLI 3 findings in `site/public/index.html` — overused-font (Instrument Serif, line 34), layout-transition (`transition: width` on `.gauge > i`, line 167), em-dash-overuse (30, advisory). Browser detector 15 findings: low-contrast ×5 (all the single `--faint` token #545c68 at 2.7–2.9:1 on `.also`, `.fineprint` ×2, `.acct.dead .name/.stat`), layout-transition ×4 (the same gauge rule, reported per element and page-level), gpt-thin-border-wide-shadow ×3 (`.fleet-frame`, `video.screen`, `img.screen`: 1 px border + 60–80 px shadow), hero-eyebrow-chip ×1 (`.kicker` tracked caps above the h1), line-length ×1 (`.fineprint` ~87 ch), em-dash ×1. Agreement: the detector's contrast hits are the same `--faint` failure A found by hand on `.note`, `.fleet-head/foot`, `pre .c`, the footer and `.brew .k`; A missed the thin-border-wide-shadow trio. False positives: none confirmed; the two `.acct.dead` contrast hits are on a deliberately dead row (WCAG's inactive-component exemption would cover them, but the same token fails everywhere else). The gauge `transition: width` is an intentional demo animation and already gated by reduced-motion — keep, or move to `transform: scaleX`.

**Visual overlays:** none available (extension not connected). Fallback signal: B's headless run produced 12 overlay boxes in `scratchpad/overlay.png`.

## Overall Impression
The top of the page sells: serif headline, one orange CTA, a demo that shows rotation happening. Then it stops designing and starts listing — 19 cards, 15 tiles, 12,000 px. The single biggest opportunity: mobile is broken (sideways scroll, edge-flush hero) on a page whose buyer will first see it on a phone.

## What's Working
1. **The live rotation demo** — the core loop shown without a screenshot, tied to the sticky tray pill, reduced-motion respected. The one block that couldn't belong to another product.
2. **The `#how` copy** — "Rotate on the limit, not after it" / "Limits become a hand-off, not an outage": concrete, benefit-first, no adjectives.
3. **The fold's type hierarchy** — serif h1 with one italic orange `em`, mono lede at 58 ch, one CTA. Clean read order on desktop.

## Priority Issues
1. **[P0] Mobile layout breaks.** At 390 px the document is 564 px wide (sideways scroll) and the hero and demo sit at x=0. `.install-cols` `1fr` tracks take each `<pre>`'s longest line as min-width; `.hero{padding:88px 0 40px}` / `.fleet{padding:26px 0 70px}` zero `.wrap`'s inline padding. **Fix:** `minmax(0,1fr)` tracks (both breakpoints) and `padding-inline: 24px` on `.hero`/`.fleet` — which also removes the 24 px desktop misalignment. `/impeccable adapt`
2. **[P1] The scary bits sit next to the CTA; the reassurance sits five screens away.** `--no-quarantine` in the brew line, "unsigned — right-click → Open" and "needs claude-swap" only in the install fineprint. **Fix:** one line under the CTA that says both, and link claude-swap wherever it is named. `/impeccable clarify`
3. **[P1] Features have no hierarchy.** 19 identical cards; phone chat, AWS login from the phone and Live Activities drown among "Playground". **Fix:** four groups with headers (Watch & switch / Phone / Wall & themes / Integrations & agents). `/impeccable layout`
4. **[P1] Cheap accessibility failures.** `--faint` fails AA on every secondary line including the trust copy; the video autoplays with no pause and no reduced-motion gate; `#tray-pct` mutates every 1.4 s outside the aria-hidden demo. **Fix:** `--faint` ≈ #7c8592, `controls` on the video + pause under reduced motion, `aria-hidden` on the pill. `/impeccable audit`
5. **[P1] No premise, no proof, no close.** Nothing says "for people running 2+ Claude subscriptions"; zero social proof; the page ends on a disclaimer. **Fix:** premise in the lede, a closing band with Download + brew before the footer; social proof only with a real number. `/impeccable clarify`

## Persona Red Flags
**Jordan (first-timer):** cannot self-qualify — is a "fleet" several paid accounts, and is that allowed? claude-swap unexplained and unlinked. "Omarchy", "consume-first", "capacity verdict" opaque. The `∞ 56%` pill looks clickable and isn't. Three download paths, none recommended.
**Sam (accessibility):** `--faint` fails on every secondary line; autoplay video, no controls, no `poster`, `aria-label` on `<video>` weakly supported; the pill's churn; 15 identical alts "X theme rows"; "copied" has no live region. Focus rings are good; no skip link.
**Casey (mobile):** the P0 overflow; the brew "copy" key lands off-screen at right=575 so the button reads as a truncated command; nav vanishes with no menu; "Download for macOS" on a phone with no send-to-Mac path; 19 stacked cards before the gallery; 2.3 MB video autoplays on cellular plus ~4 MB of theme PNGs.

## Minor Observations
- `#wall img` at page width is ~40% black: show the busy state or crop.
- Four phone cards, zero phone screenshots; no Linux screenshot.
- `.acct .stat` hides ≤560 — the demo loses "resets 9h 12m" on phones.
- Three h3 sizes (15/16/15 px); `.themes` names in `<b>` with no heading; "Questions" vs nav "FAQ"; "MIT-spirited" vs "MIT licensed".
- Version/zip URL live in three places per release.
- Thin-border-plus-wide-shadow frames on the demo, video and screenshot read as generated.

## Questions to Consider
1. If the buyer has three Claude Max subscriptions, why does the page never say so — and never address whether that's allowed?
2. Why do 15 recolors of one row get 15 images while the features nobody else has (phone chat, AWS login from the phone, Live Activities) get none?
3. If "you only need to look when something is moving" is the whole idea, why does the page ask for 12,000 pixels of reading?
