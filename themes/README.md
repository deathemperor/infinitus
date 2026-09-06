# Community row themes

Shareable "skins" for the Infinitus popup's account rows. The app's
Settings → Display → Row theme → **Community themes** section lists
everything in `index.json` and installs a copy into the user's local
`themes.json`.

## Add yours

1. Create `community/<id>.json` — a single theme object. Only `id` and
   `name` are required; every other field falls back to a sensible default.

   ```json
   {
     "id": "synthwave",
     "name": "Synthwave — neon grid",
     "sessionLabel": "SUN", "sessionColor": "#ff2d95",
     "weeklyLabel": "GRID", "weeklyColor": "#00e5ff",
     "scopedPrefix": "◆ ", "scopedColor": "#c77dff",
     "creditLabel": "CR", "creditColor": "#39ff14",
     "cashIcon": "🕶", "aheadIcon": "⚡",
     "deadMarker": "✖", "revivePrefix": "↻ ",
     "deadVerb": "offline", "flashColor": "#ff2d95",
     "rateIcon": "🎛", "rateLabel": "bpm"
   }
   ```

2. Add an entry to `index.json`:

   ```json
   { "id": "synthwave", "name": "Synthwave — neon grid",
     "author": "your-github-handle", "file": "community/synthwave.json" }
   ```

3. Open a pull request. Once merged, the theme appears in everyone's
   gallery.

## Field reference

| Field | Meaning |
|---|---|
| `sessionLabel` / `sessionColor` | 5-hour window label + gauge color |
| `weeklyLabel` / `weeklyColor` | 7-day window label + gauge color |
| `scopedPrefix` / `scopedColor` | prefix + color for per-model windows |
| `creditLabel` / `creditColor` | usage-credit label + color |
| `cashIcon` | leading icon for the estimated-spend cell |
| `aheadIcon` | ahead-of-pace marker; `sf:<name>` uses an SF Symbol |
| `deadMarker` | prefix on a dead account's name |
| `revivePrefix` | prepended to an exhausted window's reset label |
| `deadVerb` | verb for a dead limit ("out", "MIA", "sold out") |
| `readyLabel` | the all-fresh row's word ("ready", "full HP") |
| `flashColor` | tint for switch/data-change animations ("" = accent) |
| `modelAlias` | per-model rename map ({"Fable": "Dragon"}) |
| `planPrefix` | replaces "Max " in plan strings ("Lv " → "Lv 20x") |
| `slotPrefix` | prepended to the account number ("P" → "P1") |
| `resetWord` | the live "resetting…" word ("respawning…") |
| `nextIcon` | next-candidate marker ("" = green triangle) |
| `activeIcon` | active-account marker, replaces the slot text ("" = plain slot) |
| `rateIcon` | tokens/minute chip icon ("" = the bolt) |
| `rateLabel` | tokens/minute unit after the count ("mana/min", "baud"; "" = tokens/min) |
| `plain` | `true` renders text percentages instead of gauges |

Colors are SwiftUI names (`red`, `cyan`, …) or `#rrggbb`.
