import { describe, expect, it, vi } from "vite-plus/test";

import { installPreviewOAuthUserAgent, withSignInUserAgent } from "./previewOAuthUserAgent.ts";

const NATIVE =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Infinitus/0.5.0-alpha.22 Chrome/142.0.0.0 Electron/44.1.0 Safari/537.36";
const CHROME =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36";

describe("withSignInUserAgent", () => {
  it("replaces the app's user agent with Chromium's own and keeps every other header", () => {
    expect(
      withSignInUserAgent(
        { Accept: "text/html", Referer: "https://a.test/", "User-Agent": NATIVE },
        NATIVE,
      ),
    ).toEqual({ Accept: "text/html", Referer: "https://a.test/", "User-Agent": CHROME });
  });

  it("never sends two user agents, however the original header was cased", () => {
    const headers = withSignInUserAgent({ "user-agent": NATIVE }, NATIVE);
    expect(headers).toEqual({ "User-Agent": CHROME });
  });
});

describe("installPreviewOAuthUserAgent", () => {
  const install = () => {
    const onBeforeSendHeaders = vi.fn();
    installPreviewOAuthUserAgent({
      getUserAgent: () => NATIVE,
      webRequest: { onBeforeSendHeaders },
    } as never);
    return { onBeforeSendHeaders };
  };

  it("answers a matched request with the Chromium-only user agent", () => {
    const { onBeforeSendHeaders } = install();
    const listener = onBeforeSendHeaders.mock.calls[0]![1] as (
      details: { requestHeaders: Record<string, string> },
      callback: (response: { requestHeaders: Record<string, string> }) => void,
    ) => void;
    const callback = vi.fn();
    listener({ requestHeaders: { "User-Agent": NATIVE, Referer: "https://a.test/" } }, callback);
    expect(callback).toHaveBeenCalledWith({
      requestHeaders: { Referer: "https://a.test/", "User-Agent": CHROME },
    });
  });
});
