/**
 * Maps `omp usage --json --redact`'s `capacity` fold onto
 * `ServerProviderUsageLimits`. `capacity` is omp's own per-provider,
 * per-window aggregation across accounts — already `usedPercent`
 * semantics, and it carries no email. `limits[]` sits next to
 * `metadata.email` and is never read.
 *
 * `capacity` has no per-window `resetsAt`, so that field stays absent.
 *
 * Decode is defensive: an unrecognised or malformed entry is dropped,
 * never thrown on, so a future omp shape change degrades to fewer
 * windows / no quota rather than a broken probe.
 */
import type { ServerProviderUsageLimits, ServerProviderUsageWindow } from "@infinitus/contracts";

import {
  clampPercent,
  makeUnavailableUsageLimits,
  makeUsageLimits,
} from "../providerUsageLimits.ts";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function finiteNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}

function nonEmptyString(value: unknown): string | undefined {
  return typeof value === "string" ? value.trim() || undefined : undefined;
}

function windowKind(windowId: string): ServerProviderUsageWindow["kind"] {
  switch (windowId) {
    case "5h":
      return "session";
    case "7d":
    case "weekly":
      return "weekly";
    case "30d":
    case "1mo":
    case "monthly":
      return "monthly";
    default:
      return "other";
  }
}

function windowKindLabel(kind: ServerProviderUsageWindow["kind"], windowId: string): string {
  switch (kind) {
    case "session":
      return "Session";
    case "weekly":
      return "Weekly";
    case "monthly":
      return "Monthly";
    case "other":
      return windowId;
  }
}

function usedPercent(usedAccounts: number, accounts: number): number {
  if (accounts === 0) return 0;
  return clampPercent((usedAccounts / accounts) * 100);
}

function durationMins(durationMs: number | undefined): number | undefined {
  if (durationMs === undefined || durationMs < 0) return undefined;
  const mins = Math.round(durationMs / 60_000);
  return Number.isInteger(mins) && mins >= 0 ? mins : undefined;
}

function capacityWindow(provider: string, entry: unknown): ServerProviderUsageWindow | undefined {
  if (!isRecord(entry)) return undefined;
  const windowId = nonEmptyString(entry.window);
  if (windowId === undefined) return undefined;
  const accounts = finiteNumber(entry.accounts);
  const usedAccounts = finiteNumber(entry.usedAccounts);
  if (accounts === undefined || accounts < 0 || usedAccounts === undefined) return undefined;
  const kind = windowKind(windowId);
  const mins = durationMins(finiteNumber(entry.durationMs));
  return {
    id: `${provider}:${windowId}`,
    kind,
    label: `${provider} · ${windowKindLabel(kind, windowId)}`,
    usedPercent: usedPercent(usedAccounts, accounts),
    ...(mins !== undefined ? { windowDurationMins: mins } : {}),
  };
}

export function ompCapacityToUsageLimits(
  raw: unknown,
  checkedAt: string,
): ServerProviderUsageLimits {
  if (!isRecord(raw) || !isRecord(raw.capacity)) {
    return makeUnavailableUsageLimits({ checkedAt, reason: "unsupported" });
  }

  const windows: ServerProviderUsageWindow[] = [];
  const seen = new Set<string>();
  for (const [providerRaw, entries] of Object.entries(raw.capacity)) {
    const provider = providerRaw.trim();
    if (provider.length === 0 || !Array.isArray(entries)) continue;
    for (const entry of entries) {
      const window = capacityWindow(provider, entry);
      if (window === undefined || seen.has(window.id)) continue;
      seen.add(window.id);
      windows.push(window);
    }
  }

  if (windows.length === 0) {
    return makeUnavailableUsageLimits({ checkedAt, reason: "unsupported" });
  }
  return makeUsageLimits({ checkedAt, windows });
}
