/**
 * Deep links (#270 D): `<scheme>://thread/<environmentId>/<threadId>` routes
 * to a thread, `<scheme>://new?project=<id|title|folder>&prompt=<text>` opens
 * the composer on that project with the prompt prefilled, never sent. The
 * scheme is the renderer's own (`infinitus` / `infinitus-dev`), so the `app`
 * host stays the renderer origin and the Clerk bridge's OAuth callback; only
 * the `thread` and `new` hosts are claimed here.
 *
 * Two halves: an intake attached before Electron is ready (macOS delivers a
 * cold launch's `open-url` before `ready`, Windows and Linux put the URL in
 * argv and in `second-instance`), and the service that parses what the intake
 * caught, keeps the latest link, and pings the renderer. The renderer pulls
 * the link over IPC once its environment is connected, so a link that lands
 * during startup is never lost to a page that has not mounted yet.
 */
import type { DesktopDeepLink } from "@t3tools/contracts";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Ref from "effect/Ref";

import * as DesktopEnvironment from "../app/DesktopEnvironment.ts";
import { makeComponentLogger } from "../app/DesktopObservability.ts";
import * as ElectronProtocol from "../electron/ElectronProtocol.ts";
import * as ElectronWindow from "../electron/ElectronWindow.ts";
import { INFINITUS_DEEP_LINK_PENDING_CHANNEL } from "../ipc/channels.ts";
import * as DesktopWindow from "../window/DesktopWindow.ts";

/** A prompt longer than this is cut; the composer is not a file drop. */
export const MAX_DEEP_LINK_PROMPT_LENGTH = 20_000;

function decodeSegment(segment: string): string | null {
  try {
    const decoded = decodeURIComponent(segment).trim();
    return decoded.length > 0 ? decoded : null;
  } catch {
    return null;
  }
}

/** The link a URL names, or null when it is not one this shell handles. */
export function parseDesktopDeepLink(url: string, scheme: string): DesktopDeepLink | null {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return null;
  }
  if (parsed.protocol !== `${scheme}:`) return null;
  // `<scheme>://thread/...` puts "thread" in host; `<scheme>:thread/...` in
  // path. Only the former is a link the OS hands over, so only it counts.
  if (parsed.host === "thread") {
    const segments = parsed.pathname.split("/").filter((segment) => segment.length > 0);
    if (segments.length !== 2) return null;
    const environmentId = decodeSegment(segments[0] ?? "");
    const threadId = decodeSegment(segments[1] ?? "");
    if (environmentId === null || threadId === null) return null;
    return { kind: "thread", environmentId, threadId };
  }
  if (parsed.host === "new") {
    if (parsed.pathname !== "" && parsed.pathname !== "/") return null;
    const project = parsed.searchParams.get("project")?.trim() ?? "";
    if (project.length === 0) return null;
    const prompt = (parsed.searchParams.get("prompt") ?? "").slice(0, MAX_DEEP_LINK_PROMPT_LENGTH);
    return { kind: "new", project, prompt };
  }
  return null;
}

/** The last argv entry that is a link of ours: Windows and Linux launch the
    handler with the URL as an argument (`%U` in the desktop entry). */
export function findDeepLinkArgument(argv: ReadonlyArray<string>, scheme: string): string | null {
  for (let index = argv.length - 1; index >= 0; index -= 1) {
    const candidate = argv[index];
    if (candidate !== undefined && parseDesktopDeepLink(candidate, scheme) !== null) {
      return candidate;
    }
  }
  return null;
}

export type DeepLinkIntakeEvent = { readonly preventDefault: () => void };

/** The two `Electron.app.on` overloads the intake uses. */
export type DeepLinkIntakeApp = {
  readonly on: {
    (event: "open-url", listener: (event: DeepLinkIntakeEvent, url: string) => void): unknown;
    (
      event: "second-instance",
      listener: (event: DeepLinkIntakeEvent, argv: string[]) => void,
    ): unknown;
  };
};

export type DeepLinkIntake = {
  /** Registers the listeners; the URLs they catch wait until `drain`. */
  readonly attach: (app: DeepLinkIntakeApp, argv: ReadonlyArray<string>, scheme: string) => void;
  /** Hands the waiting URL (if any) and every later one to `listener`; null detaches. */
  readonly drain: (listener: ((url: string) => void) | null) => void;
};

export function makeDeepLinkIntake(): DeepLinkIntake {
  let pending: string | null = null;
  let listener: ((url: string) => void) | null = null;
  const offer = (url: string) => {
    if (listener === null) {
      pending = url;
      return;
    }
    listener(url);
  };
  return {
    attach: (app, argv, scheme) => {
      app.on("open-url", (event, url) => {
        if (parseDesktopDeepLink(url, scheme) === null) return;
        event.preventDefault();
        offer(url);
      });
      app.on("second-instance", (_event, instanceArgv) => {
        const url = findDeepLinkArgument(instanceArgv, scheme);
        if (url !== null) offer(url);
      });
      const initial = findDeepLinkArgument(argv, scheme);
      if (initial !== null) offer(initial);
    },
    drain: (next) => {
      listener = next;
      if (next === null || pending === null) return;
      const url = pending;
      pending = null;
      next(url);
    },
  };
}

/** The process's one intake: attached by the pre-ready platform setup, drained by the service. */
export const deepLinkIntake = makeDeepLinkIntake();

export class InfinitusDeepLinksService extends Context.Service<
  InfinitusDeepLinksService,
  {
    /** The latest link, cleared on read. */
    readonly consume: Effect.Effect<DesktopDeepLink | null>;
  }
>()("@t3tools/desktop/infinitus/InfinitusDeepLinks/InfinitusDeepLinksService") {}

const { logInfo } = makeComponentLogger("infinitus-deep-links");

const make = Effect.gen(function* () {
  const environment = yield* DesktopEnvironment.DesktopEnvironment;
  const desktopWindow = yield* DesktopWindow.DesktopWindow;
  const electronWindow = yield* ElectronWindow.ElectronWindow;
  const context = yield* Effect.context<never>();
  const runPromise = Effect.runPromiseWith(context);
  const scheme = ElectronProtocol.getDesktopScheme(environment.isDevelopment);
  const pending = yield* Ref.make<DesktopDeepLink | null>(null);

  // The prompt never reaches a log or a span, only its length (#433's rule).
  const receive = Effect.fn("infinitus.deepLinks.receive")(function* (link: DesktopDeepLink) {
    yield* Effect.annotateCurrentSpan({ kind: link.kind });
    yield* Ref.set(pending, link);
    yield* logInfo("link", {
      kind: link.kind,
      ...(link.kind === "new" ? { promptLength: link.prompt.length } : {}),
    });
    // The same gate as macOS's "activate without windows": a window opens
    // only once the backend is up; before that, startup opens it and the
    // renderer pulls on mount.
    yield* desktopWindow.createMainIfBackendReady;
    const open = yield* electronWindow.main;
    if (Option.isNone(open) || open.value.isDestroyed()) return;
    yield* electronWindow.reveal(open.value);
    // A page still loading pulls on mount; a loaded one is pinged.
    if (open.value.webContents.isLoadingMainFrame()) return;
    open.value.webContents.send(INFINITUS_DEEP_LINK_PENDING_CHANNEL);
  });

  deepLinkIntake.drain((url) => {
    const link = parseDesktopDeepLink(url, scheme);
    if (link !== null) void runPromise(receive(link).pipe(Effect.ignoreCause));
  });
  yield* Effect.addFinalizer(() => Effect.sync(() => deepLinkIntake.drain(null)));

  return InfinitusDeepLinksService.of({
    consume: Ref.getAndSet(pending, null),
  });
});

export const layer = Layer.effect(InfinitusDeepLinksService, make);
