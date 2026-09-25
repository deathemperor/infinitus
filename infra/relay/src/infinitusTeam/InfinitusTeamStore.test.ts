import { describe, expect, it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import * as RelayDb from "../db.ts";
import * as InfinitusTeamStore from "./InfinitusTeamStore.ts";
import { infinitusTeamMembers, infinitusTeams } from "./schema.ts";

describe("InfinitusTeamStore", () => {
  it.effect("names the failed query and keeps its cause", () => {
    const cause = new Error("database unavailable");
    const fakeDb = {
      select: () => ({
        from: (table: unknown) => {
          expect(table).toBe(infinitusTeams);
          return { where: () => ({ limit: () => Effect.fail(cause) }) };
        },
      }),
    } as unknown as RelayDb.RelayDb["Service"];
    return Effect.gen(function* () {
      const store = yield* InfinitusTeamStore.InfinitusTeamStore;
      const error = yield* Effect.flip(store.getTeam("team-1"));
      expect(error).toMatchObject({ _tag: "InfinitusTeamPersistenceError", op: "get_team" });
      expect(error.cause).toBe(cause);
    }).pipe(Effect.provide(InfinitusTeamStore.layer.pipe(Layer.provide(Layer.succeed(RelayDb.RelayDb, fakeDb)))));
  });

  it.effect("reads a member's shares off the jsonb column", () => {
    const fakeDb = {
      select: () => ({
        from: (table: unknown) => {
          expect(table).toBe(infinitusTeamMembers);
          return {
            where: () => ({
              limit: () =>
                Effect.succeed([
                  {
                    teamId: "team-1",
                    userId: "user-1",
                    role: "leader",
                    name: "Loc",
                    sharesJson: { now: "team", fleet: "off", threads: "off", stats: "off", transcripts: "off" },
                    since: "2026-09-25T00:00:00.000Z",
                    updatedAt: "2026-09-25T00:00:00.000Z",
                  },
                ]),
            }),
          };
        },
      }),
    } as unknown as RelayDb.RelayDb["Service"];
    return Effect.gen(function* () {
      const store = yield* InfinitusTeamStore.InfinitusTeamStore;
      const member = yield* store.getMember("team-1", "user-1");
      expect(member?.shares.now).toBe("team");
      expect(member?.role).toBe("leader");
    }).pipe(Effect.provide(InfinitusTeamStore.layer.pipe(Layer.provide(Layer.succeed(RelayDb.RelayDb, fakeDb)))));
  });
});
