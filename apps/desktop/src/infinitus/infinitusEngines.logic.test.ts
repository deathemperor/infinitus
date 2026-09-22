import { assert, describe, it } from "@effect/vitest";

import {
  ENGINE_DEFINITIONS,
  type EngineDefinition,
  engineBackoffSeconds,
  engineBinaryDirs,
  detectEngine,
  engineBackoffAttemptFor,
  parseCommandLine,
  resolveEngine,
} from "./infinitusEngines.logic.ts";

const HOME = "/Users/me";
const NINE_ROUTER = ENGINE_DEFINITIONS.find((entry) => entry.key === "9router")!;
const CLIPROXY = ENGINE_DEFINITIONS.find((entry) => entry.key === "cliproxy")!;

const input = (options: {
  executables?: ReadonlyArray<string>;
  files?: ReadonlyArray<string>;
  nvmVersions?: ReadonlyArray<string>;
  homeDirectory?: string | undefined;
}) => ({
  homeDirectory: "homeDirectory" in options ? options.homeDirectory : HOME,
  isExecutable: (path: string) => (options.executables ?? []).includes(path),
  fileExists: (path: string) => (options.files ?? []).includes(path),
  listDirectory: () => options.nvmVersions ?? [],
});

const detect = (definition: EngineDefinition, options: Parameters<typeof input>[0]) =>
  detectEngine(definition, input(options));

describe("engine detection", () => {
  it("walks nvm's per-version bins newest first", () => {
    const dirs = engineBinaryDirs({
      homeDirectory: HOME,
      listDirectory: () => ["v20.1.0", "v25.2.1", "v22.9.0"],
    });
    const nvm = dirs.filter((dir) => dir.includes(".nvm"));
    assert.deepStrictEqual(nvm, [
      `${HOME}/.nvm/versions/node/v25.2.1/bin`,
      `${HOME}/.nvm/versions/node/v22.9.0/bin`,
      `${HOME}/.nvm/versions/node/v20.1.0/bin`,
    ]);
  });

  it("finds an engine on an nvm path and runs it in the foreground", () => {
    const binary = `${HOME}/.nvm/versions/node/v25.2.1/bin/9router`;
    const found = detect(NINE_ROUTER, { executables: [binary], nvmVersions: ["v25.2.1"] });
    assert.strictEqual(found.mode, "child");
    // Never `-t`: tray mode backgrounds itself, which reads to the supervisor
    // as a process that exited the instant it started.
    assert.strictEqual(found.command, `${binary} -t -n -H 127.0.0.1`);
  });

  it("leaves an engine Homebrew already supervises to launchd", () => {
    const found = detect(CLIPROXY, {
      files: [`${HOME}/Library/LaunchAgents/homebrew.mxcl.cliproxyapi.plist`],
      executables: ["/opt/homebrew/bin/brew", "/opt/homebrew/bin/cliproxyapi"],
    });
    assert.strictEqual(found.mode, "service");
    assert.strictEqual(found.command, "/opt/homebrew/bin/brew services start cliproxyapi");
  });

  it("takes the binary once the service is gone, so stopping it in brew hands it over", () => {
    const found = detect(CLIPROXY, { executables: ["/opt/homebrew/bin/cliproxyapi"] });
    assert.strictEqual(found.mode, "child");
    assert.strictEqual(found.command, "/opt/homebrew/bin/cliproxyapi");
  });

  it("answers unknown when the engine is not on this machine", () => {
    assert.deepStrictEqual(detect(NINE_ROUTER, {}), { mode: "unknown", command: null });
  });

  it("quotes a path with a space so the field round-trips", () => {
    // A home directory with a space in it is the realistic way this happens.
    const home = "/Users/Ada Lovelace";
    const binary = `${home}/.local/bin/9router`;
    const found = detect(NINE_ROUTER, { homeDirectory: home, executables: [binary] });
    assert.strictEqual(found.command, `"${binary}" -t -n -H 127.0.0.1`);
    const parsed = parseCommandLine(found.command!);
    assert.deepStrictEqual(parsed, { ok: true, binary, args: ["-t", "-n", "-H", "127.0.0.1"] });
  });
});

describe("engine resolution", () => {
  it("keeps detection's mode when nothing was typed", () => {
    const resolved = resolveEngine(
      CLIPROXY,
      input({ files: [`${HOME}/Library/LaunchAgents/homebrew.mxcl.cliproxyapi.plist`] }),
      null,
    );
    assert.strictEqual(resolved.mode, "service");
  });

  it("makes a typed command ours to run, which is how a takeover is expressed", () => {
    const resolved = resolveEngine(
      CLIPROXY,
      input({ files: [`${HOME}/Library/LaunchAgents/homebrew.mxcl.cliproxyapi.plist`] }),
      "/usr/local/bin/cliproxyapi --config /etc/cliproxy.yaml",
    );
    assert.strictEqual(resolved.mode, "child");
    assert.strictEqual(resolved.command, "/usr/local/bin/cliproxyapi --config /etc/cliproxy.yaml");
    // What detection would have done is still shown, so the field can say what
    // it is overriding.
    assert.strictEqual(resolved.detectedCommand, "brew services start cliproxyapi");
  });

  it("falls back to detection when the typed command is blanked", () => {
    const binary = "/opt/homebrew/bin/9router";
    const resolved = resolveEngine(NINE_ROUTER, input({ executables: [binary] }), "   ");
    assert.strictEqual(resolved.command, `${binary} -t -n -H 127.0.0.1`);
  });
});

describe("command parsing", () => {
  it("splits a plain command", () => {
    assert.deepStrictEqual(parseCommandLine("/usr/bin/thing -a  -b c"), {
      ok: true,
      binary: "/usr/bin/thing",
      args: ["-a", "-b", "c"],
    });
  });

  it("refuses a bare program name, which has no PATH to be found on", () => {
    const parsed = parseCommandLine("9router -n");
    assert.strictEqual(parsed.ok, false);
    assert.include(parsed.ok ? "" : parsed.error, "full path");
  });

  it("refuses an empty command and an unclosed quote", () => {
    assert.strictEqual(parseCommandLine("   ").ok, false);
    assert.strictEqual(parseCommandLine('/bin/x "unclosed').ok, false);
  });

  it("keeps quoted arguments whole", () => {
    assert.deepStrictEqual(parseCommandLine(`/bin/x --name 'two words' --flag`), {
      ok: true,
      binary: "/bin/x",
      args: ["--name", "two words", "--flag"],
    });
  });
});

describe("backoff", () => {
  it("doubles to a one-minute cap", () => {
    assert.deepStrictEqual(
      [0, 1, 2, 3, 4, 5, 6, 7].map(engineBackoffSeconds),
      [1, 2, 4, 8, 16, 32, 60, 60],
    );
  });

  it("charges this death the current attempt, and starts over after a run that lasted", () => {
    assert.strictEqual(engineBackoffAttemptFor(4, 1), 4);
    assert.strictEqual(engineBackoffAttemptFor(4, 300), 0);
  });
});
