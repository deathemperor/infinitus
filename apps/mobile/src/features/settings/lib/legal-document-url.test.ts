import { describe, expect, it } from "vite-plus/test";

import { isLegalDocumentUrl } from "./legal-document-url";

describe("isLegalDocumentUrl", () => {
  it.each([
    "https://infinitus.run/legal",
    "https://infinitus.run/legal/",
    "https://infinitus.run/privacy-policy?source=app",
    "https://infinitus.run/terms-of-service#updates",
    "https://infinitus.run/security-policy",
  ])("allows a configured legal document: %s", (url) => {
    expect(isLegalDocumentUrl(url)).toBe(true);
  });

  it.each([
    // Upstream's documents bind T3 Tools, Inc. and describe services the fork
    // does not run; the Legal screen must never navigate back to them.
    "https://t3.codes/legal",
    "https://t3.codes/privacy-policy",
    "https://t3.codes/terms-of-service",
    "https://infinitus.run/download",
    "https://example.com/legal",
    "javascript:alert(1)",
    "not-a-url",
  ])("rejects a URL outside the legal-document allowlist: %s", (url) => {
    expect(isLegalDocumentUrl(url)).toBe(false);
  });
});
