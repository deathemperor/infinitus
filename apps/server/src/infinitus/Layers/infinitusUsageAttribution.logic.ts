/**
 * The pure half of per-account spend attribution (#779): the swap engine's
 * history (`swapd history --json --provider claude`, read through the app's
 * `history` verb) becomes a timeline, and a timeline answers "which account
 * was active at this instant". Emails are the join key: slots renumber when
 * the engine compacts, emails do not. Nothing here logs; the callers keep the
 * emails out of spans and log lines.
 */
import type { InfinitusAccount } from "@t3tools/contracts/infinitus";

export interface SwitchRow {
  readonly atMs: number;
  readonly email: string;
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null;

/**
 * The rows of a `history` reply that carry a parsable `ts` and a destination
 * email, oldest first. Anything else in the list is skipped, not fatal: a torn
 * tail line or an older engine's shape costs one row, never the table.
 */
export function readSwitches(reply: unknown): ReadonlyArray<SwitchRow> {
  if (!isRecord(reply) || !Array.isArray(reply.switches)) return [];
  const rows: SwitchRow[] = [];
  for (const entry of reply.switches) {
    if (!isRecord(entry) || typeof entry.ts !== "string" || !isRecord(entry.to)) continue;
    const atMs = Date.parse(entry.ts);
    if (Number.isNaN(atMs) || typeof entry.to.email !== "string" || entry.to.email.length === 0) {
      continue;
    }
    rows.push({ atMs, email: entry.to.email });
  }
  return rows.sort((a, b) => a.atMs - b.atMs);
}

const toSecond = (ms: number): number => Math.floor(ms / 1000);

/**
 * `accountAt(ms)` is the email of the latest switch at or before `ms`, or
 * `null` when there is none (the engine did not exist yet) or when `ms` falls
 * in a switch's own second: at second resolution the record may belong to
 * either side, so it is left unattributed rather than guessed.
 */
export function accountAtFactory(
  switches: ReadonlyArray<SwitchRow>,
): (timestampMs: number) => string | null {
  return (timestampMs) => {
    // Binary search for the last switch with atMs <= timestampMs.
    let low = 0;
    let high = switches.length - 1;
    let found = -1;
    while (low <= high) {
      const mid = (low + high) >>> 1;
      const row = switches[mid];
      if (row === undefined) break;
      if (row.atMs <= timestampMs) {
        found = mid;
        low = mid + 1;
      } else {
        high = mid - 1;
      }
    }
    if (found < 0) return null;
    const current = switches[found];
    const next = switches[found + 1];
    if (current === undefined) return null;
    const second = toSecond(timestampMs);
    if (second === toSecond(current.atMs)) return null;
    if (next !== undefined && second === toSecond(next.atMs)) return null;
    return current.email;
  };
}

/**
 * How the app names the account: its alias when it has one, else the email,
 * with the current slot number while the account is still in the fleet.
 */
export function describeAccount(
  accounts: ReadonlyArray<Pick<InfinitusAccount, "number" | "email" | "alias">>,
  email: string,
): { readonly label: string; readonly number?: number } {
  const account = accounts.find((candidate) => candidate.email === email);
  if (account === undefined) return { label: email };
  const alias = account.alias?.trim();
  return { label: alias !== undefined && alias.length > 0 ? alias : email, number: account.number };
}
