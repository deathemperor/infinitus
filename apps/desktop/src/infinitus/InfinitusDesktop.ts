import * as Layer from "effect/Layer";

import * as InfinitusDesktopPrefs from "./InfinitusDesktopPrefs.ts";
import * as InfinitusQuitWithApp from "./InfinitusQuitWithApp.ts";
import * as InfinitusSignIn from "./InfinitusSignIn.ts";

/** Everything the fork adds to the desktop shell for the menu-bar app: the
    prefs file, the quit-with-app hook that reads it, and the in-app sign-in
    window (#677). */
export const layer = Layer.mergeAll(InfinitusQuitWithApp.layer, InfinitusSignIn.layer).pipe(
  Layer.provideMerge(InfinitusDesktopPrefs.layer),
);
