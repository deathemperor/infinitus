import { AsyncResult } from "effect/unstable/reactivity";
import { describe, expect, it } from "vite-plus/test";

import { pinAtCreationEnabled } from "./pinAtCreation.logic";

describe("pinAtCreationEnabled", () => {
  it("is on only for a loaded preference set to true", () => {
    expect(pinAtCreationEnabled(AsyncResult.success({ infinitusPinAtCreation: true }))).toBe(true);
    expect(pinAtCreationEnabled(AsyncResult.success({ infinitusPinAtCreation: false }))).toBe(
      false,
    );
    expect(pinAtCreationEnabled(AsyncResult.success({}))).toBe(false);
    expect(pinAtCreationEnabled(AsyncResult.initial())).toBe(false);
  });
});
