/**
 * A fleet's sign-in this app runs itself (#1213): swapd's `add-oauth` runs here and
 * catches the redirect on its own loopback listener. The URL opens in a private window of
 * the default browser (passkeys never completed in a child window), else the menu-bar
 * app's sheet, last the child window; decided before spawn. Bends the "one API" rule.
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
  const runFork = Effect.runForkWith(yield* Effect.context<never>());
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
      Effect.catchTags({
        InfinitusCommandFailed: (failure) =>
          Effect.succeed({ kind: "refused" as const, error: failure.error }),
      }),
      Effect.orElseSucceed(() => ({ kind: "unavailable" as const })),
    );
    if (begun.kind === "unavailable") return null;
    if (begun.kind === "refused") return { ok: false, error: begun.error };
    const macFlowId = begun.reply.flowId;
    // The flow's entry is its life: `cancel` removes it (and tells the app),
    // and the poll below ends with it.
    flows.set(input.flowId, () => {
      flows.delete(input.flowId);
      runFork(
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
        Effect.orElseSucceed(() => null),
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

  const cancel: InfinitusOAuthSignInService["Service"]["cancel"] = Effect.fn(
    "infinitus.oauthSignIn.cancel",
  )(function* (flowId) {
    flows.get(flowId)?.();
    yield* signInWindow.close(flowId);
  });

  return { begin, cancel } satisfies InfinitusOAuthSignInService["Service"];
});

export const layer = Layer.effect(InfinitusOAuthSignInService, make);
