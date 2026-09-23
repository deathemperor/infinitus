import * as NodeServices from "@effect/platform-node/NodeServices";
import { it as effectIt } from "@effect/vitest";
import { HostProcessPlatform } from "@infinitus/shared/hostProcess";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as Sink from "effect/Sink";
import * as Stream from "effect/Stream";
import * as TestClock from "effect/testing/TestClock";
import { HttpClient, HttpClientResponse } from "effect/unstable/http";
import { ChildProcessSpawner } from "effect/unstable/process";
import { describe, expect, it } from "vite-plus/test";

import {
  claudeKeychainService,
  claudeResetCreditsToContract,
  consumeClaudeResetCredit,
  readClaudeResetCredits,
} from "./claudeResetCredits.ts";

const NOW = Date.parse("2026-09-22T12:00:00.000Z");
const grant = (overrides: Record<string, unknown>) => ({
  id: "grant_a",
  resets_left: 1,
  usable_now: true,
  ...overrides,
});
const encoder = new TextEncoder();

const writeLogin = Effect.gen(function* () {
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const directory = yield* fs.makeTempDirectoryScoped();
  yield* fs.writeFileString(
    path.join(directory, ".credentials.json"),
    '{"claudeAiOauth":{"accessToken":"oauth-token","expiresAt":4102444800000}}',
  );
  return { configDir: directory, keychainService: "Claude Code-credentials" };
});

const respond = (status: number, body: unknown) =>
  HttpClient.make((request) =>
    Effect.succeed(HttpClientResponse.fromWeb(request, Response.json(body, { status }))),
  );
const refuseRequests = HttpClient.make(() => Effect.die("must not send a request"));

/** A `security` that answers every `find-generic-password` with `payload`. */
const keychainLayer = (payload: string, code = 0) =>
  Layer.succeed(
    ChildProcessSpawner.ChildProcessSpawner,
    ChildProcessSpawner.make((command) => {
      const { command: name, args } = command as unknown as {
        command: string;
        args: ReadonlyArray<string>;
      };
      expect(name).toBe("security");
      expect(args).toEqual(["find-generic-password", "-s", "Claude Code-credentials", "-w"]);
      return Effect.succeed(
        ChildProcessSpawner.makeHandle({
          pid: ChildProcessSpawner.ProcessId(1),
          exitCode: Effect.succeed(ChildProcessSpawner.ExitCode(code)),
          isRunning: Effect.succeed(false),
          kill: () => Effect.void,
          unref: Effect.succeed(Effect.void),
          stdin: Sink.drain,
          stdout: Stream.make(encoder.encode(payload)),
          stderr: Stream.empty,
          all: Stream.empty,
          getInputFd: () => Sink.drain,
          getOutputFd: () => Stream.empty,
        }),
      );
    }),
  );
const noSpawns = Layer.succeed(
  ChildProcessSpawner.ChildProcessSpawner,
  ChildProcessSpawner.make(() => Effect.die("must not spawn")),
);

const USAGE_BODY = {
  cedar_ember: { eligible: true, next_grant_id: "grant_a", grants: [grant({})] },
};

describe("claudeKeychainService", () => {
  it("suffixes the item with the config directory's hash only when one is set", () => {
    expect(claudeKeychainService(undefined)).toBe("Claude Code-credentials");
    expect(claudeKeychainService("/Users/me/.claude-work")).toMatch(
      /^Claude Code-credentials-[0-9a-f]{8}$/,
    );
    expect(claudeKeychainService("/a")).not.toBe(claudeKeychainService("/b"));
  });
});

describe("claudeResetCreditsToContract", () => {
  it("counts live grants, pins the next one and names the offer", () => {
    expect(
      claudeResetCreditsToContract(
        {
          eligible: true,
          next_grant_id: "grant_a",
          grants: [
            grant({ resets_left: 2, label: "Opus 5.5 launch", ends_at: "2026-10-01T00:00:00Z" }),
            grant({ id: "paused", paused: true }),
            grant({ id: "expired", ends_at: "2026-09-01T00:00:00Z" }),
            grant({ id: "garbled", ends_at: "not a date" }),
            grant({ id: "Not Valid" }),
            grant({ id: "grant_b", resets_left: 3, usable_now: false }),
          ],
        },
        NOW,
      ),
    ).toEqual({
      availableCount: 6,
      nextCreditId: "grant_a",
      nextExpiresAt: "2026-10-01T00:00:00.000Z",
      label: "Opus 5.5 launch",
    });
  });

  it("holds the next grant with the reason it cannot be used yet", () => {
    const status = (extra: Record<string, unknown>, grantExtra: Record<string, unknown>) =>
      claudeResetCreditsToContract(
        { eligible: true, next_grant_id: "grant_a", grants: [grant(grantExtra)], ...extra },
        NOW,
      );
    expect(status({ at_limit: false }, { usable_now: false, use_requires_limit: true })).toEqual({
      availableCount: 1,
      nextCreditId: "grant_a",
      nextHold: { reason: "notAtLimit" },
    });
    expect(status({ at_limit: true }, { usable_now: false, use_requires_limit: true })).toEqual({
      availableCount: 1,
      nextCreditId: "grant_a",
      nextHold: { reason: "blocked" },
    });
    expect(status({ cooldown_until: "2026-09-22T12:30:00Z" }, {})).toEqual({
      availableCount: 1,
      nextCreditId: "grant_a",
      nextHold: { reason: "cooldown", until: "2026-09-22T12:30:00.000Z" },
    });
    // A cooldown already over is no hold.
    expect(status({ cooldown_until: "2026-09-22T11:30:00Z" }, {})).toEqual({
      availableCount: 1,
      nextCreditId: "grant_a",
    });
  });

  it("offers nothing when the account is ineligible or the block is missing", () => {
    expect(
      claudeResetCreditsToContract({ eligible: false, grants: [grant({})] }, NOW),
    ).toBeUndefined();
    expect(claudeResetCreditsToContract(undefined, NOW)).toBeUndefined();
    expect(claudeResetCreditsToContract(null, NOW)).toBeUndefined();
    expect(claudeResetCreditsToContract({ eligible: true, grants: [] }, NOW)).toEqual({
      availableCount: 0,
    });
  });
});

effectIt.layer(NodeServices.layer)("readClaudeResetCredits", (it) => {
  it.effect("reads the grants with the CLI's request from the file login", () =>
    Effect.gen(function* () {
      const login = yield* writeLogin;
      const client = HttpClient.make((request) => {
        expect(request.method).toBe("GET");
        expect(request.url).toBe(
          "https://api.anthropic.com/api/oauth/usage?cedar_ember=1&skip_spend=1",
        );
        expect(request.headers.authorization).toBe("Bearer oauth-token");
        expect(request.headers["anthropic-beta"]).toBe("oauth-2025-04-20");
        expect(request.headers["user-agent"]).toBe("claude-cli/2.1.280 (external, cli)");
        return Effect.succeed(HttpClientResponse.fromWeb(request, Response.json(USAGE_BODY)));
      });
      const credits = yield* readClaudeResetCredits(login, "2.1.280").pipe(
        Effect.provideService(HostProcessPlatform, "linux"),
        Effect.provideService(HttpClient.HttpClient, client),
        Effect.provide(noSpawns),
      );
      expect(credits).toEqual({ availableCount: 1, nextCreditId: "grant_a" });
    }),
  );

  it.effect("reads the macOS login from the keychain item, never the file", () =>
    Effect.gen(function* () {
      const login = { configDir: "/nowhere", keychainService: "Claude Code-credentials" };
      const credits = yield* readClaudeResetCredits(login, "2.1.280").pipe(
        Effect.provideService(HostProcessPlatform, "darwin"),
        Effect.provideService(HttpClient.HttpClient, respond(200, USAGE_BODY)),
        Effect.provide(keychainLayer('{"claudeAiOauth":{"accessToken":"oauth-token"}}\n')),
      );
      expect(credits).toEqual({ availableCount: 1, nextCreditId: "grant_a" });
    }),
  );

  it.effect("reads nothing without a usable login or from a failed request", () =>
    Effect.gen(function* () {
      // The test clock starts at the epoch; the lapsed token below expired after it.
      yield* TestClock.setTime(NOW);
      const login = yield* writeLogin;
      const missingItem = yield* readClaudeResetCredits(login, "2.1.280").pipe(
        Effect.provideService(HostProcessPlatform, "darwin"),
        Effect.provideService(HttpClient.HttpClient, refuseRequests),
        Effect.provide(keychainLayer("", 44)),
      );
      const lapsed = yield* Effect.gen(function* () {
        const fs = yield* FileSystem.FileSystem;
        const path = yield* Path.Path;
        yield* fs.writeFileString(
          path.join(login.configDir, ".credentials.json"),
          '{"claudeAiOauth":{"accessToken":"stale","expiresAt":1}}',
        );
        return yield* readClaudeResetCredits(login, "2.1.280");
      }).pipe(
        Effect.provideService(HostProcessPlatform, "linux"),
        Effect.provideService(HttpClient.HttpClient, refuseRequests),
        Effect.provide(noSpawns),
      );
      const limited = yield* readClaudeResetCredits(
        { ...login, configDir: "/nowhere" },
        "2.1.280",
      ).pipe(
        Effect.provideService(HostProcessPlatform, "linux"),
        Effect.provideService(HttpClient.HttpClient, respond(429, {})),
        Effect.provide(noSpawns),
      );
      expect([missingItem, lapsed, limited]).toEqual([undefined, undefined, undefined]);
    }),
  );
});

const ClaimBody = Schema.fromJsonString(
  Schema.Struct({ program: Schema.String, grant_id: Schema.String, request_id: Schema.String }),
);
const decodeClaimBody = Schema.decodeEffect(ClaimBody);
const PROFILE = { account: { uuid: "acct-1" }, organization: { uuid: "org-1" } };

/** Answers the profile read, then hands the claim to `claim`. */
const claimClient = (
  claim: (request: Parameters<typeof HttpClientResponse.fromWeb>[0]) => Response,
) =>
  HttpClient.make((request) =>
    Effect.succeed(
      HttpClientResponse.fromWeb(
        request,
        request.url.endsWith("/api/oauth/profile") ? Response.json(PROFILE) : claim(request),
      ),
    ),
  );

const consume = (client: HttpClient.HttpClient, ids = { grantId: "grant_a", requestId: "r-1" }) =>
  Effect.gen(function* () {
    const login = yield* writeLogin;
    return yield* consumeClaudeResetCredit({ login, version: "2.1.280", ...ids }).pipe(
      Effect.provideService(HostProcessPlatform, "linux"),
      Effect.provideService(HttpClient.HttpClient, client),
      Effect.provide(noSpawns),
      Effect.result,
    );
  });

effectIt.layer(NodeServices.layer)("consumeClaudeResetCredit", (it) => {
  it.effect("claims the grant against the token's own organization", () =>
    Effect.gen(function* () {
      let claimed = "";
      const client = claimClient((request) => {
        expect(request.method).toBe("POST");
        expect(request.url).toBe(
          "https://api.anthropic.com/api/organizations/org-1/reset_rate_limits",
        );
        expect(request.headers.authorization).toBe("Bearer oauth-token");
        expect(request.headers["user-agent"]).toBe("claude-cli/2.1.280 (external, cli)");
        claimed =
          request.body._tag === "Uint8Array" ? new TextDecoder().decode(request.body.body) : "";
        return Response.json({ result: "reset", resets_left: 0 });
      });
      expect(yield* consume(client)).toMatchObject({ _tag: "Success", success: "reset" });
      expect(yield* decodeClaimBody(claimed)).toEqual({
        program: "cedar_ember",
        grant_id: "grant_a",
        request_id: "r-1",
      });
    }),
  );

  it.effect("maps each answer to an outcome or a failure", () =>
    Effect.gen(function* () {
      for (const [result, outcome] of [
        ["not_limited", "nothingToReset"],
        ["already_used", "alreadyRedeemed"],
        ["ineligible", "noCredit"],
        ["unavailable", "noCredit"],
      ] as const) {
        expect(yield* consume(claimClient(() => Response.json({ result })))).toMatchObject({
          success: outcome,
        });
      }
      for (const [response, reason] of [
        [Response.json({ result: "cooldown" }), "coolingDown"],
        [Response.json({}, { status: 429 }), "rateLimited"],
        [Response.json({}, { status: 401 }), "signedOut"],
        [Response.json({ result: "something-new" }), "requestFailed"],
      ] as const) {
        expect(yield* consume(claimClient(() => response))).toMatchObject({
          _tag: "Failure",
          failure: { reason },
        });
      }
    }),
  );

  it.effect("refuses without a login or an organization, and malformed ids before sending", () =>
    Effect.gen(function* () {
      for (const ids of [
        { grantId: "Bad Grant", requestId: "r-1" },
        { grantId: "grant_a", requestId: "has space" },
      ]) {
        expect(yield* consume(refuseRequests, ids)).toMatchObject({
          _tag: "Failure",
          failure: { reason: "malformedCredit" },
        });
      }
      const noOrganization = HttpClient.make((request) =>
        Effect.succeed(
          HttpClientResponse.fromWeb(request, Response.json({ account: { uuid: "acct-1" } })),
        ),
      );
      expect(yield* consume(noOrganization)).toMatchObject({
        _tag: "Failure",
        failure: { reason: "signedOut" },
      });
    }),
  );
});
