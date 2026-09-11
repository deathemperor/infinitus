import { AsyncResult } from "effect/unstable/reactivity";

/** Whether this phone pins new tasks as they are created (#742, the web's
    "Pin on create" of #753): the loaded preference, off by default and off
    while the store is still loading (a queued task then drains unpinned
    rather than waiting on it). */
export function pinAtCreationEnabled(
  preferences: AsyncResult.AsyncResult<{ readonly infinitusPinAtCreation?: boolean }, unknown>,
): boolean {
  return AsyncResult.isSuccess(preferences) && preferences.value.infinitusPinAtCreation === true;
}

export const PIN_AT_CREATION_HINT = "New tasks run first when headroom is low";
