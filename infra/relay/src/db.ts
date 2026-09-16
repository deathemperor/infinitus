import type { PgClient } from "@effect/sql-pg/PgClient";
import * as Cloudflare from "alchemy/Cloudflare";
import * as Drizzle from "alchemy/Drizzle";
import * as Neon from "alchemy/Neon";
import * as Alchemy from "alchemy";
import * as RemovalPolicy from "alchemy/RemovalPolicy";
import type { EffectPgDatabase } from "drizzle-orm/effect-postgres";
import * as Config from "effect/Config";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";

import { relayDatabaseMode } from "./dbConfig.ts";

export class RelayDb extends Context.Service<
  RelayDb,
  EffectPgDatabase & {
    readonly $client: PgClient;
  }
>()("infinitus-relay/db/RelayDb") {}

export class RelayTransactions extends Context.Service<
  RelayTransactions,
  {
    readonly withTransaction: RelayDb["Service"]["$client"]["withTransaction"];
  }
>()("infinitus-relay/db/RelayTransactions") {
  static readonly layer = Layer.effect(
    RelayTransactions,
    Effect.gen(function* () {
      const db = yield* RelayDb;
      return RelayTransactions.of({
        withTransaction: db.$client.withTransaction,
      });
    }),
  );
}

// Infinitus (#1322): the relay's Postgres is a Neon project, not upstream's
// PlanetScale database (whose cheapest cluster needs a card on file). The
// shape is upstream's — `prod` owns the retained project, every other stage
// branches off it — with Neon's own owner role in place of a runtime role.
export const NeonDatabase = Effect.gen(function* () {
  const { stage } = yield* Alchemy.Stack;
  const schema = yield* Drizzle.Schema("RelaySchema", {
    schema: "./src/persistence/schema.ts",
    out: "./migrations/postgres",
    dialect: "postgres",
  });

  const mode = relayDatabaseMode(stage);
  const migrations = { dir: schema.out, table: "relay_migrations" };
  // Through Config like the zone names: the deploy script's `.env` provider
  // never reaches `process.env`, and `orgId` cannot be changed after creation.
  const orgId = yield* Config.nonEmptyString("NEON_ORG_ID").pipe(Config.option);
  const project =
    mode === "shared-database"
      ? yield* Neon.Project("RelayNeonProject", {
          name: "infinitus-relay",
          region: "aws-ap-southeast-1",
          ...(Option.isSome(orgId) ? { orgId: orgId.value } : {}),
          migrations,
        }).pipe(RemovalPolicy.retain())
      : yield* Neon.Project.ref("RelayNeonProject", { stage: "prod" });
  const branch =
    mode === "stage-branch"
      ? yield* Neon.Branch("RelayNeonBranch", { project, migrations })
      : undefined;

  return { branch, project };
});

export const RelayHyperdrive = Effect.gen(function* () {
  const { branch, project } = yield* NeonDatabase;
  return yield* Cloudflare.Hyperdrive.Connection("RelayHyperdrive", {
    // The direct endpoint: Hyperdrive is the pooler, so Neon's pgbouncer
    // stays out of the path (Cloudflare's Neon guide says the same).
    origin: (branch ?? project).origin,
    caching: {
      disabled: true,
    },
    originConnectionLimit: 20,
  });
});
