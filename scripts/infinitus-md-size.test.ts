// @effect-diagnostics nodeBuiltinImport:off - Reads the checked-in file this test guards.
import * as NodeFS from "node:fs";
import { expect, it } from "vite-plus/test";

// INFINITUS.md is loaded whole into every session through CLAUDE.md's
// `@INFINITUS.md`. It grew to 155 KB before #1339 moved the feature
// narratives out; this keeps it from growing back. A feature adds one
// ledger line in docs/internals/fork-registration-points.md or
// fork-only-files.md and a docs/internals/<feature>.md page, never a
// paragraph here.
const INFINITUS_MD_BYTE_CAP = 16 * 1024;

it("keeps INFINITUS.md under the byte cap (#1339)", () => {
  const bytes = NodeFS.statSync(new URL("../INFINITUS.md", import.meta.url)).size;
  expect(
    bytes,
    `INFINITUS.md is ${bytes} bytes, over the ${INFINITUS_MD_BYTE_CAP}-byte cap. Every session loads it whole: put the narrative in a docs/internals/<feature>.md page and one ledger line in docs/internals/fork-registration-points.md or docs/internals/fork-only-files.md (#1339).`,
  ).toBeLessThanOrEqual(INFINITUS_MD_BYTE_CAP);
});
