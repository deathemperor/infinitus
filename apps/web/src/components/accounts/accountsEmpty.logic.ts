import type { EngineStatusRow } from "../settings/infinitus/panel.logic";

/**
 * Why the Accounts page has nothing to draw, in the user's terms. The app
 * answered — so the question is never "is Infinitus running", it is which of
 * the three steps before an account row is missing: an engine installed, that
 * engine turned on, an account registered in it.
 */
export type AccountsEmptyReason = "no-engines" | "none-registered" | "all-disabled" | "no-accounts";

export function accountsEmptyReason(rows: ReadonlyArray<EngineStatusRow>): AccountsEmptyReason {
  if (rows.length === 0) return "no-engines";
  const registered = rows.filter((row) => row.registered);
  if (registered.length === 0) return "none-registered";
  if (!registered.some((row) => row.enabled)) return "all-disabled";
  return "no-accounts";
}

const REASON_TEXT: Readonly<Record<AccountsEmptyReason, string>> = {
  "no-engines":
    "This Mac reports no engine at all. An engine — swapd for Claude accounts — is what holds the accounts and rotates between them.",
  "none-registered":
    "No engine is registered yet. Install one (swapd holds Claude accounts), then relaunch Infinitus so it finds the binary.",
  "all-disabled":
    "An engine is installed but turned off. Turn it on in Settings › Infinitus › Engines.",
  "no-accounts":
    "The engine is running but holds no account yet. Sign in to Claude Code, then register that account with the engine.",
};

/** The one sentence under the heading. */
export function accountsEmptyMessage(reason: AccountsEmptyReason): string {
  return REASON_TEXT[reason];
}

/** Only a machine that could actually gain an engine gets the setup link; a
    build already running one needs the account step, not the install guide. */
export function accountsEmptyShowsSetupGuide(reason: AccountsEmptyReason): boolean {
  return reason === "no-engines" || reason === "none-registered";
}

/** The engine setup guide, on the repository that ships the Mac app. */
export const ACCOUNTS_SETUP_GUIDE_URL =
  "https://github.com/deathemperor/infinitus/blob/main/apps/mac/docs/guides/agent-setup.md";
