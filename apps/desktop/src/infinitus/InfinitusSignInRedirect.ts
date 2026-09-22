// @effect-diagnostics nodeBuiltinImport:off -- This platform boundary binds the loopback port the OAuth redirect names.

/**
 * The engine's loopback listener, stood in for on this machine. A sign-in an
 * engine finishes itself (swapd's `add-oauth`, the proxy) ends on
 * `http://localhost:<port>/callback?code=…&state=…`, and the engine listens
 * there — on the Mac that owns it. When this desktop looks at ANOTHER Mac's
 * environment, the page opens in this machine's browser, so the redirect
 * comes to this machine's loopback instead. This service takes that port
 * for the flow's lifetime, answers the browser's one request the way the
 * engine would, and hands the address it carried back to the page, which
 * sends it over `signin-code` for the Mac to replay on its own listener.
 * Nothing to copy: the browser shows "Signed in" and the account lands.
 *
 * The address carries the code, so it goes to the renderer over IPC and on
 * to the server as a secret, the way the pasted one does; it reaches no log.
 * A port already held (an engine of this Mac's own is signing in, a proxy
 * sits on 54545) answers `ok: false`, and the page falls back to the field.
 */
import * as NodeHttp from "node:http";

import type {
  InfinitusSignInRedirectListenInput,
  InfinitusSignInRedirectResult,
} from "@infinitus/contracts/infinitus";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import { makeComponentLogger } from "../app/DesktopObservability.ts";
import { InfinitusSignInService } from "./InfinitusSignIn.ts";
import { openInPrivateWindow } from "./InfinitusSwapdProcess.ts";

/** The engine's own path; anything else on the port is not the redirect. */
const CALLBACK_PATH = "/callback";

/** What the stand-in answers one request with: the engine's own words for
    the callback (swapd's `serve`), so the browser tab reads the same whether
    the redirect landed here or there. `redirect` is the address to hand on —
    only for the callback path; a favicon probe or a stray hit is answered
    and ignored. The provider's refusal (`error=`) is handed on too: the Mac
    reads it off the query and words it. */
export function signInRedirectResponse(requestUrl: string): {
  readonly status: number;
  readonly body: string;
  readonly redirect: string | null;
} {
  const target = new URL(requestUrl, "http://localhost");
  if (target.pathname !== CALLBACK_PATH) {
    return { status: 404, body: "Not found.", redirect: null };
  }
  const refused = target.searchParams.has("error");
  return {
    status: 200,
    body: refused
      ? "Sign-in failed. You can close this window."
      : "Signed in. You can close this window.",
    redirect: requestUrl,
  };
}

export interface SignInRedirectListener {
  /** Settles with the address the browser brought, or `ok: false` once
      stopped without one. */
  readonly result: Promise<InfinitusSignInRedirectResult>;
  readonly stop: () => void;
}

/**
 * Binds `127.0.0.1:<port>` and waits for the callback. The engine's listener
 * takes `::1` too, best-effort, because a browser resolving `localhost` may
 * pick either; here the same. A port already held rejects the bind, and the
 * result says so.
 */
export function listenForSignInRedirect(input: {
  readonly port: number;
  readonly hosts?: ReadonlyArray<string>;
}): SignInRedirectListener {
  let settle: ((result: InfinitusSignInRedirectResult) => void) | null = null;
  const result = new Promise<InfinitusSignInRedirectResult>((resolve) => {
    settle = resolve;
  });
  const servers: NodeHttp.Server[] = [];
  const finish = (value: InfinitusSignInRedirectResult) => {
    const resolve = settle;
    settle = null;
    for (const server of servers) server.close();
    servers.length = 0;
    resolve?.(value);
  };
  const handle = (request: NodeHttp.IncomingMessage, response: NodeHttp.ServerResponse) => {
    const answer = signInRedirectResponse(request.url ?? "/");
    response.writeHead(answer.status, { "Content-Type": "text/html; charset=utf-8" });
    response.end(`<!doctype html><meta charset=utf-8><p>${answer.body}</p>`);
    if (answer.redirect !== null) {
      // The whole address as the browser had it: the Mac checks the host,
      // the port and the state itself before it replays anything.
      finish({ ok: true, redirect: `http://localhost:${input.port}${answer.redirect}` });
    }
  };

  const hosts = input.hosts ?? ["127.0.0.1", "::1"];
  const [required, ...optional] = hosts;
  const bind = (host: string, onError: (error: NodeJS.ErrnoException) => void) => {
    const server = NodeHttp.createServer(handle);
    server.once("error", onError);
    server.listen(input.port, host);
    servers.push(server);
  };
  if (required !== undefined) {
    bind(required, (error) => {
      finish({
        ok: false,
        error:
          error.code === "EADDRINUSE"
            ? `Port ${input.port} is in use on this machine, so the sign-in cannot end here.`
            : error.message,
      });
    });
  }
  // The other family is a bonus: its failure changes nothing.
  for (const host of optional) {
    bind(host, () => undefined);
  }

  return { result, stop: () => finish({ ok: false }) };
}

export class InfinitusSignInRedirectService extends Context.Service<
  InfinitusSignInRedirectService,
  {
    /** Takes the port, opens the page, and settles when the browser's
        redirect lands here or the flow is stopped. */
    readonly listen: (
      input: InfinitusSignInRedirectListenInput,
    ) => Effect.Effect<InfinitusSignInRedirectResult>;
    readonly stop: (flowId: string) => Effect.Effect<void>;
  }
>()("@infinitus/desktop/infinitus/InfinitusSignInRedirect/InfinitusSignInRedirectService") {}

const { logInfo, logWarning } = makeComponentLogger("infinitus-sign-in-redirect");

const make = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const signInWindow = yield* InfinitusSignInService;
  const flows = new Map<string, () => void>();

  const listen: InfinitusSignInRedirectService["Service"]["listen"] = Effect.fn(
    "infinitus.signInRedirect.listen",
  )(function* (input) {
    flows.get(input.flowId)?.();
    const listener = listenForSignInRedirect({ port: input.port });
    flows.set(input.flowId, listener.stop);

    // The page opens the way the shell's own sign-in does (#1213): a private
    // window of the default browser, so passkeys work and no signed-in
    // account gets in the way; the child window where there is none. Either
    // way the redirect comes to this machine, which is where we listen.
    const inBrowser =
      environment.platform === "darwin" &&
      (yield* Effect.promise(() => openInPrivateWindow(input.url)));
    if (!inBrowser) {
      yield* signInWindow.open({ flowId: input.flowId, url: input.url, label: input.label });
    }
    yield* logInfo("listening for the sign-in redirect", {
      flowId: input.flowId,
      port: input.port,
      inBrowser,
    });

    const outcome = yield* Effect.promise(() => listener.result);
    flows.delete(input.flowId);
    yield* signInWindow.close(input.flowId);
    if (!outcome.ok && outcome.error !== undefined) {
      yield* logWarning("the sign-in redirect could not end here", { flowId: input.flowId });
    } else {
      yield* logInfo("sign-in redirect ended", { flowId: input.flowId, ok: outcome.ok });
    }
    return outcome;
  });

  const stop: InfinitusSignInRedirectService["Service"]["stop"] = (flowId) =>
    Effect.gen(function* () {
      flows.get(flowId)?.();
      yield* signInWindow.close(flowId);
    });

  yield* Effect.addFinalizer(() =>
    Effect.sync(() => {
      for (const stopFlow of flows.values()) stopFlow();
    }),
  );

  return { listen, stop } satisfies InfinitusSignInRedirectService["Service"];
});

export const layer = Layer.effect(InfinitusSignInRedirectService, make);
