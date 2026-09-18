/**
 * The pure half of the shell's own OAuth sign-in (#1213): where the engine's
 * binary lives, and what its two `add-oauth --json` lines mean.
 *
 * The engine is swapd, and this is the one place in the desktop tree that
 * knows its name. `add-oauth` makes swapd the OAuth client — it holds the PKCE
 * verifier and its own loopback listener catches the redirect — so the shell
 * only opens a URL and reads an envelope. The menu-bar app is not in the flow,
 * which is the whole point: this app can add an account on its own.
 */

/** Where `swapd` lives, checked in order; first hit wins. The list mirrors the
    Mac app's `SwapdLocator`, so both find the same binary on one machine. */
export interface SwapdBinaryInput {
  readonly env: Record<string, string | undefined>;
  readonly homeDirectory: string;
  /** The packaged macOS bundle (`…/Infinitus.app`), when there is one: the
      menu-bar helper nested in it (#777) ships swapd beside its executable. */
  readonly desktopBundlePath: string | null;
  readonly exists: (path: string) => boolean;
}

/** The helper's own copy, the one a DMG install always has. */
const NESTED_SWAPD_RELATIVE_PATH =
  "Contents/Library/LoginItems/Infinitus Menu Bar.app/Contents/MacOS/swapd";

const swapdBinaryCandidates = (
  input: Pick<SwapdBinaryInput, "homeDirectory" | "desktopBundlePath">,
): ReadonlyArray<string> => [
  "/opt/homebrew/bin/swapd",
  "/usr/local/bin/swapd",
  `${input.homeDirectory}/.cargo/bin/swapd`,
  `${input.homeDirectory}/.local/bin/swapd`,
  ...(input.desktopBundlePath === null
    ? []
    : [`${input.desktopBundlePath}/${NESTED_SWAPD_RELATIVE_PATH}`]),
];

/**
 * `null` when the engine is not on this machine. `INFINITUS_SWAPD_CLI` pins
 * one for a dev run and, set empty, simulates a machine without it — the
 * override is the whole answer, never the head of the list.
 */
export const resolveSwapdBinary = (input: SwapdBinaryInput): string | null => {
  const forced = input.env.INFINITUS_SWAPD_CLI;
  if (forced !== undefined) {
    return forced.length === 0 || !input.exists(forced) ? null : forced;
  }
  return swapdBinaryCandidates(input).find((path) => input.exists(path)) ?? null;
};

/** The command-line switch a browser takes for a private window, by bundle
    identifier — the Mac app's `SignInSheetRoute.privateFlags`, the Chromium
    family's only (Safari has none). `null` leaves the page to the profile. */
const PRIVATE_WINDOW_FLAGS: Readonly<Record<string, string>> = {
  "com.google.Chrome": "--incognito",
  "com.google.Chrome.beta": "--incognito",
  "com.google.Chrome.canary": "--incognito",
  "com.google.Chrome.dev": "--incognito",
  "org.chromium.Chromium": "--incognito",
  "com.brave.Browser": "--incognito",
  "com.vivaldi.Vivaldi": "--incognito",
  "company.thebrowser.Browser": "--incognito",
  "com.microsoft.edgemac": "--inprivate",
  "com.microsoft.edgemac.Beta": "--inprivate",
  "com.microsoft.edgemac.Dev": "--inprivate",
  "com.microsoft.edgemac.Canary": "--inprivate",
};

export const privateWindowFlag = (bundleId: string): string | null =>
  PRIVATE_WINDOW_FLAGS[bundleId] ?? null;

/** One line of `add-oauth --json`: the URL to open, the account it stored, or
    the engine's refusal. An unreadable line is `null` — swapd writes nothing
    else on stdout, so it is noise, not a failure. */
export type SwapdAddOauthLine =
  | { readonly kind: "url"; readonly url: string }
  | { readonly kind: "added"; readonly slot: number; readonly email: string }
  | { readonly kind: "error"; readonly message: string };

const readString = (value: unknown): string | null =>
  typeof value === "string" && value.length > 0 ? value : null;

export const parseAddOauthLine = (line: string): SwapdAddOauthLine | null => {
  const trimmed = line.trim();
  if (trimmed.length === 0) return null;
  let parsed: unknown;
  try {
    parsed = JSON.parse(trimmed);
  } catch {
    return null;
  }
  if (typeof parsed !== "object" || parsed === null) return null;
  const record = parsed as Record<string, unknown>;
  const error = record.error;
  if (typeof error === "object" && error !== null) {
    const body = error as Record<string, unknown>;
    const message = readString(body.message) ?? readString(body.code);
    return message === null ? null : { kind: "error", message };
  }
  const url = readString(record.url);
  if (url !== null) return { kind: "url", url };
  const email = readString(record.email);
  if (email !== null && typeof record.slot === "number") {
    return { kind: "added", slot: record.slot, email };
  }
  return null;
};
