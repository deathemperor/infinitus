/**
 * A fleet's sign-in this app runs itself (#1213). Where #677 asks the menu-bar
 * app to drive the flow and pastes the code back, this one runs the account
 * engine's `add-oauth` here: swapd is the OAuth client, so its own loopback
 * listener catches the provider's redirect and there is no code — the shell
 * opens the URL the engine printed and reads the envelope it prints once the
 * account is stored. Nothing leaves this process but the URL.
 *
 * The URL opens in a private window of the default browser where it has a
 * switch for one (the Chromium family, on an empty profile): a passkey sign-in
 * never completed in a child window (the platform authenticator, as far as we
 * can tell, is the browser's to use and not an Electron window's), and a
 * browser is where a user's passkeys already are. A browser with no such
 * switch (Safari) must not get the page in its signed-in profile — that
 * offered the account already there and made the user switch accounts to add
 * one (2026-09-21) — and a child window of ours has no passkeys, which the
 * user needs too. So that case is handed to the menu-bar app on this same Mac
 * (`signin-begin --window`): its ephemeral system sheet is private AND has
 * passkeys, and the engine it runs takes the redirect, so this shell only
 * polls `signin-status` for the outcome. The child window (#677's, a fresh
 * in-memory partition) is the last resort, when the menu-bar app is not
 * running. Decided before the engine is spawned: two listeners cannot share
 * the loopback port.
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
import { InfinitusUnavailable } from "@infinitus/contracts/infinitus";
import { PRODUCT_NAME } from "@infinitus/contracts/productName";
import { resolveInfinitusControlSocketPath } from "@infinitus/shared/infinitusControl";
import {
  type InfinitusControlError,
  type InfinitusControlRequestInput,
  requestInfinitusControl,
} from "@infinitus/shared/infinitusControlSocket";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";
import * as NodeOS from "node:os";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import { makeComponentLogger } from "../app/DesktopObservability.ts";
import { InfinitusSignInService } from "./InfinitusSignIn.ts";
import {
  isExecutableFile,
  openInPrivateWindow,
  privateWindowBrowser,
  startSwapdAddOAuth,
} from "./InfinitusSwapdProcess.ts";
import { resolveSwapdBinary } from "./infinitusSwapd.logic.ts";

const NO_ENGINE_ERROR = "No account engine on this Mac.";
/** The child window's title, ahead of the product name. */
const WINDOW_LABEL = "Sign in";

/** `signin-begin` answers once the engine has printed its URL, within its own
    30 s; a status poll is a read. */
const BEGIN_TIMEOUT_MS = 40_000;
const STATUS_TIMEOUT_MS = 5_000;
const STATUS_POLL_MS = 1_000;

const decodeBegun = Schema.decodeUnknownEffect(
  Schema.Struct({ flowId: Schema.String, window: Schema.optionalKey(Schema.Boolean) }),
);
const decodeStatus = Schema.decodeUnknownEffect(
  Schema.Struct({
    phase: Schema.String,
    error: Schema.optionalKey(Schema.NullOr(Schema.String)),
    account: Schema.optionalKey(Schema.NullOr(Schema.String)),
  }),
);

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
  const signInWindow = yield* InfinitusSignInService;
  const socketPath = resolveInfinitusControlSocketPath({
    platform: environment.platform,
    env: process.env,
    homeDir: NodeOS.homedir(),
  });
  const request = (
    input: InfinitusControlRequestInput,
    timeoutMs: number,
  ): Effect.Effect<unknown, InfinitusControlError> =>
    socketPath === null
      ? Effect.fail(new InfinitusUnavailable({ path: "", cause: "no control socket here" }))
      : requestInfinitusControl({ socketPath, request: input, timeoutMs });
  /** `…/Infinitus.app`, the bundle the menu-bar helper — and its copy of the
      engine — is nested in (#777). Only a packaged macOS build has one. */
  const desktopBundlePath =
    environment.isPackaged && environment.platform === "darwin"
      ? environment.path.resolve(environment.resourcesPath, "..", "..")
      : null;
  const flows = new Map<string, () => void>();

  /** The sign-in run by the menu-bar app with its own sheet. Null when the
      app is not running here (the caller falls back); otherwise the outcome,
      the app's own error text included. */
  const beginOnMac = Effect.fn("infinitus.oauthSignIn.beginOnMac")(function* (
    input: InfinitusOAuthSignInInput & { readonly fleet: string },
  ): Effect.fn.Return<InfinitusOAuthSignInResult | null> {
    const begun = yield* request(
      {
        command: "signin-begin",
        args: [input.fleet],
        options: {
          window: "1",
          ...(input.relogin === undefined ? {} : { relogin: input.relogin }),
        },
      },
      BEGIN_TIMEOUT_MS,
    ).pipe(
      Effect.flatMap(decodeBegun),
      Effect.map((reply) => ({ kind: "begun" as const, reply })),
      Effect.catchTag("InfinitusCommandFailed", (failure) =>
        Effect.succeed({ kind: "refused" as const, error: failure.error }),
      ),
      Effect.catch(() => Effect.succeed({ kind: "unavailable" as const })),
    );
    if (begun.kind === "unavailable") return null;
    if (begun.kind === "refused") return { ok: false, error: begun.error };
    const macFlowId = begun.reply.flowId;
    // The flow's entry is its life: `cancel` removes it (and tells the app),
    // and the poll below ends with it.
    flows.set(input.flowId, () => {
      flows.delete(input.flowId);
      Effect.runFork(
        request({ command: "signin-cancel", args: [macFlowId] }, STATUS_TIMEOUT_MS).pipe(
          Effect.catch(() => Effect.void),
        ),
      );
    });
    yield* logInfo("sign-in handed to the menu-bar app", { flowId: input.flowId, macFlowId });
    while (flows.has(input.flowId)) {
      yield* Effect.sleep(STATUS_POLL_MS);
      if (!flows.has(input.flowId)) break;
      const status = yield* request(
        { command: "signin-status", args: [macFlowId] },
        STATUS_TIMEOUT_MS,
      ).pipe(
        Effect.flatMap(decodeStatus),
        Effect.catch(() => Effect.succeed(null)),
      );
      if (status === null) continue;
      if (status.phase === "done") {
        flows.delete(input.flowId);
        return { ok: true, ...(status.account == null ? {} : { email: status.account }) };
      }
      if (status.phase === "failed") {
        flows.delete(input.flowId);
        return { ok: false, error: status.error ?? `${PRODUCT_NAME} gave no reason.` };
      }
    }
    return { ok: false };
  });

  const begin: InfinitusOAuthSignInService["Service"]["begin"] = Effect.fn(
    "infinitus.oauthSignIn.begin",
  )(function* (input) {
    // Where the page will show decides who runs the sign-in, so it is
    // settled before any engine is spawned.
    const privateBrowser =
      environment.platform === "darwin" &&
      (yield* Effect.promise(() => privateWindowBrowser("https://claude.ai/"))) !== null;
    if (!privateBrowser && input.fleet !== undefined) {
      const outcome = yield* beginOnMac({ ...input, fleet: input.fleet });
      if (outcome !== null) return outcome;
      yield* logInfo("menu-bar app not running; the shell signs in itself", {
        flowId: input.flowId,
      });
    }

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
      const inBrowser = privateBrowser && (yield* Effect.promise(() => openInPrivateWindow(url)));
      if (inBrowser) {
        // No window of ours to close, so nothing but the page's Cancel or
        // the engine's own timeout ends a flow the user walked away from.
        yield* logInfo("sign-in opened in the browser", { flowId: input.flowId });
      } else {
        yield* signInWindow.open({ flowId: input.flowId, url, label: WINDOW_LABEL });
        yield* logInfo("sign-in opened in a private window", { flowId: input.flowId });
      }
    }

    const outcome = yield* Effect.promise(() => run.result);
    flows.delete(input.flowId);
    yield* signInWindow.close(input.flowId);
    yield* logInfo("sign-in ended", { flowId: input.flowId, ok: outcome.ok });
    return outcome;
  });

  const cancel: InfinitusOAuthSignInService["Service"]["cancel"] = (flowId) =>
    Effect.gen(function* () {
      flows.get(flowId)?.();
      yield* signInWindow.close(flowId);
    });

  return { begin, cancel } satisfies InfinitusOAuthSignInService["Service"];
});

export const layer = Layer.effect(InfinitusOAuthSignInService, make);
