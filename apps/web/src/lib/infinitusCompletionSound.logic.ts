import type { OrchestrationLatestTurn } from "@t3tools/contracts";

/**
 * The completion sound's pure half (#270 H): which sounds exist, and when a
 * turn's finish should ring. It rings when a thread this window already knew
 * reaches a completed turn it had not seen completed — a turn seen running
 * before, or one that ran between two renders — and only while the window
 * is in the background; the window the user is looking at needs no bell.
 */
export const COMPLETION_SOUNDS = ["chime", "whoosh", "click"] as const;
export type CompletionSound = (typeof COMPLETION_SOUNDS)[number];
export const DEFAULT_COMPLETION_SOUND: CompletionSound = "chime";

export interface CompletionSoundPreference {
  readonly enabled: boolean;
  readonly sound: CompletionSound;
}

export const DEFAULT_COMPLETION_SOUND_PREFERENCE: CompletionSoundPreference = {
  enabled: false,
  sound: DEFAULT_COMPLETION_SOUND,
};

export function completionSoundLabel(sound: CompletionSound): string {
  switch (sound) {
    case "chime":
      return "Chime";
    case "whoosh":
      return "Whoosh";
    case "click":
      return "Click";
  }
}

export function isCompletionSound(value: unknown): value is CompletionSound {
  return typeof value === "string" && (COMPLETION_SOUNDS as ReadonlyArray<string>).includes(value);
}

/** What a thread's latest turn looked like last render: its id and state. */
export type SeenTurn = `${string}:${OrchestrationLatestTurn["state"]}`;

export interface TurnShell {
  readonly environmentId: string;
  readonly id: string;
  readonly latestTurn: {
    readonly turnId: string;
    readonly state: OrchestrationLatestTurn["state"];
  } | null;
}

/**
 * The threads whose latest turn just completed, and the map to keep for the
 * next render. A thread absent from `previous` (first render, a server that
 * just bootstrapped) is only recorded, never rung.
 */
export function turnsJustCompleted(
  previous: ReadonlyMap<string, SeenTurn | null>,
  shells: ReadonlyArray<TurnShell>,
): {
  readonly completed: ReadonlyArray<string>;
  readonly next: ReadonlyMap<string, SeenTurn | null>;
} {
  const next = new Map<string, SeenTurn | null>();
  const completed: string[] = [];
  for (const shell of shells) {
    const key = `${shell.environmentId}:${shell.id}`;
    const seen: SeenTurn | null =
      shell.latestTurn === null ? null : `${shell.latestTurn.turnId}:${shell.latestTurn.state}`;
    next.set(key, seen);
    if (!previous.has(key)) continue;
    if (shell.latestTurn?.state === "completed" && previous.get(key) !== seen) completed.push(key);
  }
  return { completed, next };
}

/** In the background: hidden, or visible but not the focused window. */
export function windowInBackground(doc: {
  readonly visibilityState: DocumentVisibilityState;
  readonly hasFocus: () => boolean;
}): boolean {
  return doc.visibilityState !== "visible" || !doc.hasFocus();
}
