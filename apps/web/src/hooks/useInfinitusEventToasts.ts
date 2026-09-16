import type { EnvironmentId } from "@infinitus/contracts";
import { useNavigate } from "@tanstack/react-router";
import { useEffect, useRef } from "react";

import { stackedThreadToast, toastManager } from "../components/ui/toast";
import { usePrimaryEnvironment } from "../state/environments";
import { infinitusEnvironment } from "../state/infinitus";
import { useEnvironmentQuery } from "../state/query";
import {
  hasDesktopNotifications,
  hasNotificationSound,
  playNotificationSound,
} from "../threadNotifications";
import { eventRepeatKey, eventToast } from "./infinitusEventToasts.logic";
import { getClientSettings, useClientSettings } from "./useSettings";

/** Ids remembered before the oldest are forgotten; the snapshot only ever
    carries a poll's worth, so this is far more than a page will meet. */
const SEEN_LIMIT = 1_000;

interface Watched {
  environmentId: EnvironmentId;
  /** Set once the first snapshot has been read: everything in it is history. */
  primed: boolean;
  seen: Set<string>;
  /** The news last toasted, so the same line re-emitted stays one toast. */
  lastToasted: string | null;
}

/**
 * Turns the Infinitus host's new events into the app's notifications: an
 * account switch, every account exhausted, and the app's own announcements
 * (#1032 finished — the menu bar app stays quiet whenever this is running,
 * so these are the account banners, not a second copy of them). Each gets
 * one Open action to /accounts. Nothing from the first snapshot after mount
 * (no replay on reload), nothing twice (by the server's id), and a line the
 * app re-emits unchanged only once. It is the web's one always-on snapshot
 * subscriber, so it is what keeps the fast poll and the client-activity
 * lease running whatever page is open.
 *
 * An urgent line — the fleet out of accounts, the last one nearly gone, a
 * crash — reaches the user where they are: a toast in the window, and a real
 * OS banner under `notificationMode` when the window is not in front. The
 * rest (a switch, an account back) stay toasts. Same two rules as a thread's
 * banner (`ThreadNotificationCoordinator`): the sound is the settings', and
 * the banner only fires when the window is away.
 */
export function useInfinitusEventToasts(): void {
  const environment = usePrimaryEnvironment();
  const environmentId = environment?.environmentId ?? null;
  const supported = environment?.serverConfig?.environment.capabilities.infinitus === true;
  const mode = useClientSettings((settings) => settings.notificationMode);
  const query = useEnvironmentQuery(
    environmentId === null || !supported
      ? null
      : infinitusEnvironment.snapshot({ environmentId, input: {} }),
  );
  const snapshot = query.data;
  const navigate = useNavigate();
  const watched = useRef<Watched | null>(null);

  useEffect(() => {
    if (environmentId === null || !supported || snapshot === null) return;
    if (watched.current === null || watched.current.environmentId !== environmentId) {
      watched.current = { environmentId, primed: false, seen: new Set(), lastToasted: null };
    }
    const state = watched.current;
    const events = snapshot.events ?? [];
    if (!state.primed) {
      state.primed = true;
      for (const event of events) state.seen.add(event.id);
      return;
    }
    for (const event of events) {
      if (state.seen.has(event.id)) continue;
      state.seen.add(event.id);
      if (state.seen.size > SEEN_LIMIT) {
        const oldest = state.seen.values().next().value;
        if (oldest !== undefined) state.seen.delete(oldest);
      }
      const toast = eventToast(event);
      if (toast === null) continue;
      const key = eventRepeatKey(event);
      if (key === state.lastToasted) continue;
      state.lastToasted = key;
      toastManager.add(
        stackedThreadToast({
          type: toast.type,
          title: toast.title,
          ...(toast.description === undefined ? {} : { description: toast.description }),
          actionProps: {
            children: "Open",
            onClick: () => {
              void navigate({ to: "/accounts" });
            },
          },
        }),
      );
      if (!toast.urgent) continue;
      // The fleet is out and nothing is running — the one piece of account
      // news worth a bell and a banner away from the window.
      // `input` of the two bundled sounds: this waits on the user the way an
      // approval does. The audio context is unlocked by the gesture listeners
      // `ThreadNotificationCoordinator` installs, and the settings are re-read
      // at play time there, so a mode turned off mid-decode stays silent.
      if (hasNotificationSound(mode)) {
        void playNotificationSound("input", () =>
          hasNotificationSound(getClientSettings().notificationMode),
        );
      }
      if (
        !hasDesktopNotifications(mode) ||
        (document.visibilityState === "visible" && document.hasFocus()) ||
        typeof Notification === "undefined" ||
        Notification.permission !== "granted"
      )
        continue;
      try {
        const notification = new Notification(toast.title, {
          ...(toast.description === undefined ? {} : { body: toast.description }),
          // One tag for the fleet: a second alert replaces the first rather
          // than stacking a Notification Center column while the user is out.
          tag: `${environmentId}:infinitus-accounts`,
          silent: true,
        });
        notification.addEventListener("click", () => {
          notification.close();
          window.focus();
          void navigate({ to: "/accounts" });
        });
      } catch {
        // Some browsers expose Notification but reject desktop presentation.
      }
    }
  }, [snapshot, environmentId, supported, navigate, mode]);
}
