import {
  threadRuntimeCanArchive,
  type ThreadRuntimeSummary,
} from "@infinitus/client-runtime/state/models";

/**
 * Archiving may discard queued work, but it must not detach a provider while
 * that provider is still executing a turn.
 */
export function threadCanArchive(runtime: ThreadRuntimeSummary | null | undefined): boolean {
  return threadRuntimeCanArchive(runtime);
}
