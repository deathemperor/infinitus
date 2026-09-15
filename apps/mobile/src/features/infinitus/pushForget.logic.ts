import type { EnvironmentId } from "@t3tools/contracts";
import type { InfinitusCommandInput } from "@t3tools/contracts/infinitus";

import { forgetCommand, type LiveActivityTokenKind } from "./liveActivity.logic";

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

/** Withdraws this phone's registrations of `kinds` from the Mac (#702). Best
    effort: a Mac that is away, or a bundle before the verb, leaves them to
    APNs' token rotation as before, so nothing here throws. */
export async function forgetTokens(input: {
  readonly environmentId: EnvironmentId;
  readonly kinds: ReadonlyArray<LiveActivityTokenKind>;
  readonly run: ForgetRun;
  readonly loadDeviceId: () => Promise<string>;
}): Promise<void> {
  let deviceId: string;
  try {
    deviceId = await input.loadDeviceId();
  } catch {
    return;
  }
  await Promise.all(
    input.kinds.map((kind) =>
      input
        .run({ environmentId: input.environmentId, input: forgetCommand(deviceId, kind) })
        .catch(() => undefined),
    ),
  );
}

/** Withdraws one kind and says whether the Mac took the withdrawal (#1265):
    the thread-card bridge retries a forget the Mac never saw, since a slot
    left holding an ended card's token keeps the push-to-start token unused. */
export async function forgetTokenLanded(input: {
  readonly environmentId: EnvironmentId;
  readonly kind: LiveActivityTokenKind;
  readonly run: ForgetRun;
  readonly loadDeviceId: () => Promise<string>;
}): Promise<boolean> {
  try {
    const deviceId = await input.loadDeviceId();
    const result = await input.run({
      environmentId: input.environmentId,
      input: forgetCommand(deviceId, input.kind),
    });
    return (result as { readonly _tag?: string } | null)?._tag === "Success";
  } catch {
    return false;
  }
}
