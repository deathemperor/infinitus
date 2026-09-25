# Settings across machines

Display prefs and, as a second switch, custom account names stay the same on every machine the desktop app is paired with. The desktop runs the whole sync: it is the one process that holds every environment, each environment's snapshot already carries its prefs and its fleets with their aliases, and `prefs set` and `rename` already exist. Nothing new crosses the socket and no file travels; the Mac holds only the two switches (`sync_settings`, `sync_account_names`, Devices section of `PrefCatalog`). The loop is `apps/web/src/hooks/useInfinitusSettingsSync.ts` over the pure rules in `settingsSync.logic.ts`, mounted through `InfinitusSettingsSync.tsx` in `__root.tsx`, Electron only, and reads the switches off the primary environment's prefs.

This replaced the Mac's iCloud Drive file sync (`SettingsSyncModel`, 2026-08-29 to 2026-09-24), which also mirrored each Mac's usage history beside the file. Custom themes travelled in that file; nothing edits them since the Mac's settings window retired, so they no longer travel. The usage history is per machine now: `utilization` answers for the Mac it runs on.

## Which keys travel

`SYNCED_PREF_KEYS`: the popup's look, the title, the animations, the pushes. Not the status item's own switches, the ports, the engines, the priority knobs, or the two sync switches. A test checks the list against the catalog, so a retired key fails there rather than being sent to every machine as an unknown pref.

## The rules, and why there are no timestamps

The desktop keeps one shared doc in memory. Every machine's desktop may run this loop against the same machines, so the rules had to converge with two desktops pushing, and had to survive a write a machine refuses (a custom theme id the target does not have, an alias its engine rejects) without any machine fighting the doc every poll:

- **An edit is a value unlike both what that machine last showed and the shared value.** One rule filters the echo of our own push, a snapshot taken while a push is half applied, and a refused write (the machine still shows what it showed before).
- **A key seen for the first time joins only where the doc has nothing.** So a machine's first sight, and a new account, never override what the others agree on; the names map is the union of every machine's accounts.
- **The primary seeds.** Until the primary Mac's doc is in, the others are not read, so the seed is always this desktop's own Mac rather than whichever machine answered first.
- **Each machine is aligned once per version of the doc.** A refused write is not retried until the doc moves again.
- **Startup and first sight baseline; only a flip aligns.** A desktop coming up reads the primary's switches without treating them as a change, and a machine's first sight (or its return after its app was away) only records what it shows: its edits travel from then on, but what it holds now is not pushed over the others'. A switch flip on the primary is the one thing that starts over — the primary seeds again and every machine's next sight is aligned to it — which is how "turn it on and the machines line up" happens; turning it off stops everything and forgets the doc.

The trap behind the last rule: with two desktops each aligning on sight from a different seed, Mac 1 shows what desktop 2 pushed, desktop 1 reads that as an edit (unlike both what Mac 1 showed and its own doc), adopts it and pushes it to Mac 2, while desktop 2 does the same the other way — the machines swap values forever. `settingsSync.logic.test.ts` replays two desktops over two Macs for exactly this. The cost is that existing divergence between machines persists until someone changes a setting or flips the switch. That is the trade for having no clock: a Mac-side revision stamp with newest-wins would need a new verb pair and contract changes for a case the flip already covers.
