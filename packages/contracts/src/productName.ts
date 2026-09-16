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
