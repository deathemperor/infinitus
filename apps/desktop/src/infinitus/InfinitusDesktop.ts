import * as Layer from "effect/Layer";

import * as InfinitusCaptureGesture from "../captures/InfinitusCaptureGesture.ts";
import * as InfinitusDeepLinks from "./InfinitusDeepLinks.ts";
import * as InfinitusDesktopPrefs from "./InfinitusDesktopPrefs.ts";
import * as InfinitusHistoryGesture from "./InfinitusHistoryGesture.ts";
import * as InfinitusKeepAwake from "./InfinitusKeepAwake.ts";
import * as InfinitusOAuthSignIn from "./InfinitusOAuthSignIn.ts";
import * as InfinitusQuitWithApp from "./InfinitusQuitWithApp.ts";
import * as InfinitusSignIn from "./InfinitusSignIn.ts";

/** Everything the fork adds to the desktop shell for the menu-bar app: the
    prefs file, the quit-with-app hook that reads it, the in-app sign-in
    window (#677), the sign-in the shell runs itself (#1213), the capture
    gesture (#433 slice 2), the deep links (#270 D) and the keep-awake
    blocker (#1075). */
export const layer = Layer.mergeAll(
  InfinitusQuitWithApp.layer,
  InfinitusSignIn.layer,
  InfinitusOAuthSignIn.layer,
  InfinitusCaptureGesture.layer,
  InfinitusDeepLinks.layer,
  InfinitusKeepAwake.layer,
  InfinitusHistoryGesture.layer,
).pipe(Layer.provideMerge(InfinitusDesktopPrefs.layer));
