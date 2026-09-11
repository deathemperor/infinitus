import {
  AuthAccessWriteScope,
  AuthAdministrativeScopes,
  AuthOrchestrationReadScope,
} from "@t3tools/contracts";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { it as effectIt } from "@effect/vitest";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Fiber from "effect/Fiber";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Ref from "effect/Ref";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { describe, expect } from "vite-plus/test";

import * as EnvironmentAuth from "../../auth/EnvironmentAuth.ts";
import { InfinitusPairing } from "../Services/InfinitusPairing.ts";
import {
  InfinitusPairingLive,
  MAX_PENDING,
  MAX_PENDING_PER_ADDRESS,
  PAIRING_APPROVAL_TTL,
} from "./InfinitusPairing.ts";

const SECRET = "phone-secret-0123456789abcdef";
const CREDENTIAL_EXPIRES_AT = DateTime.makeUnsafe("2026-09-11T12:00:00.000Z");

/** An auth service that mints a numbered credential and remembers revocations. */
const authLayer = (issued: Ref.Ref<Array<string>>, revoked: Ref.Ref<Array<string>>) =>
  Layer.mock(EnvironmentAuth.EnvironmentAuth)({
    issuePairingCredential: (input) =>
      Effect.gen(function* () {
        const all = yield* Ref.get(issued);
        const label = input?.label ?? "";
        yield* Ref.set(issued, [...all, label]);
        return {
          id: `link-${all.length + 1}`,
          credential: `credential-${all.length + 1}`,
          label,
          expiresAt: CREDENTIAL_EXPIRES_AT,
        };
      }),
    revokePairingLink: (id) => Ref.update(revoked, (all) => [...all, id]).pipe(Effect.as(true)),
  });

const withPairing = <A, E>(
  body: (input: {
    readonly pairing: InfinitusPairing["Service"];
    readonly issued: Ref.Ref<Array<string>>;
    readonly revoked: Ref.Ref<Array<string>>;
  }) => Effect.Effect<A, E>,
) =>
  Effect.gen(function* () {
    const issued = yield* Ref.make<Array<string>>([]);
    const revoked = yield* Ref.make<Array<string>>([]);
    return yield* Effect.gen(function* () {
      const pairing = yield* InfinitusPairing;
      return yield* body({ pairing, issued, revoked });
    }).pipe(
      Effect.provide(
        InfinitusPairingLive.pipe(
          Layer.provide(authLayer(issued, revoked)),
          Layer.provide(NodeServices.layer),
        ),
      ),
    );
  }).pipe(Effect.scoped);

/** The list a fresh subscriber sees first. */
const currentPending = (pairing: InfinitusPairing["Service"]) =>
  Stream.runHead(pairing.pending).pipe(Effect.map(Option.getOrElse(() => [])));

const ask = (pairing: InfinitusPairing["Service"], deviceName = "iPhone", remoteAddress?: string) =>
  pairing.create({
    deviceName,
    os: "ios",
    secret: SECRET,
    ...(remoteAddress !== undefined ? { remoteAddress } : {}),
  });

describe("InfinitusPairing", () => {
  effectIt.effect("a new request is pending for the phone and listed for the desktop", () =>
    withPairing(({ pairing }) =>
      Effect.gen(function* () {
        const created = yield* ask(pairing, "Loc's iPhone", "192.168.1.20");
        expect(created.matchCode).toMatch(/^[ABCDEFGHJKMNPQRSTUVWXYZ23456789]{4}$/);
        expect(DateTime.toEpochMillis(created.expiresAt)).toBe(
          Duration.toMillis(PAIRING_APPROVAL_TTL),
        );
        expect(yield* pairing.poll({ id: created.id, secret: SECRET })).toEqual({
          state: "pending",
        });
        const [listed] = yield* currentPending(pairing);
        expect(listed).toEqual({
          id: created.id,
          deviceName: "Loc's iPhone",
          os: "ios",
          remoteAddress: "192.168.1.20",
          matchCode: created.matchCode,
          createdAt: DateTime.makeUnsafe(0),
          expiresAt: created.expiresAt,
        });
        expect(Object.keys(listed!)).not.toContain("secretHash");
      }),
    ),
  );

  effectIt.effect("a poll with the wrong secret or an unknown id is not found", () =>
    withPairing(({ pairing }) =>
      Effect.gen(function* () {
        const created = yield* ask(pairing);
        const wrong = yield* pairing
          .poll({ id: created.id, secret: "someone-elses-secret-0123456789" })
          .pipe(Effect.flip);
        expect(wrong._tag).toBe("PairingApprovalNotFound");
        const unknown = yield* pairing.poll({ id: "nope", secret: SECRET }).pipe(Effect.flip);
        expect(unknown._tag).toBe("PairingApprovalNotFound");
      }),
    ),
  );

  effectIt.effect("approving mints a credential the phone collects until the request expires", () =>
    withPairing(({ pairing, issued }) =>
      Effect.gen(function* () {
        const created = yield* ask(pairing, "Loc's iPhone");
        const decided = yield* pairing.decide({
          id: created.id,
          approve: true,
          approverScopes: AuthAdministrativeScopes,
        });
        expect(decided).toEqual({ decided: true });
        expect(yield* Ref.get(issued)).toEqual(["Loc's iPhone"]);
        const approved = {
          state: "approved",
          credential: "credential-1",
          expiresAt: CREDENTIAL_EXPIRES_AT,
        };
        expect(yield* pairing.poll({ id: created.id, secret: SECRET })).toEqual(approved);
        // A dropped response is retried, not stranded: the grant store makes
        // the credential single-use, not this store.
        expect(yield* pairing.poll({ id: created.id, secret: SECRET })).toEqual(approved);
        // Decided requests leave the desktop's list and cannot be decided again.
        expect(yield* currentPending(pairing)).toEqual([]);
        expect(
          yield* pairing.decide({
            id: created.id,
            approve: false,
            approverScopes: AuthAdministrativeScopes,
          }),
        ).toEqual({ decided: false });
        expect(yield* Ref.get(issued)).toHaveLength(1);
      }),
    ),
  );

  effectIt.effect("denying tells the phone so and mints nothing", () =>
    withPairing(({ pairing, issued }) =>
      Effect.gen(function* () {
        const created = yield* ask(pairing);
        expect(
          yield* pairing.decide({
            id: created.id,
            approve: false,
            approverScopes: AuthAdministrativeScopes,
          }),
        ).toEqual({ decided: true });
        expect(yield* pairing.poll({ id: created.id, secret: SECRET })).toEqual({
          state: "denied",
        });
        expect(yield* Ref.get(issued)).toEqual([]);
      }),
    ),
  );

  effectIt.effect("an approver missing one of the delegated scopes cannot approve", () =>
    withPairing(({ pairing, issued }) =>
      Effect.gen(function* () {
        const created = yield* ask(pairing);
        const error = yield* pairing
          .decide({
            id: created.id,
            approve: true,
            approverScopes: [AuthOrchestrationReadScope, AuthAccessWriteScope],
          })
          .pipe(Effect.flip);
        expect(error._tag).toBe("EnvironmentAuthorizationError");
        expect(yield* Ref.get(issued)).toEqual([]);
        expect(yield* pairing.poll({ id: created.id, secret: SECRET })).toEqual({
          state: "pending",
        });
      }),
    ),
  );

  effectIt.effect("holds at most five undecided requests, two per address", () =>
    withPairing(({ pairing }) =>
      Effect.gen(function* () {
        yield* ask(pairing, "a", "10.0.0.1");
        yield* ask(pairing, "b", "10.0.0.1");
        const third = yield* ask(pairing, "c", "10.0.0.1").pipe(Effect.flip);
        expect(third).toMatchObject({
          _tag: "PairingApprovalRefused",
          reason: "too_many_from_address",
        });
        expect(MAX_PENDING_PER_ADDRESS).toBe(2);
        yield* ask(pairing, "d", "10.0.0.2");
        yield* ask(pairing, "e", "10.0.0.3");
        const fifth = yield* ask(pairing, "f", "10.0.0.4");
        const sixth = yield* ask(pairing, "g", "10.0.0.5").pipe(Effect.flip);
        expect(sixth).toMatchObject({ _tag: "PairingApprovalRefused", reason: "too_many_pending" });
        expect(MAX_PENDING).toBe(5);
        // A decided request no longer counts.
        yield* pairing.decide({ id: fifth.id, approve: false, approverScopes: [] });
        yield* ask(pairing, "h", "10.0.0.5");
      }),
    ),
  );

  effectIt.effect("an undecided request expires: the phone gets not found, the list empties", () =>
    withPairing(({ pairing }) =>
      Effect.gen(function* () {
        const created = yield* ask(pairing);
        const seen = yield* Ref.make<Array<number>>([]);
        const watcher = yield* pairing.pending.pipe(
          Stream.runForEach((list) => Ref.update(seen, (all) => [...all, list.length])),
          Effect.forkChild,
        );
        yield* Effect.yieldNow;
        yield* TestClock.adjust(Duration.subtract(PAIRING_APPROVAL_TTL, Duration.millis(1)));
        expect(yield* pairing.poll({ id: created.id, secret: SECRET })).toEqual({
          state: "pending",
        });
        yield* TestClock.adjust(Duration.millis(1));
        const gone = yield* pairing.poll({ id: created.id, secret: SECRET }).pipe(Effect.flip);
        expect(gone._tag).toBe("PairingApprovalNotFound");
        expect(
          yield* pairing.decide({ id: created.id, approve: true, approverScopes: [] }),
        ).toEqual({ decided: false });
        // One row, then none — without anyone asking.
        expect(yield* Ref.get(seen)).toEqual([1, 0]);
        yield* Fiber.interrupt(watcher);
      }),
    ),
  );
});
