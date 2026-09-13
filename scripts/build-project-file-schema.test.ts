// @effect-diagnostics nodeBuiltinImport:off - Reads the checked-in asset the script writes.
import * as NodeFS from "node:fs";
import { expect, it } from "vite-plus/test";

import {
  PROJECT_FILE_SCHEMA_ASSET,
  projectFileSchemaDocument,
} from "./build-project-file-schema.ts";

it("serves the schema infinitus.json's $schema points at", () => {
  const document = JSON.parse(projectFileSchemaDocument()) as { $id: string };
  expect(document.$id).toBe("https://infinitus.run/schema/infinitus.json");
});

it("keeps the checked-in site asset in step with the contract", () => {
  const asset = NodeFS.readFileSync(
    new URL(`../${PROJECT_FILE_SCHEMA_ASSET}`, import.meta.url),
    "utf8",
  );
  expect(asset).toBe(projectFileSchemaDocument());
});
