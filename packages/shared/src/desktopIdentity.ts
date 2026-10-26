/**
 * The fork's desktop identity: URL scheme and Electron `userData` directory. Both
 * must differ from the installed T3 Code's: a shared scheme lets the fork swallow
 * the real app's OAuth deep links, and a shared `userData` lets it block or corrupt
 * the app's single-instance lock, cookies and electron-store.
 */

/** The renderer's own origin scheme — `<scheme>://app`. */
export const DESKTOP_URL_SCHEME = "infinitus";
export const DESKTOP_DEV_URL_SCHEME = "infinitus-dev";

/**
 * `<appData>/<name>`: the Electron `userData` directory. Not `infinitus`: the
 * native Infinitus app keeps its Application Support in `Infinitus/`, and on
 * the case-insensitive APFS a Mac ships with that is the same directory (the
 * .3 prerelease wrote Cookies, Preferences and caches into it, #600).
 */
export const DESKTOP_USER_DATA_DIR_NAME = "infinitus-desktop";
export const DESKTOP_DEV_USER_DATA_DIR_NAME = "infinitus-desktop-dev";

/**
 * Legacy `userData` directories a build adopts when it finds one. Upstream
 * adopts its own pre-rename directory that way; the fork has never shipped
 * under another name, so the list is empty and the rule never fires. Never add
 * `T3 Code (Alpha)` or `T3 Code (Dev)` — those belong to the installed app.
 */
const ADOPTED_LEGACY_USER_DATA_DIR_NAMES: readonly string[] = [];

export function adoptsLegacyDesktopUserDataDir(legacyDirName: string): boolean {
  return ADOPTED_LEGACY_USER_DATA_DIR_NAMES.includes(legacyDirName);
}
