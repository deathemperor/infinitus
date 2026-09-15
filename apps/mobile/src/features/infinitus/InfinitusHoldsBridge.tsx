import { useAtomValue } from "@effect/atom-react";
import type { EnvironmentId } from "@t3tools/contracts";

import { infinitusEnvironment } from "../../state/infinitus";
import { environmentPresentations } from "../../state/presentation";
import { environmentServerConfigsAtom } from "../../state/server";
import { infinitusMacs } from "../accounts/accountsRoute.logic";

/** Headless. Keeps every Infinitus Mac's holds stream (`subscribeInfinitusHolds`)
    mounted for the app's lifetime (#1278 finding 7). The outbox drain reads the
    holds atom off the registry (`readHeldThreads`) before it sends; with no
    screen subscribed, that read was what mounted the stream — so the first
    queued message per Mac read null and could slip past a hold, and a queued
    message pinned a stream no screen wanted for a minute after. One deliberate
    subscription per Mac makes the lifetime explicit and the first read real.
    An environment without the `infinitus` capability subscribes to nothing. */
export function InfinitusHoldsBridge() {
  const configs = useAtomValue(environmentServerConfigsAtom);
  const presentations = useAtomValue(environmentPresentations.presentationsAtom);
  return (
    <>
      {infinitusMacs(configs, presentations).map((mac) => (
        <HoldsKeepAlive key={mac.environmentId} environmentId={mac.environmentId} />
      ))}
    </>
  );
}

function HoldsKeepAlive(props: { readonly environmentId: EnvironmentId }) {
  useAtomValue(infinitusEnvironment.holds({ environmentId: props.environmentId, input: {} }));
  return null;
}
