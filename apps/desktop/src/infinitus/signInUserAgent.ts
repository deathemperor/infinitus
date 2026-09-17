/** The products a stock Chromium user agent names. Electron's default adds the
    app's own (`Infinitus/0.5.0`) and `Electron/44.1.0`, and Google's sign-in
    reads those as an embedded browser: it answers a request carrying them with
    `flowName=GeneralOAuthLite` and its legacy consent page, which cannot finish
    a federated login here. Everything kept is Chromium's own — which is what
    the page is really running. */
const CHROMIUM_USER_AGENT_PRODUCTS = new Set(["Mozilla", "AppleWebKit", "Chrome", "Safari"]);

/** The user agent a sign-in provider sees: the default with every non-Chromium
    product dropped. Tokens that name no product (the platform, `(KHTML,`,
    `like`, `Gecko)`) are part of the string's shape and stay. Its own file so
    the browser preview (`previewOAuthUserAgent.ts`) shares it without loading
    the sign-in window's service graph. */
export const signInUserAgent = (defaultUserAgent: string): string =>
  defaultUserAgent
    .split(" ")
    .filter((token) => {
      const slash = token.indexOf("/");
      return slash === -1 || CHROMIUM_USER_AGENT_PRODUCTS.has(token.slice(0, slash));
    })
    .join(" ");
