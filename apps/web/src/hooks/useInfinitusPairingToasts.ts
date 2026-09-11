import type { EnvironmentId } from "@t3tools/contracts";
import { useNavigate } from "@tanstack/react-router";
import { useEffect, useRef } from "react";

import { unseenRequests } from "../components/settings/infinitus/pairingRequests.logic";
import { usePairingRequests } from "../components/settings/infinitus/usePairingRequests";
import { stackedThreadToast, toastManager } from "../components/ui/toast";
import { usePrimaryEnvironment } from "../state/environments";

/** Where the toast's one action goes: the card with the match code and the
    Approve / Deny pair. The toast itself never approves — a spoofed device
    name must not be let in by reflex (#710). */
const PAIRING_REQUESTS_ROUTE = "/settings/infinitus/devices";

interface Watched {
  environmentId: EnvironmentId;
  seen: Set<string>;
  /** A broken stream is logged once per environment, not once per render. */
  warned: boolean;
}

/**
 * A toast for every phone that asks to pair (#710): its device name and one
 * Open action to the Devices card. Every request the desktop has not toasted
 * is news, including those already pending when the app loads — a request
 * lives two minutes and needs the user. Each id is toasted once per
 * environment; the request's match code and the phone's secret stay off
 * the toast (the code is compared on the card, the secret never leaves the
 * server). A client without the administrative scopes is refused the stream
 * and toasts nothing — the Devices card says who can approve (#730); any
 * other failure is logged once.
 */
export function useInfinitusPairingToasts(): void {
  const environmentId = usePrimaryEnvironment()?.environmentId ?? null;
  const access = usePairingRequests(environmentId);
  const navigate = useNavigate();
  const watched = useRef<Watched | null>(null);

  useEffect(() => {
    if (environmentId === null || access.kind === "loading" || access.kind === "forbidden") return;
    if (watched.current === null || watched.current.environmentId !== environmentId) {
      watched.current = { environmentId, seen: new Set(), warned: false };
    }
    const state = watched.current;
    if (access.kind === "failed") {
      if (!state.warned) {
        state.warned = true;
        console.warn("Infinitus pairing requests stream failed", { message: access.message });
      }
      return;
    }
    for (const request of unseenRequests(access.requests, state.seen)) {
      state.seen.add(request.id);
      toastManager.add(
        stackedThreadToast({
          type: "info",
          title: `“${request.deviceName}” wants to pair`,
          description: "Compare the code on the phone with the Devices card before approving.",
          actionProps: {
            children: "Open",
            onClick: () => {
              void navigate({ to: PAIRING_REQUESTS_ROUTE });
            },
          },
        }),
      );
    }
  }, [access, environmentId, navigate]);
}
