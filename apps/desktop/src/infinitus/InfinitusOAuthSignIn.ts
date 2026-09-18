/**
 * A fleet's sign-in this app runs itself (#1213). Where #677 asks the menu-bar
 * app to drive the flow and pastes the code back, this one runs the account
 * engine's `add-oauth` here: swapd is the OAuth client, so its own loopback
 * listener catches the provider's redirect and there is no code — the shell
 * opens the URL the engine printed and reads the envelope it prints once the
 * account is stored. Nothing leaves this process but the URL.
 *
 * The URL opens in the system browser, not a child window: a passkey sign-in
 * never completed in the child window (the platform authenticator, as far as
 * we can tell, is the browser's to use and not an Electron window's), and a
 * browser is where a user's passkeys already are. The redirect lands on the
 * engine's listener whichever
 * browser rendered the page, so the flow is unchanged; what is lost is the
 * per-flow cookie jar, so the provider's page may offer the browser's current
 * account first, and a re-added account lands in its existing slot.
 *
 * It bends the fork's "one API" rule, which is about talking to the menu-bar
 * app: this spawns the engine's CLI directly, so `apps/desktop` knows the name
 * of one engine (`infinitusSwapd.logic.ts`). The alternative — the Mac app
 * running the verb while this shell only shows the window — is the placement
 * the user ruled out, since it leaves the desktop unable to add an account on
 * a machine where the menu-bar app is not running.
 */
import {
  type InfinitusOAuthSignInInput,
  type InfinitusOAuthSignInResult,
} from "@infinitus/contracts/infinitus";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import { makeComponentLogger } from "../app/DesktopObservability.ts";
import * as ElectronShell from "../electron/ElectronShell.ts";
import { isExecutableFile, startSwapdAddOAuth } from "./InfinitusSwapdProcess.ts";
import { resolveSwapdBinary } from "./infinitusSwapd.logic.ts";

const NO_ENGINE_ERROR = "No account engine on this Mac.";
const BROWSER_ERROR = "The browser could not be opened.";

export class InfinitusOAuthSignInService extends Context.Service<
  InfinitusOAuthSignInService,
  {
    /** Runs one whole sign-in: settles when the account is stored, the engine
        refused, or the flow was cancelled (`ok: false` with no message). */
    readonly begin: (input: InfinitusOAuthSignInInput) => Effect.Effect<InfinitusOAuthSignInResult>;
    readonly cancel: (flowId: string) => Effect.Effect<void>;
  }
>()("@infinitus/desktop/infinitus/InfinitusOAuthSignIn/InfinitusOAuthSignInService") {}

const { logInfo, logWarning } = makeComponentLogger("infinitus-oauth-sign-in");

const make = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const electronShell = yield* ElectronShell.ElectronShell;
  /** `…/Infinitus.app`, the bundle the menu-bar helper — and its copy of the
      engine — is nested in (#777). Only a packaged macOS build has one. */
  const desktopBundlePath =
    environment.isPackaged && environment.platform === "darwin"
      ? environment.path.resolve(environment.resourcesPath, "..", "..")
      : null;
  const flows = new Map<string, () => void>();

  const begin: InfinitusOAuthSignInService["Service"]["begin"] = Effect.fn(
    "infinitus.oauthSignIn.begin",
  )(function* (input) {
    const binary = resolveSwapdBinary({
      env: process.env,
      homeDirectory: environment.homeDirectory,
      desktopBundlePath,
      exists: isExecutableFile,
    });
    if (binary === null) {
      yield* logWarning("no account engine found", { provider: input.provider });
      return { ok: false, error: NO_ENGINE_ERROR };
    }

    let announce: ((url: string) => void) | null = null;
    const announced = new Promise<string>((resolve) => {
      announce = resolve;
    });
    const run = startSwapdAddOAuth({
      binary,
      provider: input.provider,
      onUrl: (url) => announce?.(url),
    });

    const cancel = () => {
      if (!flows.delete(input.flowId)) return;
      run.stop();
    };
    flows.set(input.flowId, cancel);

    // Whichever comes first: the listener is up, or the engine gave up before
    // it ever was.
    const url = yield* Effect.promise(() => Promise.race([announced, run.result.then(() => null)]));
    if (url !== null) {
      const opened = yield* electronShell.openExternal(url);
      if (!opened) {
        // Nothing will ever open that URL, and the engine would sit on its
        // listener for the whole timeout. End it here and say why.
        yield* logWarning("sign-in browser failed", { flowId: input.flowId });
        cancel();
        yield* Effect.promise(() => run.result);
        return { ok: false, error: BROWSER_ERROR };
      }
      // No window to close, so nothing but the page's Cancel or the engine's
      // own timeout ends a flow the user walked away from.
      yield* logInfo("sign-in opened in the browser", { flowId: input.flowId });
    }

    const outcome = yield* Effect.promise(() => run.result);
    flows.delete(input.flowId);
    yield* logInfo("sign-in ended", { flowId: input.flowId, ok: outcome.ok });
    return outcome;
  });

  const cancel: InfinitusOAuthSignInService["Service"]["cancel"] = (flowId) =>
    Effect.sync(() => {
      flows.get(flowId)?.();
    });

  return { begin, cancel } satisfies InfinitusOAuthSignInService["Service"];
});

export const layer = Layer.effect(InfinitusOAuthSignInService, make);
