import * as Layer from "effect/Layer";

import * as InfinitusCaptureGesture from "../captures/InfinitusCaptureGesture.ts";
import * as InfinitusDeepLinks from "./InfinitusDeepLinks.ts";
import * as InfinitusDesktopPrefs from "./InfinitusDesktopPrefs.ts";
import * as InfinitusEngineSupervisor from "./InfinitusEngineSupervisor.ts";
import * as InfinitusHistoryGesture from "./InfinitusHistoryGesture.ts";
import * as InfinitusKeepAwake from "./InfinitusKeepAwake.ts";
import * as InfinitusOAuthSignIn from "./InfinitusOAuthSignIn.ts";
import * as InfinitusQuitWithApp from "./InfinitusQuitWithApp.ts";
import * as InfinitusSignIn from "./InfinitusSignIn.ts";
import * as InfinitusSignInRedirect from "./InfinitusSignInRedirect.ts";

/** Everything the fork adds to the desktop shell for the menu-bar app: the prefs file,
    quit-with-app, the sign-in window (#677) and the shell's own sign-in (#1213), the
    capture gesture, deep links, the keep-awake blocker and the proxy engines. */
export const layer = Layer.mergeAll(
  InfinitusQuitWithApp.layer,
  InfinitusSignIn.layer,
  // The same layer value, so the sign-in the shell runs itself borrows the
  // one window service (Effect memoises a layer by identity).
  InfinitusOAuthSignIn.layer.pipe(Layer.provide(InfinitusSignIn.layer)),
  InfinitusSignInRedirect.layer,
  InfinitusCaptureGesture.layer,
  InfinitusDeepLinks.layer,
  InfinitusKeepAwake.layer,
  InfinitusHistoryGesture.layer,
  InfinitusEngineSupervisor.layer,
).pipe(Layer.provideMerge(InfinitusDesktopPrefs.layer));
