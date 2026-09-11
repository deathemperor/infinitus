// @effect-diagnostics nodeBuiltinImport:off - A plain CLI over files the harness wrote; no Effect runtime here.
/**
 * The visual pass's verdict: applies `fork-visual-routes.ts` to the
 * `text-<route>.txt` captures `fork-visual-pass.mjs` wrote and exits 1 on the
 * first route that misses its marker or shows an empty state.
 *
 *   node scripts/fork-visual-check.ts --out <dir>   check the captures in <dir>
 *   node scripts/fork-visual-check.ts --routes      print the routes, space-separated,
 *                                                   for the harness's argument list
 */
import * as NodeFS from "node:fs";
import * as NodePath from "node:path";
import * as NodeProcess from "node:process";

import { FORK_VISUAL_ROUTES, checkVisualPass } from "./fork-visual-routes.ts";

const argv = NodeProcess.argv.slice(2);
if (argv[0] === "--routes") {
  NodeProcess.stdout.write(`${FORK_VISUAL_ROUTES.map((route) => route.route).join(" ")}\n`);
} else if (argv[0] === "--out" && argv[1] !== undefined) {
  const out = argv[1];
  const results = checkVisualPass((name) => {
    const file = NodePath.join(out, `text-${name}.txt`);
    return NodeFS.existsSync(file) ? NodeFS.readFileSync(file, "utf8") : null;
  });
  let failed = 0;
  for (const { route, failures } of results) {
    if (failures.length === 0) {
      NodeProcess.stdout.write(`ok    ${route.label} (${route.route})\n`);
    } else {
      failed++;
      NodeProcess.stdout.write(`FAIL  ${route.label} (${route.route}): ${failures.join("; ")}\n`);
    }
  }
  NodeProcess.stdout.write(`${results.length - failed}/${results.length} routes rendered\n`);
  if (failed > 0) NodeProcess.exit(1);
} else {
  NodeProcess.stderr.write("usage: fork-visual-check.ts --out <dir> | --routes\n");
  NodeProcess.exit(2);
}
