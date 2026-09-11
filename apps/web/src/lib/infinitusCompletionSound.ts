import { create } from "zustand";

import completionChimeUrl from "../assets/infinitus-completion-chime.wav?url";
import snapShotClickUrl from "../assets/snap-shot-click.mp3?url";
import snapShotWhooshUrl from "../assets/snap-shot-whoosh.mp3?url";
import {
  type CompletionSound,
  type CompletionSoundPreference,
  DEFAULT_COMPLETION_SOUND_PREFERENCE,
  isCompletionSound,
} from "./infinitusCompletionSound.logic";

/**
 * The completion sound (#270 H): a per-window preference (this browser, this
 * desktop install — a sound is a property of the machine that plays it, so
 * it stays out of the shared client settings) and the player. Off by default.
 */
const STORAGE_KEY = "infinitus:completion-sound:v1";

function readPreference(): CompletionSoundPreference {
  try {
    const raw = typeof window === "undefined" ? null : window.localStorage.getItem(STORAGE_KEY);
    if (raw === null) return DEFAULT_COMPLETION_SOUND_PREFERENCE;
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== "object" || parsed === null) return DEFAULT_COMPLETION_SOUND_PREFERENCE;
    const record = parsed as Record<string, unknown>;
    return {
      enabled: record.enabled === true,
      sound: isCompletionSound(record.sound)
        ? record.sound
        : DEFAULT_COMPLETION_SOUND_PREFERENCE.sound,
    };
  } catch {
    return DEFAULT_COMPLETION_SOUND_PREFERENCE;
  }
}

function writePreference(preference: CompletionSoundPreference): void {
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(preference));
  } catch {
    // A full or blocked store keeps the in-memory value for this session.
  }
}

export const useCompletionSoundPreference = create<CompletionSoundPreference>(() =>
  readPreference(),
);

export function setCompletionSoundPreference(patch: Partial<CompletionSoundPreference>): void {
  const next = { ...useCompletionSoundPreference.getState(), ...patch };
  useCompletionSoundPreference.setState(next);
  writePreference(next);
}

const SOUND_URLS: Record<CompletionSound, string> = {
  chime: completionChimeUrl,
  whoosh: snapShotWhooshUrl,
  click: snapShotClickUrl,
};

export function playCompletionSound(sound: CompletionSound): void {
  const audio = new Audio(SOUND_URLS[sound]);
  audio.preload = "auto";
  audio.currentTime = 0;
  void audio.play().catch(() => undefined);
}
