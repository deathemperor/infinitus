/**
 * A fleet's sign-in this app runs itself (#1213). Where #677 asks the menu-bar
 * app to drive the flow and pastes the code back, this one runs the account
 * engine's `add-oauth` here: swapd is the OAuth client, so its own loopback
 * listener catches the provider's redirect and there is no code — the shell
 * opens the URL the engine printed and reads the envelope it prints once the
 * account is stored. Nothing leaves this process but the URL.
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
import * as ElectronWindow from "../electron/ElectronWindow.ts";
import { signInWindowOptions } from "./InfinitusSignIn.ts";
import { isExecutableFile, startSwapdAddOAuth } from "./InfinitusSwapdProcess.ts";
import { resolveSwapdBinary } from "./infinitusSwapd.logic.ts";

const NO_ENGINE_ERROR = "No account engine on this Mac.";
const WINDOW_ERROR = "The sign-in window could not be opened.";

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
  const electronWindow = yield* ElectronWindow.ElectronWindow;
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

    let window: Electron.BrowserWindow | null = null;
    const cancel = () => {
      if (!flows.delete(input.flowId)) return;
      run.stop();
    };
    flows.set(input.flowId, cancel);

    // Whichever comes first: the listener is up, or the engine gave up before
    // it ever was.
    const url = yield* Effect.promise(() => Promise.race([announced, run.result.then(() => null)]));
    if (url !== null) {
      window = yield* electronWindow
        .create(
          signInWindowOptions(
            { flowId: input.flowId, url, label: input.label },
            environment.platform,
          ),
        )
        .pipe(
          Effect.tapError((error) => logWarning("sign-in window failed", { error })),
          Effect.catch(() => Effect.succeed(null)),
        );
      if (window === null) {
        // Nothing will ever open that URL, and the engine would sit on its
        // listener for the whole timeout. End it here and say why.
        cancel();
        yield* Effect.promise(() => run.result);
        return { ok: false, error: WINDOW_ERROR };
      }
      window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
      // Unlike #677 there is nothing to paste elsewhere: closing the page
      // ends the flow, rather than leaving it to the engine's timeout.
      window.once("closed", cancel);
      window.loadURL(url).catch(() => undefined);
      yield* logInfo("sign-in window opened", { flowId: input.flowId });
    }

    const outcome = yield* Effect.promise(() => run.result);
    flows.delete(input.flowId);
    if (window !== null && !window.isDestroyed()) window.close();
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
