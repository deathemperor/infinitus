import type { SignInRowModel } from "@t3tools/client-runtime/state/infinitusAccounts";

import { formatRelativeTimeLabel } from "../../timestampFormat";

/** The one-line status under a sign-in's name: how long it has been lapsed
    while idle, then what the running login is doing. The page a waiting
    device-code login printed is drawn as a link by the row, not here. */
export function signInStatus(row: SignInRowModel): string {
  switch (row.phase) {
    case "idle": {
      const since = row.failedAt === null ? "" : formatRelativeTimeLabel(row.failedAt);
      return since === "" ? "Lapsed" : `Lapsed ${since}`;
    }
    case "starting":
      return "Starting sign-in…";
    case "waiting":
      if (row.userCode !== null) return `Open the sign-in page and enter ${row.userCode}`;
      return row.deviceCode ? "Waiting for the sign-in page…" : "Waiting for the Mac's browser…";
    case "done":
      return "Signed in";
    case "failed":
      return row.message === null ? "Sign-in failed" : `Sign-in failed: ${row.message}`;
  }
}

/** Which sessions are stuck on the row, or empty when the app named none. */
export function waitingSessionsLabel(sessions: ReadonlyArray<string>): string {
  if (sessions.length === 0) return "";
  return `Waiting: ${sessions.join(", ")}`;
}

/** The button's text, or null while a login runs or after it finished. */
export function signInButtonLabel(row: SignInRowModel): string | null {
  if (row.phase === "idle") return "Sign in";
  if (row.phase === "failed") return "Try again";
  return null;
}
