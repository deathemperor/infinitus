import type { ClientSettings } from "@infinitus/contracts";

import type { SidebarThreadStatus } from "../components/Sidebar.logic";

/**
 * The fork's half of thread notifications (#1032, on upstream #11481): the
 * two states upstream has no title for, the quiet rule for the thread on
 * screen, the Dock badge's count and the queue rule (#270 B), and the
 * one-time mapping of the old #270 B toggles and #270 H sound onto
 * upstream's `notificationMode`.
 */
const ATTENTION_TITLES: Partial<Record<SidebarThreadStatus, string>> = {
  approval: "Approval needed",
  input: "Input needed",
  held: "Held for headroom",
  // Upstream's word since #11372, adopted here so the fork carries no second
  // vocabulary for the same banner: a thread is the product's noun, a session
  // is the provider's. `held` and `limited` stay ours — upstream has neither.
  failed: "Thread failed",
};

/** The banner title for a state that waits on the user, else null. */
export function attentionNotificationTitle(status: SidebarThreadStatus): string | null {
  return ATTENTION_TITLES[status] ?? null;
}

/** The thread on screen needs no banner or bell while the window has focus. */
export function quietForViewer(
  viewedKey: string | null,
  key: string,
  doc: { readonly visibilityState: DocumentVisibilityState; readonly hasFocus: () => boolean },
): boolean {
  return viewedKey === key && doc.visibilityState === "visible" && doc.hasFocus();
}

/** What a thread's notification record looks like between two renders. */
export interface ThreadNotificationRecord {
  /** The waiting turn and state, null while nothing waits on the user. */
  readonly input: string | null;
  /** The latest completion seen, as epoch ms. */
  readonly completion: number | null;
}

/**
 * What to ring for a thread whose record changed. A new wait on the user
 * always rings: the queue cannot drain past an approval or a question. A
 * later completion rings only while nothing is queued (#270 B): the drain
 * sends the next row the moment the turn ends, so the thread is not done.
 * The completion still counts as seen, so a queued row the user removes
 * afterwards rings nothing for it.
 */
export function notificationKind(
  prior: ThreadNotificationRecord,
  next: ThreadNotificationRecord,
  queuedCount: number,
): "input" | "completion" | null {
  if (next.input !== null && next.input !== prior.input) return "input";
  if (
    queuedCount === 0 &&
    next.completion !== null &&
    (prior.completion === null || next.completion > prior.completion)
  )
    return "completion";
  return null;
}

/** The threads waiting on the user: an approval to give or a question to answer. */
export function attentionCount(
  threads: ReadonlyArray<{ readonly status: SidebarThreadStatus }>,
): number {
  let count = 0;
  for (const thread of threads) {
    if (thread.status === "approval" || thread.status === "input") count += 1;
  }
  return count;
}

type LegacyBannerFlags = Pick<
  ClientSettings,
  | "desktopNotifyOnApproval"
  | "desktopNotifyOnInput"
  | "desktopNotifyOnHeld"
  | "desktopNotifyOnFailure"
>;

/**
 * What `notificationMode` the old settings amount to. Banners were on by
 * default (an absent flag counts as on) and desktop-only (`null` flags: no
 * desktop shell, so no banners); the sound was this window's own switch.
 */
export function legacyNotificationMode(
  flags: Partial<LegacyBannerFlags> | null,
  soundEnabled: boolean,
): ClientSettings["notificationMode"] {
  const banners =
    flags !== null &&
    (flags.desktopNotifyOnApproval !== false ||
      flags.desktopNotifyOnInput !== false ||
      flags.desktopNotifyOnHeld !== false ||
      flags.desktopNotifyOnFailure !== false);
  if (banners) return soundEnabled ? "notifications-and-sound" : "notifications";
  return soundEnabled ? "sound" : "off";
}
