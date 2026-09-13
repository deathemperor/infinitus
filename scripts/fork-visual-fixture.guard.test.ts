// @effect-diagnostics nodeBuiltinImport:off -- A guard test reading the Mac app's own source files, not runtime code.
import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeNet from "node:net";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";
import * as NodeURL from "node:url";

import { describe, expect, it } from "vite-plus/test";

/**
 * `fork-visual-fixture.data.json` is an `infinitusctl` capture: it plays the
 * Mac the visual pass renders against. A capture drifts silently. A command
 * it still claims after the Mac dropped it hands every capability gate in the
 * web a `true` no real build gives — the pane renders in CI and is gone on the
 * user's Mac — and a pref key it still carries draws a settings row the same
 * way, which is how the session-era rows stayed on screen in CI until #1122.
 *
 * The same ordering rule holds as for `PREF_COPY` (#1041, stated in #1068):
 * the fixture loses a verb or a key in the PR that removes it from the Mac.
 *
 * One direction only for commands: the fixture answers just the read verbs the
 * pass exercises, so a command the Mac has and the fixture omits is normal.
 * A command the fixture claims and the Mac lacks is the lie.
 */

const read = (path: string) => NodeFS.readFileSync(new URL(path, import.meta.url), "utf8");

const FIXTURE = JSON.parse(read("./fork-visual-fixture.data.json")) as {
  readonly manifest: { readonly commands: ReadonlyArray<{ readonly name: string }> };
  readonly prefs: {
    readonly sections: ReadonlyArray<{ readonly slug: string; readonly name: string }>;
    readonly prefs: ReadonlyArray<{ readonly key: string }>;
  };
};

/** Every `ControlCommand(name: "<verb>", …)` the Mac's table declares. */
function macCommands(): ReadonlyArray<string> {
  const source = read("../apps/mac/Sources/InfinitusCore/ControlProtocol.swift");
  return [...source.matchAll(/ControlCommand\(name: "([a-z0-9-]+)"/g)].map(
    (match) => match[1] as string,
  );
}

/** Every `Entry("<key>", …)` the Mac's preference catalog declares. */
function macPrefKeys(): ReadonlyArray<string> {
  const source = read("../apps/mac/Sources/InfinitusCore/PrefCatalog.swift");
  return [...source.matchAll(/\bEntry\("([a-z0-9_]+)"/g)].map((match) => match[1] as string);
}

/** Its sections, as `{slug, name}` in the order the catalog lists them. */
function macPrefSections(): ReadonlyArray<{ readonly slug: string; readonly name: string }> {
  const source = read("../apps/mac/Sources/InfinitusCore/PrefCatalog.swift");
  return [...source.matchAll(/Section\(slug: "([a-z]+)", name: "([^"]+)"\)/g)].map((match) => ({
    slug: match[1] as string,
    name: match[2] as string,
  }));
}

/** The verbs `answer()` in the fixture server has a case for. */
function fixtureAnswered(): ReadonlyArray<string> {
  const source = read("./fork-visual-fixture.mjs");
  return [...source.matchAll(/^\s{4}case "([a-z0-9-]+)":/gm)].map((match) => match[1] as string);
}

const FIXTURE_SCRIPT = NodeURL.fileURLToPath(new URL("./fork-visual-fixture.mjs", import.meta.url));

interface ForecastWindow {
  readonly name: string;
  readonly pct: number;
  readonly ratePctPerHour: number | null;
  readonly resetsAt: number | null;
  readonly hitsAt: number | null;
}
interface ForecastReply {
  readonly ok: boolean;
  readonly result?: {
    readonly forecast: {
      readonly accounts: ReadonlyArray<{
        readonly alias: string;
        readonly windows: ReadonlyArray<ForecastWindow>;
      }>;
    };
  };
}

/** Starts the fixture on a throwaway socket and asks it one verb the way the
    server does: one JSON line out, one back. Reading the reply, rather than
    the source that builds it, is what makes the rule below a check of what
    the pass actually renders. */
async function fixtureReply(command: string): Promise<ForecastReply> {
  const socketPath = NodePath.join(NodeOS.tmpdir(), `inf-fixture-${process.pid}.sock`);
  const fixture = NodeChildProcess.spawn(
    process.execPath,
    [FIXTURE_SCRIPT, "--socket", socketPath],
    { stdio: ["ignore", "pipe", "ignore"] },
  );
  try {
    // It prints one line once the socket is up; waiting for that beats polling
    // the path, and a fixture that dies instead fails here with its exit code.
    await new Promise<void>((resolve, reject) => {
      fixture.stdout.setEncoding("utf8");
      fixture.stdout.on("data", (chunk: string) => {
        if (chunk.includes("listening")) resolve();
      });
      fixture.on("error", reject);
      fixture.on("exit", (code) => reject(new Error(`fixture exited with ${String(code)}`)));
    });
    const line = await new Promise<string>((resolve, reject) => {
      const socket = NodeNet.connect(socketPath);
      let buffer = "";
      socket.setEncoding("utf8");
      socket.on("connect", () =>
        socket.write(`${JSON.stringify({ command, args: [], options: {} })}\n`),
      );
      socket.on("data", (chunk: string) => {
        buffer += chunk;
      });
      socket.on("end", () => resolve(buffer));
      socket.on("error", reject);
    });
    return JSON.parse(line) as ForecastReply;
  } finally {
    // Its SIGTERM handler unlinks the socket.
    fixture.kill();
  }
}

describe("the visual-pass fixture's forecast", () => {
  /**
   * The Mac projects a window's `hitsAt` itself and drops it when the reset
   * lands first (`UsageForecast.project`: `if let reset = w.resetsAt, reset
   * <= at { hits = nil }`), which is what makes the web print "Resets before
   * it fills". The fixture used to hand the active account a 5h window that
   * fills three hours after it resets, so the visual pass photographed "Out
   * 10:34 PM · Resets 7:44 PM" — a line no real build can produce.
   */
  it("projects nothing a real Mac would not", async () => {
    const reply = await fixtureReply("forecast");
    expect(reply.ok).toBe(true);
    const accounts = reply.result?.forecast.accounts ?? [];
    expect(accounts.length).toBeGreaterThan(0);
    for (const account of accounts) {
      for (const window of account.windows) {
        if (window.hitsAt === null) continue;
        const where = `${account.alias} ${window.name}`;
        expect(window.resetsAt === null || window.hitsAt < window.resetsAt, where).toBe(true);
        // A hit needs a measured pace, or a window already full.
        expect((window.ratePctPerHour ?? 0) > 0 || window.pct >= 100, where).toBe(true);
      }
    }
    // And one window still fills, so the pass keeps rendering "binds first"
    // and "Out <time>" rather than only the resets-first branch.
    expect(
      accounts.some((account) => account.windows.some((window) => window.hitsAt !== null)),
    ).toBe(true);
  });
});

describe("the visual-pass fixture against the Mac's control protocol", () => {
  it("reads the Mac's sources", () => {
    // A rename or a move of either Swift file must fail here, not pass the
    // assertions below against an empty list.
    expect(macCommands().length).toBeGreaterThan(30);
    expect(macPrefKeys().length).toBeGreaterThan(30);
    expect(macPrefSections().length).toBeGreaterThan(3);
  });

  it("claims no command the Mac dropped", () => {
    const known = new Set(macCommands());
    const orphans = FIXTURE.manifest.commands
      .map((command) => command.name)
      .filter((name) => !known.has(name));
    expect(orphans).toEqual([]);
  });

  it("answers only commands it claims", () => {
    // A verb answered but unclaimed would keep working after the Mac drops it,
    // with nothing above to catch it.
    const claimed = new Set(FIXTURE.manifest.commands.map((command) => command.name));
    const unclaimed = fixtureAnswered().filter((verb) => !claimed.has(verb));
    expect(unclaimed).toEqual([]);
  });

  it("carries the catalog's preferences, no more and no less", () => {
    const fixtureKeys = FIXTURE.prefs.prefs.map((pref) => pref.key);
    const catalogKeys = macPrefKeys();
    expect(fixtureKeys.filter((key) => !catalogKeys.includes(key))).toEqual([]);
    expect(catalogKeys.filter((key) => !fixtureKeys.includes(key))).toEqual([]);
  });

  it("carries the catalog's sections, slug and name", () => {
    // The pages read the section by slug and print its name, so a retitle on
    // the Mac (#1069) lands here before a route goes blank in CI.
    expect([...FIXTURE.prefs.sections]).toEqual([...macPrefSections()]);
  });
});
