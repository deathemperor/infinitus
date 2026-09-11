import type { PairingApprovalRequest } from "@t3tools/contracts/infinitusPairing";
import * as Cause from "effect/Cause";
import { AsyncResult } from "effect/unstable/reactivity";
import { describe, expect, it } from "vite-plus/test";

import { isAuthorizationFailure, pairingAccessOf } from "./pairingAccess.logic";

type Requests = ReadonlyArray<PairingApprovalRequest>;
const failed = (error: unknown) => AsyncResult.failure<Requests, unknown>(Cause.fail(error));

describe("pairingAccessOf", () => {
  it("is loading before the first answer and ok with the server's list", () => {
    expect(pairingAccessOf(AsyncResult.initial<Requests, unknown>(true))).toEqual({
      kind: "loading",
    });
    expect(pairingAccessOf(AsyncResult.success<Requests, unknown>([]))).toEqual({
      kind: "ok",
      requests: [],
    });
  });

  it("reads a missing scope as forbidden, whatever the message", () => {
    const refused = failed({
      _tag: "EnvironmentAuthorizationError",
      message: "The authenticated token is missing required scope: access:read.",
    });
    expect(pairingAccessOf(refused)).toEqual({ kind: "forbidden" });
  });

  it("keeps any other failure's words", () => {
    expect(pairingAccessOf(failed(new Error("socket closed")))).toEqual({
      kind: "failed",
      message: "socket closed",
    });
    expect(pairingAccessOf(failed({ _tag: "Other" }))).toEqual({
      kind: "failed",
      message: "the pairing requests could not be read.",
    });
  });
});

describe("isAuthorizationFailure", () => {
  it("matches the tag only", () => {
    expect(isAuthorizationFailure({ _tag: "EnvironmentAuthorizationError" })).toBe(true);
    expect(isAuthorizationFailure({ _tag: "PairingApprovalIssueFailed" })).toBe(false);
    expect(isAuthorizationFailure(null)).toBe(false);
    expect(isAuthorizationFailure("EnvironmentAuthorizationError")).toBe(false);
  });
});
