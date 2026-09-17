/**
 * The fork's product name, for the surfaces that identify the app (brand
 * mark, window title, first-run heading). Every user-facing string routes
 * through this constant so upstream-sync conflicts collapse to import
 * lines; see INFINITUS.md.
 */
export const PRODUCT_NAME = "Infinitus";

/**
 * The relay feature's name, "Infinitus Connect" (#1368: upstream's "T3
 * Connect"). Same rule as `PRODUCT_NAME`: every string a user reads routes
 * through it.
 */
export const CONNECT_NAME = `${PRODUCT_NAME} Connect`;

/**
 * Upstream attribution (#1426 follow-up). Infinitus is a fork of T3 Code and
 * ships its MIT-licensed source, so the licenses screen credits it in its own
 * section rather than leaving the notice buried among the npm packages. The
 * formal notice itself is the "T3 Code" entry in
 * `third-party-licenses.config.json`; this is the human-readable credit.
 */
export const UPSTREAM_PRODUCT_NAME = "T3 Code";
export const UPSTREAM_PUBLISHER_NAME = "T3 Tools, Inc.";
export const UPSTREAM_REPOSITORY_URL = "https://github.com/pingdotgg/t3code";
