import type { AccountsPageState } from "@t3tools/client-runtime/state/infinitusAccounts";
import type { InfinitusSnapshot, InfinitusStatus } from "@t3tools/contracts/infinitus";
import * as Cause from "effect/Cause";

import { formatEnvironmentQueryError } from "~/state/query";
import type { PrefRowModel } from "./prefsForm.logic";

/**
 * What the Infinitus settings panes share: which of the five shapes to draw,
 * how a forwarded command's failure reads, and the engine status list. Pure so
 * the panes only render.
 */

/** The five shapes, in the Accounts page's own vocabulary: the capability
    answers first, `empty` is the build that answers but has nothing to show. */
export type InfinitusPanelState = AccountsPageState;

/** `empty` here is a build that predates the `prefs` command, so its catalog
    never arrives however long the pane waits. */
export function infinitusPrefsPanelState(input: {
  capability: boolean | undefined;
  snapshot: InfinitusSnapshot | null;
}): InfinitusPanelState {
  if (input.capability !== true) return "unsupported";
  if (input.snapshot === null) return "loading";
  if (!input.snapshot.available) return "unavailable";
  if (input.snapshot.prefs === undefined) return "empty";
  return "ready";
}

/** The pane's own copy for every shape but `ready`. `unavailableReason` is the
    snapshot's, which names the socket it tried. */
export function infinitusPanelMessage(
  state: Exclude<InfinitusPanelState, "ready">,
  unavailableReason?: string | undefined,
  emptyMessage = "This Infinitus build has no preference catalog (needs ≥ a6a18a94d).",
): string {
  switch (state) {
    case "unsupported":
      return "This environment's server does not reach an Infinitus app.";
    case "loading":
      return "Reading the Infinitus app…";
    case "unavailable":
      return unavailableReason === undefined || unavailableReason === ""
        ? "Infinitus is not answering — it may be closed, or running on another machine."
        : `Infinitus is not answering: ${unavailableReason}`;
    case "empty":
      return emptyMessage;
  }
}

/**
 * What a failed `infinitus.command` says and whether the app is quitting
 * anyway. `InfinitusCommandFailed.error` is the native app's own text (down to
 * "refresh_interval must be one of 30, 60, 300, not 45"), so it is shown
 * verbatim; `restarting: false` means a restart-effect write was refused and
 * nothing is waiting for the socket to come back.
 */
export function infinitusCommandFailure(cause: Cause.Cause<unknown>): {
  readonly message: string;
  readonly restarting: boolean;
} {
  const error: unknown = Cause.squash(cause);
  if (typeof error === "object" && error !== null && "_tag" in error) {
    const tagged = error as {
      readonly _tag: unknown;
      readonly error?: unknown;
      readonly cause?: unknown;
      readonly detail?: unknown;
      readonly restarting?: unknown;
    };
    if (tagged._tag === "InfinitusCommandFailed" && typeof tagged.error === "string") {
      return { message: tagged.error, restarting: tagged.restarting === true };
    }
    if (tagged._tag === "InfinitusUnavailable" && typeof tagged.cause === "string") {
      return { message: `Infinitus is not answering: ${tagged.cause}`, restarting: false };
    }
    if (tagged._tag === "InfinitusProtocolError" && typeof tagged.detail === "string") {
      return { message: `Infinitus answered unexpectedly: ${tagged.detail}`, restarting: false };
    }
  }
  return { message: formatEnvironmentQueryError(cause), restarting: false };
}

/** The hint under a row whose value is no longer the app's default. The
    default is named the way the control names it, not as raw JSON. */
export function prefDefaultHint(row: PrefRowModel, value: boolean | number | string): string {
  if (row.control.kind === "switch") return value === true ? "Default: on" : "Default: off";
  if (row.control.kind === "select") {
    const option = row.control.options.find((candidate) => candidate.value === String(value));
    return `Default: ${option?.label ?? String(value)}`;
  }
  return `Default: ${String(value)}`;
}

/** The engines the app knows by their product names; anything the native side
    adds later shows its own key. */
const ENGINE_LABELS: Readonly<Record<string, string>> = {
  swapd: "swapd",
  cliproxy: "CLIProxyAPI",
  "9router": "9Router",
};

export interface EngineStatusRow {
  readonly key: string;
  readonly label: string;
  readonly enabled: boolean;
  readonly registered: boolean;
  /** `none` for an engine that holds no key at all — only the proxies do, and
      only they get the "Manage in Infinitus" hand-off. */
  readonly keyState: "present" | "missing" | "none";
}

/** One row per engine the app reports, in key order so the list never jumps. */
export function buildEngineStatusRows(
  status: InfinitusStatus | undefined,
): ReadonlyArray<EngineStatusRow> {
  if (status === undefined) return [];
  return Object.entries(status.engines)
    .map(([key, engine]) => ({
      key,
      label: ENGINE_LABELS[key] ?? key,
      enabled: engine.enabled,
      registered: engine.registered,
      keyState:
        engine.keyPresent === undefined
          ? ("none" as const)
          : engine.keyPresent
            ? ("present" as const)
            : ("missing" as const),
    }))
    .toSorted((left, right) => left.key.localeCompare(right.key));
}
