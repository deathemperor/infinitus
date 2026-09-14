// @effect-diagnostics nodeBuiltinImport:off - Reads the checked-in asset the script writes.
import * as NodeFS from "node:fs";
import { expect, it } from "vite-plus/test";

import { INSTALL_SCRIPT_ASSET, installScriptDocument } from "./sync-install-script.ts";

it("keeps the served copy in step with scripts/install.sh", () => {
  const asset = NodeFS.readFileSync(new URL(`../${INSTALL_SCRIPT_ASSET}`, import.meta.url), "utf8");
  expect(asset).toBe(installScriptDocument());
});

it("installs from this repository's releases, not upstream's (#1192)", () => {
  // The registration point an upstream sync would silently undo.
  const script = installScriptDocument();
  expect(script).toContain('repo="deathemperor/infinitus"');
  expect(script).not.toContain("pingdotgg");
  expect(script).toContain("$HOME/.infinitus");
});
