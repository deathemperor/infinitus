# Infinitus — feature walkthrough (script)

Target: ~90 seconds, no narration track needed (captions in the edit).
Recorded on the demo fleet (`cswap-shim`: alpha…echo, fabricated
usage) — never the real engine, so no account emails appear.

| # | Shot | On screen | Caption |
|---|---|---|---|
| 1 | Menu bar | The ∞ glyph with `alpha 37%·22%` beside it | "Every Claude account in one menu bar" |
| 2 | Click the glyph | The glass popup: five rows, HP/MP gauges, gold column, pace markers | "Live 5-hour / weekly / per-model headroom for the whole fleet" |
| 3 | Hover a gauge | Tooltip with reset countdown + pace | "Pace markers when a window burns faster than time passes" |
| 4 | Row 3 (charlie) | Dead row: 💀, "HP down", respawn countdown | "Dead rows say why — and when they're back" |
| 5 | Rotate button | Switch to the next candidate; the celebration sweep runs over the new active row | "One-click rotate, auto-switch aware" |
| 6 | Right-click the glyph → Theme | Flip RPG → Metal Gear → Cosmos → Off | "Themes reskin every label, marker and countdown" |
| 7 | Pop out | The pinned window, compact toggle | "Pop-out window, compact mode, remembers its spot" |
| 8 | Settings → Display / Themes / Engines | Toggles, the theme card grid, the resume-nudge switches | "Auto-order, glass dial, resume nudges into cmux/tmux/herdr" |
| 9 | Settings → Push | Slack/Discord/Telegram/webhook rows (masked) | "Switch and limit events pushed where you are" |
| 10 | Close | Back to the bar glyph | "brew install --cask deathemperor/tap/infinitus" |

Recording: `screencapture -v -V <seconds> -R x,y,w,h out.mov` per shot on
the shim fleet (`INFINITUS_CSWAP=$S/cswap-shim ./run-unbundled.sh`),
then `ffmpeg -f concat` the segments; keep the mp4 out of git.

## Recorded cut №2 — 2026-08-31 (39s tight / 75s full, ~/Movies/Infinitus-walkthrough[-full].mp4)

Re-recorded per user ask ("changing layout, compact mode for both,
theme switching") on the shim fleet, all interactions scripted:

| t | Segment | On screen |
|---|---|---|
| 0:00 | Open + tour | Wide rows (RPG), hover tooltips on gauges |
| 0:12 | Rotate | One-click rotate + celebration sweep |
| 0:20 | Compact (wide) | One-line rows + icon rail, and back |
| 0:30 | Layouts | Wide -> stacked cards; compact in stacked, and back |
| 0:41 | Pop out | Pop-out window appears, morphs stacked -> horizontal cards in place |
| 0:54 | Themes | Settings window snapped flush beside the pop-out; Themes card grid re-skins the fleet live: Sci-Fi -> Hades -> Movie -> RPG |

Notes: the bar click raises the pop-out once one exists (by design), so
the popup can't sit beside it — layout flips ride the pop-out's own
rail. macOS notification banners photobomb the region; wait them out.
Themes retake: both window frames are placed exactly (Settings frame via
its NSWindow-frame default + AX move, pop-out via popout_x/y) so the two
windows sit adjacent and all five cards clear the region bottom.
Tight cut: mpdecimate collapses static holds ~3-5x (gentler on the
hover tour and themes so dwells stay readable, harder on layout
mechanics) + 1.1x global pace; motion frames stay. 75s -> 39s.
README demo.gif is the tight cut as gif: crop the 1600x900 pad to
1600x678, 10fps, 960w, palettegen/paletteuse (bayer dither) — 4.8MB.
