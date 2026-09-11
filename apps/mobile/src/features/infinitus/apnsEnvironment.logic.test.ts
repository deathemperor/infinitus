import { describe, expect, it } from "vite-plus/test";

import { apnsEnvironmentFromProfile } from "./apnsEnvironment.logic";

const profile = (env: string) =>
  `garbage<plist version="1.0"><dict><key>Entitlements</key><dict>` +
  `<key>application-identifier</key><string>Q783W6B4FA.run.infinitus.mobile</string>` +
  `<key>aps-environment</key>\n    <string>${env}</string></dict></dict></plist>more`;

describe("apnsEnvironmentFromProfile", () => {
  it("reads development as sandbox and production as production", () => {
    expect(apnsEnvironmentFromProfile(profile("development"))).toBe("sandbox");
    expect(apnsEnvironmentFromProfile(profile("production"))).toBe("production");
  });

  it("is production without a profile or without the entitlement", () => {
    expect(apnsEnvironmentFromProfile(null)).toBe("production");
    expect(apnsEnvironmentFromProfile("<plist><dict></dict></plist>")).toBe("production");
  });
});
