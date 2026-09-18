import { assert, describe, it } from "@effect/vitest";

import { resolveEarlyWebAuthnKeychainAccessGroup } from "./DesktopWebAuthn.ts";

describe("DesktopWebAuthn", () => {
  const joinPath = (...segments: ReadonlyArray<string>) => segments.join("/");

  it("reads the keychain access group the build signed into the packaged app", () => {
    const group = resolveEarlyWebAuthnKeychainAccessGroup({
      isPackaged: true,
      appPath: "/Applications/Infinitus.app/Contents/Resources/app.asar",
      joinPath,
      readFileString: (path) => {
        assert.equal(path, "/Applications/Infinitus.app/Contents/Resources/app.asar/package.json");
        return JSON.stringify({
          name: "infinitus-desktop",
          webauthnKeychainAccessGroup: "ABC1234567.run.infinitus.desktop.webauthn",
        });
      },
    });

    assert.equal(group, "ABC1234567.run.infinitus.desktop.webauthn");
  });

  it("configures nothing for an unpackaged run, without reading any file", () => {
    const group = resolveEarlyWebAuthnKeychainAccessGroup({
      isPackaged: false,
      appPath: "/repo/apps/desktop",
      joinPath,
      readFileString: () => {
        throw new Error("must not read");
      },
    });

    assert.isNull(group);
  });

  for (const [label, contents] of [
    ["an unsigned package without the field", JSON.stringify({ name: "infinitus-desktop" })],
    ["a blank field", JSON.stringify({ webauthnKeychainAccessGroup: "  " })],
    ["a non-string field", JSON.stringify({ webauthnKeychainAccessGroup: 7 })],
    ["unreadable metadata", "{not json"],
  ] as const) {
    it(`configures nothing for ${label}`, () => {
      const group = resolveEarlyWebAuthnKeychainAccessGroup({
        isPackaged: true,
        appPath: "/app",
        joinPath,
        readFileString: () => contents,
      });

      assert.isNull(group);
    });
  }
});
