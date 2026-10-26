#!/usr/bin/env node
// @effect-diagnostics nodeBuiltinImport:off - A plain CLI copying one file; no Effect runtime here.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeProcess from "node:process";
import * as NodeURL from "node:url";

/**
 * Where infinitus.run serves the Linux install script from: a static asset of the
 * site worker (`apps/mac/site`). The site has no build step and the source of truth
 * is `scripts/install.sh`, so the copy is checked in; the test beside this file and
 * `--check` fail when the two drift. The Windows script is not served.
 */
export const INSTALL_SCRIPT_SOURCE = "scripts/install.sh";
export const INSTALL_SCRIPT_ASSET = "apps/mac/site/public/install.sh";

const repoRoot = new URL("../", import.meta.url);

/** The script as it is served, byte for byte the checked-in source. */
export function installScriptDocument(): string {
  return NodeFS.readFileSync(new URL(INSTALL_SCRIPT_SOURCE, repoRoot), "utf8");
}

if (import.meta.main) {
  const target = new URL(INSTALL_SCRIPT_ASSET, repoRoot);
  const document = installScriptDocument();
  if (NodeProcess.argv.includes("--check")) {
    const current = NodeFS.existsSync(target) ? NodeFS.readFileSync(target, "utf8") : "";
    if (current !== document) {
      NodeProcess.stderr.write(
        `${INSTALL_SCRIPT_ASSET} is stale. Run: node scripts/sync-install-script.ts\n`,
      );
      NodeProcess.exit(1);
    }
  } else {
    NodeFS.mkdirSync(NodePath.dirname(NodeURL.fileURLToPath(target)), { recursive: true });
    NodeFS.writeFileSync(target, document);
  }
}
