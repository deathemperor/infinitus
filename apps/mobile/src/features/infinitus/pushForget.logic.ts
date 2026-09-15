import type { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusCommandInput } from "@t3tools/contracts/infinitus";

import * as Cause from "effect/Cause";

import { forgetCommand, type LiveActivityTokenKind } from "./liveActivity.logic";
import { isEnvironmentUnreachable } from "./pushRetry.logic";

export type ForgetRun = (input: {
  readonly environmentId: EnvironmentId;
  readonly input: InfinitusCommandInput;
}) => Promise<unknown>;

export interface SwitchState {
  readonly enabled: boolean;
  readonly environmentId: EnvironmentId | null;
}

/**
 * Which Mac to withdraw from when the switch moves from `before` to `now`:
 * only an on → off with a Mac that was driving the phone counts. `now` null
 * (preferences not loaded) is not a state at all, and a Mac going away is not
 * a switch-off — its registrations are its own business until the phone is
 * back.
 */
export function macToForget(
  before: SwitchState | null,
  now: SwitchState | null,
): EnvironmentId | null {
  if (now === null || before === null) return null;
  if (!before.enabled || now.enabled) return null;
  return before.environmentId;
}

/** What became of a withdrawal (#1265 follow-up). `unreachable` means the Mac
    never saw it — the switch-off hook sends it again on the next foreground;
    `refused` is the Mac's own answer and is not retried. */
export interface ForgetOutcome {
  readonly outcome: "withdrawn" | "refused" | "unreachable";
  /** The failure's own words; null when every kind was withdrawn. */
  readonly detail: string | null;
}

/** Withdraws this phone's registrations of `kinds` from the Mac (#702) and
    says what became of it, so the Settings row can read the outcome and the
    thread-card bridge can retry one that never landed. Never throws. */
export async function forgetTokensOutcome(input: {
  readonly environmentId: EnvironmentId;
  readonly kinds: ReadonlyArray<LiveActivityTokenKind>;
  readonly run: ForgetRun;
  readonly loadDeviceId: () => Promise<string>;
}): Promise<ForgetOutcome> {
  try {
    const deviceId = await input.loadDeviceId();
    const results = await Promise.all(
      input.kinds.map((kind) =>
        input.run({ environmentId: input.environmentId, input: forgetCommand(deviceId, kind) }),
      ),
    );
    const failed = results.find((result) => !isSuccess(result));
    if (failed === undefined) return { outcome: "withdrawn", detail: null };
    const error = isFailure(failed) ? Cause.squash(failed.cause) : failed;
    return classify(error);
  } catch (error) {
    return classify(error);
  }
}

const isSuccess = (result: unknown) => (result as { _tag?: unknown } | null)?._tag === "Success";
const isFailure = (result: unknown): result is { readonly cause: Cause.Cause<unknown> } =>
  (result as { _tag?: unknown } | null)?._tag === "Failure";

const classify = (error: unknown): ForgetOutcome => {
  const unreachable = isEnvironmentUnreachable(error);
  const detail = !(error instanceof Error)
    ? String(error)
    : unreachable
      ? error.message
      : `${error.name}: ${error.message}`;
  return { outcome: unreachable ? "unreachable" : "refused", detail };
};
