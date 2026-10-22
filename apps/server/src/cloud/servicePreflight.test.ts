import { expect, it } from "@effect/vitest";

import { runServicePreflight } from "./servicePreflight.ts";
<<<<<<< HEAD
import { PRODUCT_NAME } from "@infinitus/shared/productName";

import { SERVICE_LAUNCHER_PROTOCOL } from "./serviceProtocol.ts";
=======
>>>>>>> upstream-sync-3b95e7831-upstream-renamed

it.each([1, 2])("blocks legacy launcher protocol %i", (launcherProtocol) => {
  expect(
    runServicePreflight({
      databasePath: "/missing/state.sqlite",
      launcherProtocol,
      version: "1.2.3",
    }),
  ).toEqual({
    status: "blocked",
    version: "1.2.3",
    reason: `This release requires a newer ${PRODUCT_NAME} service launcher. Update it on the server machine.`,
  });
});
