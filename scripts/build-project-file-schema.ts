#!/usr/bin/env node
// @effect-diagnostics nodeBuiltinImport:off - A plain CLI writing one file; no Effect runtime here.
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeProcess from "node:process";
import * as NodeURL from "node:url";

import { buildT3ProjectFileJsonSchema } from "@t3tools/shared/t3ProjectFile";

/**
 * Where infinitus.run serves the project file's JSON Schema from: a static
 * asset of the site worker (`apps/mac/site`), which every `infinitus.json`
 * points at with `$schema` (`T3_PROJECT_FILE_SCHEMA_URL`). The site has no
 * build step, so the document is generated here and checked in; the test
 * beside this file fails when the two drift, and `--check` does the same in
 * a shell.
 */
export const PROJECT_FILE_SCHEMA_ASSET = "apps/mac/site/public/schema/infinitus.json";

/** The document as it is written to disk, newline-terminated. */
export function projectFileSchemaDocument(): string {
  return `${JSON.stringify(buildT3ProjectFileJsonSchema(), null, 2)}\n`;
}

if (import.meta.main) {
  const target = new URL(`../${PROJECT_FILE_SCHEMA_ASSET}`, import.meta.url);
  const document = projectFileSchemaDocument();
  if (NodeProcess.argv.includes("--check")) {
    const current = NodeFS.existsSync(target) ? NodeFS.readFileSync(target, "utf8") : "";
    if (current !== document) {
      NodeProcess.stderr.write(
        `${PROJECT_FILE_SCHEMA_ASSET} is stale. Run: node scripts/build-project-file-schema.ts\n`,
      );
      NodeProcess.exit(1);
    }
  } else {
    NodeFS.mkdirSync(NodePath.dirname(NodeURL.fileURLToPath(target)), { recursive: true });
    NodeFS.writeFileSync(target, document);
  }
}
