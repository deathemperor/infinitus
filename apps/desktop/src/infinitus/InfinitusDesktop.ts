import * as Layer from "effect/Layer";

import * as InfinitusDesktopPrefs from "./InfinitusDesktopPrefs.ts";
import * as InfinitusQuitWithApp from "./InfinitusQuitWithApp.ts";

/** Everything the fork adds to the desktop shell for the menu-bar app: the
    prefs file, and the quit-with-app hook that reads it. */
export const layer = InfinitusQuitWithApp.layer.pipe(
  Layer.provideMerge(InfinitusDesktopPrefs.layer),
);
