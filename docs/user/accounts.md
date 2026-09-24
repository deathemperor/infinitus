# Engines, fleets, and accounts

An **engine** manages provider logins, reads their usage, and handles account switching. Infinitus shows what the engine reports and lets you control it.

A **fleet** is the set of accounts an engine manages for one provider, such as Claude accounts managed by swapd. A host can have several fleets. Accounts and engine configuration belong to that host; connecting from another device does not move them. Accounts lists every connected host that runs Infinitus, one group per host, so one page shows the status of the accounts on all your machines. The menu bar popup shows them too while the desktop app is open on that Mac, each fleet headed by its machine's name, and a switch, hold, star, keep-warm, rename or remove on one of those rows runs on that machine. Adding an account and igniting stay on the machine's own Accounts page.

## Set up an engine

Official Mac releases include swapd. In the desktop or web client, open **Settings → Infinitus → Engines** to see engine status and enable it. A host whose Accounts group reports no engine links to that host's engine settings. Opening engine settings directly uses your primary environment. The page's **About** section shows the menu bar app's version; it is bundled with the desktop app and updates with it.

The Engines page shows the swapd version, its daemon status and the binary in use. The copy bundled with the release comes first; a copy installed on the PATH is used only when the bundle has none, so updating swapd means updating Infinitus. If swapd is missing, install a current Infinitus release and relaunch. Source builds can install swapd separately with `cargo install --git https://github.com/deathemperor/swapd swapd` (requires Rust).

CLIProxyAPI and 9Router are optional alternatives, installed separately. In **Settings → Infinitus → Engines**, enter CLIProxyAPI's base URL and management key, or 9Router's base URL and dashboard password, then **Save and relaunch**. Only the desktop app on the owning Mac can change a secret; it stays in that Mac's keychain, and **Forget** clears it. **Test connection** reaches the engine at the address in the field with the stored secret, without saving anything. Enabling or disabling an engine restarts the Mac app. Use one engine per account set to avoid competing rotation policies.

## Add accounts

With swapd enabled, its fleet appears in Accounts even before it holds an account. Choose **Add account**: in the desktop app on the owning Mac, the sign-in opens in your browser and the account joins the fleet when it completes, with nothing to paste. Repeat once per login. If Claude Code on that Mac is already signed in, the menu bar popup's setup card offers to adopt that login in one click instead; its **Sign in…** button opens the desktop app, where Accounts has **Add account**. From the desktop app on another machine, **Add account** opens the sign-in in that machine's browser and the owning Mac finishes it when you approve. From a web browser, **Add account** opens the provider's sign-in as a link; if it shows an authorization code, paste it into that sign-in flow, and if it ends on a page that does not load, copy that page's address from the browser and paste it into the flow. Cancel the flow if you no longer want to add the account.

CLIProxyAPI accounts can be added from its accounts controls. For 9Router, open its dashboard and use **Providers → Connect Claude Code**. The available actions depend on the engine and provider.

## Read usage and switch accounts

Accounts groups logins by fleet and shows each account's usage windows, limits, reset times, and active status when the engine supplies them. The forecast estimates remaining fleet capacity from reported usage. A missing estimate means there is not enough information to calculate it.

When a host's fleets serve more than one provider, the tabs above them filter the page to one provider, each with its account count; every fleet heading carries its provider's logo.

**Quota windows** draws every account's usage windows on one calendar: a lane per account, a bar per window from when it opened to when it resets, filled to the share used. The vertical line is now, so a fill that reaches past it is spending faster than the window's time. Lanes whose bars end together run out on the same days. Switch between **Weekly** (two weeks) and **5-hour** (one day), and step back or forward with the arrows. Past windows come from the usage history Infinitus records, so they appear once it has watched an account through a reset. Dashed bars are the earliest the next windows can run; a 5-hour window only starts on first use, so only accounts kept warm show 5-hour windows ahead. A yellow tick marks when an account's banked reset lapses.

Use **Switch** to choose an account manually. Automatic switching follows the engine's policy: swapd swaps the provider CLI's active login, while proxy engines route requests behind their own endpoint. swapd's policy is set under **Settings → Infinitus → Engines → Switching policy**: whether it switches at all, the strategy, the usage percentage it switches at, and which models' weekly limits also count (add `Fable` there and an account whose Fable window is spent is rotated away from even while its 5-hour and 7-day windows have room). Adding an account only registers it; the daemon decides when to switch onto it. The knobs belong to that machine, and a change takes effect on the daemon's next poll. Proxy session affinity can keep existing conversations on their current credential even after you switch. **Remove** deletes an account's credential from the engine after a confirmation; sign in again to add it back.

A 5-hour window only starts when the account is used, so a switch onto an idle account starts its clock from zero. **Keep warm** (the flame on an account row, swapd only) makes swapd's daemon restart that account's 5-hour window whenever it has gone cold, so a later switch lands on a window that is already running. Each restart is one small request as that account and costs it a little weekly quota; an account whose weekly quota is nearly spent, held, or currently active is not restarted.

An account with banked limit resets (the resets Claude offers under **Settings → Usage**) shows a ticket count next to its plan. Open it for how many are left, when the offer ends, and what stops the next one: a Claude reset is only usable while the account is at a limit, and one cannot follow another straight away. **Use reset** spends one as that account, after a confirmation; the provider does not give it back. On a phone the row's menu offers the same action while nothing holds it.

When accounts run out of headroom, the fleet shows its exhausted state and reported reset timing. Whether a thread can resume automatically depends on its provider and your resume settings; adding another usable account or waiting for a reset restores capacity. A login that expires needs sign-in again rather than a quota reset. Use the account's re-login action, or the separate **Sign-ins** section for pending service logins.

On a phone, Accounts displays each paired Mac's fleets. Configure engines and add accounts on the owning Mac. If Accounts has no fleets, check that an engine is enabled and reachable, then add its first account.
