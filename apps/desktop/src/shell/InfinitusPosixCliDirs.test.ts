import { assert, describe, it } from "@effect/vitest";
import * as Option from "effect/Option";

import { knownPosixCliDirCandidates, resolvePosixCliDirFallback } from "./InfinitusPosixCliDirs.ts";

const HOME = "/Users/me";

const fakeFs = (existing: ReadonlyArray<string>) => {
  const paths = new Set(existing);
  return {
    exists: (path: string) => paths.has(path),
    listDirectory: (path: string) =>
      [...paths]
        .filter((entry) => entry.startsWith(`${path}/`))
        .map((entry) => entry.slice(path.length + 1).split("/")[0] ?? "")
        .filter((entry, index, all) => entry.length > 0 && all.indexOf(entry) === index),
  };
};

describe("resolvePosixCliDirFallback (#1078)", () => {
  it("lists the known dirs in precedence order, nvm newest first", () => {
    const fs = fakeFs([
      `${HOME}/.nvm/versions/node/v22.4.0/bin`,
      `${HOME}/.nvm/versions/node/v25.2.1/bin`,
      `${HOME}/.nvm/versions/node/v24.10.0/bin`,
    ]);
    assert.deepEqual(knownPosixCliDirCandidates(HOME, fs.listDirectory), [
      `${HOME}/.claude/local`,
      `${HOME}/.local/bin`,
      "/opt/homebrew/bin",
      "/usr/local/bin",
      `${HOME}/.nvm/versions/node/v25.2.1/bin`,
      `${HOME}/.nvm/versions/node/v24.10.0/bin`,
      `${HOME}/.nvm/versions/node/v22.4.0/bin`,
      `${HOME}/.volta/bin`,
      `${HOME}/.bun/bin`,
    ]);
    assert.deepEqual(knownPosixCliDirCandidates(undefined, fs.listDirectory), [
      "/opt/homebrew/bin",
      "/usr/local/bin",
    ]);
  });

  it("stays out when the shell's PATH already reaches claude", () => {
    const fs = fakeFs([`${HOME}/.local/bin/claude`, "/opt/homebrew/bin"]);
    assert.isNull(
      resolvePosixCliDirFallback({
        homeDirectory: HOME,
        shellPath: Option.some(`${HOME}/.local/bin:/usr/bin`),
        ...fs,
      }),
    );
  });

  it("answers the existing dirs and the one holding claude when the probe gave no PATH", () => {
    const fs = fakeFs([
      `${HOME}/.local/bin`,
      `${HOME}/.local/bin/claude`,
      "/opt/homebrew/bin",
      `${HOME}/.bun/bin`,
    ]);
    assert.deepEqual(
      resolvePosixCliDirFallback({ homeDirectory: HOME, shellPath: Option.none(), ...fs }),
      {
        reason: "no-shell-path",
        dirs: [`${HOME}/.local/bin`, "/opt/homebrew/bin", `${HOME}/.bun/bin`],
        claudeDir: `${HOME}/.local/bin`,
      },
    );
  });

  it("answers the existing dirs when the probe's PATH has no claude, claudeDir null without one", () => {
    const fs = fakeFs(["/usr/local/bin", "/opt/homebrew/bin"]);
    assert.deepEqual(
      resolvePosixCliDirFallback({
        homeDirectory: HOME,
        shellPath: Option.some("/opt/homebrew/bin:/usr/bin"),
        ...fs,
      }),
      {
        reason: "no-claude-on-shell-path",
        dirs: ["/opt/homebrew/bin", "/usr/local/bin"],
        claudeDir: null,
      },
    );
  });
});
