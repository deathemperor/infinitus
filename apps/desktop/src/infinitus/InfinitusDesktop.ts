import * as Layer from "effect/Layer";

import * as InfinitusCaptureGesture from "../captures/InfinitusCaptureGesture.ts";
import * as InfinitusDeepLinks from "./InfinitusDeepLinks.ts";
import * as InfinitusDesktopPrefs from "./InfinitusDesktopPrefs.ts";
import * as InfinitusQuitWithApp from "./InfinitusQuitWithApp.ts";
import * as InfinitusSignIn from "./InfinitusSignIn.ts";

/** Everything the fork adds to the desktop shell for the menu-bar app: the
    prefs file, the quit-with-app hook that reads it, the in-app sign-in
    window (#677), the capture gesture (#433 slice 2) and the deep links
    (#270 D). */
export const layer = Layer.mergeAll(
  InfinitusQuitWithApp.layer,
  InfinitusSignIn.layer,
  InfinitusCaptureGesture.layer,
  InfinitusDeepLinks.layer,
).pipe(Layer.provideMerge(InfinitusDesktopPrefs.layer));
