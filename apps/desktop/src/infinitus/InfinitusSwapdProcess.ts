// @effect-diagnostics nodeBuiltinImport:off -- This platform boundary runs the account engine's CLI with Node.

import * as NodeChildProcess from "node:child_process";
import * as NodeFS from "node:fs";
import * as NodeOS from "node:os";
import * as NodePath from "node:path";

import type { InfinitusOAuthSignInResult } from "@infinitus/contracts/infinitus";
import * as Electron from "electron";

import { parseAddOauthLine, privateWindowFlag } from "./infinitusSwapd.logic.ts";

/** The engine locator's existence test, the Mac app's `isExecutableFile`. */
export function isExecutableFile(path: string): boolean {
  try {
    NodeFS.accessSync(path, NodeFS.constants.X_OK);
    return NodeFS.statSync(path).isFile();
  } catch {
    return false;
  }
}

/** A directory's entries, empty when it is missing — the engine locator's way
    of walking nvm's per-version bins without caring whether nvm is installed. */
export function listDirectoryNames(path: string): ReadonlyArray<string> {
  try {
    return NodeFS.readdirSync(path);
  } catch {
    return [];
  }
}

/** Any file, executable or not: a launch agent plist says a service manager
    already owns an engine. */
export function fileExists(path: string): boolean {
  try {
    return NodeFS.statSync(path).isFile();
  } catch {
    return false;
  }
}

const run = (file: string, args: ReadonlyArray<string>): Promise<string | null> =>
  new Promise((resolve) => {
    NodeChildProcess.execFile(file, [...args], (error, stdout) => {
      resolve(error === null ? stdout.trim() : null);
    });
  });

/** The default browser for `url` and its private-window switch, or null when
    there is no default browser or it has no such switch (Safari). Asked before
    a sign-in starts, since where the page will show decides who runs it. */
export async function privateWindowBrowser(
  url: string,
): Promise<{ readonly path: string; readonly flag: string } | null> {
  if (!/^https?:\/\//i.test(url)) return null;
  const browser = await Electron.app.getApplicationInfoForProtocol(url).catch(() => null);
  if (browser === null) return null;
  const bundleId = await run("/usr/bin/plutil", [
    "-extract",
    "CFBundleIdentifier",
    "raw",
    `${browser.path}/Contents/Info.plist`,
  ]);
  const flag = bundleId === null ? null : privateWindowFlag(bundleId);
  return flag === null ? null : { path: browser.path, flag };
}

/**
 * The sign-in page in a private window of a browser instance of its own, on
 * an empty profile, so the browser's signed-in account never meets the one
 * being added. `false` when there is no such window to open — no default
 * browser, one with no private switch — and the caller opens the URL the
 * plain way.
 *
 * `open -na <browser> --args <flag> --user-data-dir=<fresh> <url>`: a running
 * browser gets a URL over Apple Events and ignores launch arguments, and a
 * second instance handing `--incognito` to the running one was seen to open
 * the page in the signed-in profile (user 2026-09-21, Chrome 153). A
 * different `--user-data-dir` is what makes the Chromium family start a
 * separate process instead of handing off, and the profile is wiped before
 * every launch, so the page opens signed in to nothing (the Mac app's
 * `openInDefaultBrowser`). macOS only: the caller asks.
 */
export async function openInPrivateWindow(url: string): Promise<boolean> {
  const browser = await privateWindowBrowser(url);
  if (browser === null) return false;
  const profile = NodePath.join(NodeOS.tmpdir(), "infinitus-signin-profile");
  NodeFS.rmSync(profile, { recursive: true, force: true });
  return (
    (await run("/usr/bin/open", [
      "-na",
      browser.path,
      "--args",
      browser.flag,
      `--user-data-dir=${profile}`,
      "--no-first-run",
      "--no-default-browser-check",
      url,
    ])) !== null
  );
}

/**
 * One `swapd --json --provider <p> add-oauth` run (#1213). The verb prints two
 * lines: the URL to open, flushed the moment its loopback listener is up, then
 * the `add` envelope once the sign-in has been redeemed and stored. `onUrl`
 * takes the first, the promise settles on the second; cancelling is killing
 * the process, which takes its listener with it.
 */

/** swapd's own default is five minutes; the shell asks for no more. */
const TIMEOUT_SECONDS = 300;
/** Enough of stderr to word a failure the engine did not word itself. */
const MAX_STDERR_CHARS = 2_000;

export interface SwapdAddOAuthRun {
  readonly result: Promise<InfinitusOAuthSignInResult>;
  /** Kills the child; the result settles as a plain refusal, no message. */
  readonly stop: () => void;
}

export function startSwapdAddOAuth(input: {
  readonly binary: string;
  readonly provider: string;
  readonly onUrl: (url: string) => void;
}): SwapdAddOAuthRun {
  const child = NodeChildProcess.spawn(
    input.binary,
    ["--json", "--provider", input.provider, "add-oauth", "--timeout", String(TIMEOUT_SECONDS)],
    { stdio: ["ignore", "pipe", "pipe"] },
  );

  let settle: ((result: InfinitusOAuthSignInResult) => void) | null = null;
  const result = new Promise<InfinitusOAuthSignInResult>((resolve) => {
    settle = resolve;
  });

  let stopped = false;
  let buffered = "";
  let stderr = "";

  const finish = (value: InfinitusOAuthSignInResult) => {
    if (settle === null) return;
    const resolve = settle;
    settle = null;
    resolve(value);
  };

  const stop = () => {
    if (stopped) return;
    stopped = true;
    child.kill();
    finish({ ok: false });
  };

  const take = (line: string) => {
    const parsed = parseAddOauthLine(line);
    if (parsed === null) return;
    if (parsed.kind === "url") {
      if (!stopped) input.onUrl(parsed.url);
      return;
    }
    if (parsed.kind === "added") {
      finish({ ok: true, slot: parsed.slot, email: parsed.email });
      return;
    }
    finish({ ok: false, error: parsed.message });
  };

  child.stdout.on("data", (chunk: Buffer) => {
    buffered += chunk.toString();
    const lines = buffered.split("\n");
    buffered = lines.pop() ?? "";
    for (const line of lines) take(line);
  });

  child.stderr.on("data", (chunk: Buffer) => {
    if (stderr.length < MAX_STDERR_CHARS) stderr += chunk.toString();
  });

  child.once("error", (error) => {
    finish({ ok: false, error: error.message });
  });

  // `close`, not `exit`: the engine prints its envelope and exits at once, and
  // `exit` can win the race against stdout's last chunk — which would refuse a
  // sign-in whose account the engine had already stored. `close` waits for the
  // pipes, so by here every line has been read; the remainder is whatever had
  // no newline after it.
  child.once("close", (code) => {
    if (stopped) return;
    if (buffered.length > 0) {
      const trailing = buffered;
      buffered = "";
      take(trailing);
    }
    const said = stderr.trim();
    finish({
      ok: false,
      error: said.length > 0 ? said : `The account engine exited with code ${code}.`,
    });
  });

  return { result, stop };
}
