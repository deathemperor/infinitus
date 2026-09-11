/**
 * A fleet's sign-in inside this app (#677). The menu-bar app runs the flow
 * with no window of its own (`signin-begin`); this shell shows the provider's
 * page in a child window per flow — a fresh in-memory partition, so one
 * account's cookies never meet another's, gone when the window closes — and
 * hands the code from the success page to the app over its control socket as
 * the request's `secret`, the way stdin material always travels. The code
 * never crosses an RPC, the server or the tunnel: only this process can send
 * it, which is the whole of the "desktop only" rule.
 */
import * as NodeOS from "node:os";

import {
  type InfinitusSignInCodeInput,
  InfinitusSignInCodeResult,
  type InfinitusSignInWindowInput,
} from "@t3tools/contracts/infinitus";
import { PRODUCT_NAME } from "@t3tools/contracts/productName";
import { resolveInfinitusControlSocketPath } from "@t3tools/shared/infinitusControl";
import {
  type InfinitusControlError,
  type InfinitusControlRequestInput,
  requestInfinitusControl,
} from "@t3tools/shared/infinitusControlSocket";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import { makeComponentLogger } from "../app/DesktopObservability.ts";
import * as ElectronWindow from "../electron/ElectronWindow.ts";

const CODE_COMMAND = "signin-code";
/** The app answers a bad paste within a second and a good one within a few;
    its own deadline is fifteen seconds. */
const CODE_TIMEOUT_MS = 20_000;

/** In-memory (no `persist:`): the jar lives as long as the window. */
export const signInPartition = (flowId: string): string => `signin-${flowId}`;

/** The child window's options: the provider's page and nothing of ours in it
    — no preload, no node, sandboxed, its own partition. */
export const signInWindowOptions = (
  input: InfinitusSignInWindowInput,
  platform: NodeJS.Platform,
): Electron.BrowserWindowConstructorOptions => ({
  width: 520,
  height: 720,
  minWidth: 400,
  minHeight: 500,
  title: `${input.label} — ${PRODUCT_NAME}`,
  autoHideMenuBar: true,
  ...(platform === "darwin" ? { titleBarStyle: "default" as const } : {}),
  webPreferences: {
    partition: signInPartition(input.flowId),
    contextIsolation: true,
    nodeIntegration: false,
    sandbox: true,
    webviewTag: false,
  },
});

const decodeCodeResult = Schema.decodeUnknownEffect(InfinitusSignInCodeResult);

/**
 * `signin-code <flowId>` with the code as `secret`. The app's refusal (the
 * CLI's "Invalid code…" / "OAuth error: …" wording, or "not waiting for a
 * code") comes back as `ok: false` with its words; an app that is not there
 * says so in the same shape, so the page has one thing to show.
 */
export const submitSignInCode = Effect.fn("infinitus.submitSignInCode")(function* (
  request: (input: InfinitusControlRequestInput) => Effect.Effect<unknown, InfinitusControlError>,
  input: InfinitusSignInCodeInput,
): Effect.fn.Return<InfinitusSignInCodeResult> {
  const code = input.code.trim();
  if (code.length === 0) return { ok: false, error: "Paste the code from the sign-in page." };
  return yield* request({ command: CODE_COMMAND, args: [input.flowId], secret: code }).pipe(
    Effect.flatMap(decodeCodeResult),
    Effect.catchTag("InfinitusCommandFailed", (failure) =>
      Effect.succeed({ ok: false, error: failure.error }),
    ),
    Effect.catchTag("InfinitusUnavailable", () =>
      Effect.succeed({ ok: false, error: `${PRODUCT_NAME} is not running on this Mac.` }),
    ),
    Effect.catch(() =>
      Effect.succeed({ ok: false, error: `${PRODUCT_NAME} did not answer the code.` }),
    ),
  );
});

export class InfinitusSignInService extends Context.Service<
  InfinitusSignInService,
  {
    /** Shows the flow's page; a second call for the same flow focuses it. */
    readonly open: (input: InfinitusSignInWindowInput) => Effect.Effect<void>;
    /** Closes the flow's window if it is still open. */
    readonly close: (flowId: string) => Effect.Effect<void>;
    readonly submitCode: (
      input: InfinitusSignInCodeInput,
    ) => Effect.Effect<InfinitusSignInCodeResult>;
  }
>()("@t3tools/desktop/infinitus/InfinitusSignIn/InfinitusSignInService") {}

const { logInfo, logWarning } = makeComponentLogger("infinitus-sign-in");

const make = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const electronWindow = yield* ElectronWindow.ElectronWindow;
  const socketPath = resolveInfinitusControlSocketPath({
    platform: environment.platform,
    env: process.env,
    homeDir: NodeOS.homedir(),
  });
  const windows = new Map<string, Electron.BrowserWindow>();

  const open: InfinitusSignInService["Service"]["open"] = Effect.fn("infinitus.signIn.open")(
    function* (input) {
      const existing = windows.get(input.flowId);
      if (existing !== undefined && !existing.isDestroyed()) {
        existing.focus();
        return;
      }
      const window = yield* electronWindow
        .create(signInWindowOptions(input, environment.platform))
        .pipe(
          Effect.tapError((error) => logWarning("sign-in window failed", { error })),
          Effect.catch(() => Effect.succeed(null)),
        );
      if (window === null) return;
      windows.set(input.flowId, window);
      // The provider's page may open pop-ups; they stay in the same jar.
      window.webContents.setWindowOpenHandler(() => ({ action: "deny" }));
      window.once("closed", () => {
        windows.delete(input.flowId);
      });
      window.loadURL(input.url).catch(() => undefined);
      yield* logInfo("sign-in window opened", { flowId: input.flowId });
    },
  );

  const close: InfinitusSignInService["Service"]["close"] = (flowId) =>
    Effect.sync(() => {
      const window = windows.get(flowId);
      windows.delete(flowId);
      if (window !== undefined && !window.isDestroyed()) window.close();
    });

  const submitCode: InfinitusSignInService["Service"]["submitCode"] = (input) =>
    socketPath === null
      ? Effect.succeed({ ok: false, error: `${PRODUCT_NAME} has no control socket here.` })
      : submitSignInCode(
          (request) => requestInfinitusControl({ socketPath, request, timeoutMs: CODE_TIMEOUT_MS }),
          input,
        );

  return { open, close, submitCode } satisfies InfinitusSignInService["Service"];
});

export const layer = Layer.effect(InfinitusSignInService, make);
