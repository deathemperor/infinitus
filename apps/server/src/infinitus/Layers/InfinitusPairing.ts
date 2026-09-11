import {
  AuthStandardClientScopes,
  EnvironmentAuthorizationError,
  type AuthEnvironmentScope,
} from "@t3tools/contracts";
import {
  PairingApprovalIssueFailed,
  PairingApprovalNotFound,
  PairingApprovalRefused,
  type PairingApprovalPollResult,
  type PairingApprovalRequest,
} from "@t3tools/contracts/infinitusPairing";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Duration from "effect/Duration";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";
import * as NodeCrypto from "node:crypto";

import * as EnvironmentAuth from "../../auth/EnvironmentAuth.ts";
import { InfinitusPairing, type InfinitusPairingShape } from "../Services/InfinitusPairing.ts";

/** How long a request waits for the desktop before the phone gives up. */
export const PAIRING_APPROVAL_TTL = Duration.minutes(2);
/** Undecided requests the server holds at once, overall and per remote
    address (behind a tunnel every phone shares one address, so there the
    per-address cap is the overall one). */
export const MAX_PENDING = 5;
export const MAX_PENDING_PER_ADDRESS = 2;

/** Four characters the user compares between the two screens. No 0/O, 1/I/L. */
const MATCH_CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
const MATCH_CODE_LENGTH = 4;
/** Bytes at or above this are redrawn so every letter is equally likely. */
const MATCH_CODE_REJECTION_LIMIT = 256 - (256 % MATCH_CODE_ALPHABET.length);

type Decision =
  | { readonly state: "pending" }
  | { readonly state: "denied" }
  | { readonly state: "approved"; readonly credential: string; readonly expiresAt: DateTime.Utc };

interface Entry extends PairingApprovalRequest {
  readonly secretHash: Buffer;
  readonly decision: Decision;
}

const hashSecret = (secret: string) =>
  NodeCrypto.createHash("sha256").update(secret, "utf8").digest();

/** The desktop's view of an entry: everything but the hash and the decision. */
const toRequest = ({ secretHash: _hash, decision: _decision, ...request }: Entry) => request;

const isLive = (entry: Entry, now: DateTime.Utc) =>
  DateTime.toEpochMillis(now) < DateTime.toEpochMillis(entry.expiresAt);
const isPending = (entry: Entry, now: DateTime.Utc) =>
  entry.decision.state === "pending" && isLive(entry, now);

const makeInfinitusPairing = Effect.gen(function* () {
  const crypto = yield* Crypto.Crypto;
  const auth = yield* EnvironmentAuth.EnvironmentAuth;
  // Expiry timers outlive the request that armed them, so they run in the
  // layer's scope.
  const scope = yield* Effect.scope;
  const entries = yield* SubscriptionRef.make<ReadonlyMap<string, Entry>>(new Map());

  const matchCode = Effect.gen(function* () {
    let code = "";
    while (code.length < MATCH_CODE_LENGTH) {
      const bytes = yield* crypto.randomBytes(MATCH_CODE_LENGTH * 2).pipe(Effect.orDie);
      for (const byte of bytes) {
        if (byte >= MATCH_CODE_REJECTION_LIMIT || code.length === MATCH_CODE_LENGTH) continue;
        code += MATCH_CODE_ALPHABET[byte % MATCH_CODE_ALPHABET.length];
      }
    }
    return code;
  });

  /** Drops expired entries; the phone polling one gets "not found", the
      desktop's list loses the row. */
  const sweep = Effect.gen(function* () {
    const now = yield* DateTime.now;
    yield* SubscriptionRef.update(entries, (current) => {
      const next = new Map([...current].filter(([, entry]) => isLive(entry, now)));
      return next.size === current.size ? current : next;
    });
  });

  const pendingList = (current: ReadonlyMap<string, Entry>, now: DateTime.Utc) =>
    [...current.values()].filter((entry) => isPending(entry, now)).map(toRequest);

  const live = (id: string) =>
    Effect.gen(function* () {
      const now = yield* DateTime.now;
      const entry = (yield* SubscriptionRef.get(entries)).get(id);
      return entry !== undefined && isLive(entry, now) ? entry : undefined;
    });

  const create: InfinitusPairingShape["create"] = (input) =>
    Effect.gen(function* () {
      yield* sweep;
      const now = yield* DateTime.now;
      const current = yield* SubscriptionRef.get(entries);
      const pending = [...current.values()].filter((entry) => isPending(entry, now));
      if (pending.length >= MAX_PENDING) {
        return yield* new PairingApprovalRefused({ reason: "too_many_pending" });
      }
      if (
        input.remoteAddress !== undefined &&
        pending.filter((entry) => entry.remoteAddress === input.remoteAddress).length >=
          MAX_PENDING_PER_ADDRESS
      ) {
        return yield* new PairingApprovalRefused({ reason: "too_many_from_address" });
      }
      const id = yield* crypto.randomUUIDv4.pipe(Effect.orDie);
      const entry: Entry = {
        id,
        deviceName: input.deviceName,
        ...(input.os !== undefined ? { os: input.os } : {}),
        ...(input.remoteAddress !== undefined ? { remoteAddress: input.remoteAddress } : {}),
        matchCode: yield* matchCode,
        createdAt: now,
        expiresAt: DateTime.addDuration(now, PAIRING_APPROVAL_TTL),
        secretHash: hashSecret(input.secret),
        decision: { state: "pending" },
      };
      yield* SubscriptionRef.update(entries, (map) => new Map(map).set(id, entry));
      // The row leaves the desktop's list on its own when nobody decides.
      yield* Effect.sleep(PAIRING_APPROVAL_TTL).pipe(Effect.andThen(sweep), Effect.forkIn(scope));
      return { id, matchCode: entry.matchCode, expiresAt: entry.expiresAt };
    });

  const poll: InfinitusPairingShape["poll"] = (input) =>
    Effect.gen(function* () {
      const entry = yield* live(input.id);
      const presented = hashSecret(input.secret);
      if (entry === undefined || !NodeCrypto.timingSafeEqual(entry.secretHash, presented)) {
        return yield* new PairingApprovalNotFound({});
      }
      return entry.decision satisfies PairingApprovalPollResult;
    });

  /** Records a decision on a request that is still pending and still live;
      an expired one the sweep has not reached yet counts as gone. */
  const setDecision = (id: string, decision: Decision) =>
    DateTime.now.pipe(
      Effect.flatMap((now) =>
        SubscriptionRef.modify(entries, (map) => {
          const entry = map.get(id);
          if (entry === undefined || !isPending(entry, now)) return [false, map] as const;
          return [true, new Map(map).set(id, { ...entry, decision })] as const;
        }),
      ),
    );

  const decide: InfinitusPairingShape["decide"] = (input) =>
    Effect.gen(function* () {
      const entry = yield* live(input.id);
      if (entry === undefined || entry.decision.state !== "pending") return { decided: false };
      if (!input.approve) return { decided: yield* setDecision(input.id, { state: "denied" }) };
      for (const scope of AuthStandardClientScopes) {
        if (!input.approverScopes.includes(scope as AuthEnvironmentScope)) {
          return yield* new EnvironmentAuthorizationError({
            message: `Approving a device delegates scope ${scope}, which the approving session lacks.`,
            requiredScope: scope,
          });
        }
      }
      const issued = yield* auth
        .issuePairingCredential({ label: entry.deviceName, scopes: AuthStandardClientScopes })
        .pipe(
          Effect.mapError((cause) => new PairingApprovalIssueFailed({ message: cause.message })),
        );
      const decided = yield* setDecision(input.id, {
        state: "approved",
        credential: issued.credential,
        expiresAt: issued.expiresAt,
      });
      // Someone else decided (or it expired) between the check and the mint:
      // the credential has no taker, so it does not stay valid.
      if (!decided) yield* auth.revokePairingLink(issued.id).pipe(Effect.ignore);
      return { decided };
    });

  const pending = SubscriptionRef.changes(entries).pipe(
    Stream.mapEffect((current) =>
      DateTime.now.pipe(Effect.map((now) => pendingList(current, now))),
    ),
  );

  return { create, poll, pending, decide } satisfies InfinitusPairingShape;
});

export const InfinitusPairingLive = Layer.effect(InfinitusPairing, makeInfinitusPairing);
