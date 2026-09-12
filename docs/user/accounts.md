# Engines, fleets, and accounts

An **engine** manages provider logins, reads their usage, and handles account switching. Infinitus shows what the engine reports and lets you control it. Session tracking works independently, so seeing sessions does not mean an account engine is configured.

A **fleet** is the set of accounts an engine manages for one provider, such as Claude accounts managed by swapd. A host can have several fleets. Accounts and engine configuration belong to that host; connecting from another device does not move them.

## Set up an engine

Official Mac releases include swapd. In the desktop or web client, open **Settings → Infinitus → Engines** to see engine status and enable it. From Accounts, choose **Set up engines** to configure the selected host. Opening engine settings directly uses your primary environment. You can also open Infinitus on the owning Mac and use **Settings → Engines**.

In the Mac app, the swapd pane shows the detected binary and daemon status. An installed copy takes precedence over the bundled copy. If swapd is missing, install a current Infinitus release and relaunch. Source builds can install swapd separately with `cargo install --git https://github.com/deathemperor/swapd swapd` (requires Rust).

CLIProxyAPI and 9Router are optional alternatives, installed separately. In the Mac app's engine settings, enter CLIProxyAPI's base URL and management key, or 9Router's base URL and dashboard password. Use **Test Connection**, then **Save & Restart**. Secrets stay in the Mac's keychain. Enabling or disabling an engine restarts the Mac app. Use one engine per account set to avoid competing rotation policies.

## Add accounts

With swapd enabled, sign in to Claude Code first, then relaunch Infinitus. Its first-account setup offers to add the detected login. If Claude Code is already signed in, you can adopt that login directly. Once a fleet appears, use its **Add account** action in Accounts; supported engines offer an in-app sign-in flow. Complete the provider's sign-in instructions, then return to Accounts. If prompted for an authorization code, paste it into that sign-in flow. Cancel the flow if you no longer want to add the account.

CLIProxyAPI accounts can be added from its accounts controls. For 9Router, open its dashboard and use **Providers → Connect Claude Code**. The available actions depend on the engine and provider.

## Read usage and switch accounts

Accounts groups logins by fleet and shows each account's usage windows, limits, reset times, and active status when the engine supplies them. The forecast estimates remaining fleet capacity from reported usage. A missing estimate means there is not enough information to calculate it.

Use **Switch** to choose an account manually. Automatic switching follows the engine's policy: swapd swaps the provider CLI's active login, while proxy engines route requests behind their own endpoint. Proxy session affinity can keep existing conversations on their current credential even after you switch.

When accounts run out of headroom, the fleet shows its exhausted state and reported reset timing. Whether a thread can resume automatically depends on its provider and your resume settings; adding another usable account or waiting for a reset restores capacity. A login that expires needs sign-in again rather than a quota reset. Use the account's re-login action, or the separate **Sign-ins** section for pending service logins.

On a phone, Accounts displays each paired Mac's fleets. Configure engines and add accounts on the owning Mac. If Accounts has no fleets, check that an engine is enabled and reachable, then add its first account.
