import type { PgClient } from "@effect/sql-pg/PgClient";
import * as Cloudflare from "alchemy/Cloudflare";
import * as Drizzle from "alchemy/Drizzle";
import * as Neon from "alchemy/Neon";
import * as Alchemy from "alchemy";
import * as RemovalPolicy from "alchemy/RemovalPolicy";
import type { EffectPgDatabase } from "drizzle-orm/effect-postgres";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";

import { relayDatabaseMode } from "./dbConfig.ts";

export class RelayDb extends Context.Service<
  RelayDb,
  EffectPgDatabase & {
    readonly $client: PgClient;
  }
>()("t3code-relay/db/RelayDb") {}

export class RelayTransactions extends Context.Service<
  RelayTransactions,
  {
    readonly withTransaction: RelayDb["Service"]["$client"]["withTransaction"];
  }
>()("t3code-relay/db/RelayTransactions") {
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
// Fresh logical ids: the two PlanetScale rows the first deploys left in the
// state store are orphans, which is why `Planetscale.providers()` is still
// registered in `alchemy.run.ts` until one deploy has dropped them.
export const NeonDatabase = Effect.gen(function* () {
  const { stage } = yield* Alchemy.Stack;
  const schema = yield* Drizzle.Schema("RelaySchema", {
    schema: "./src/persistence/schema.ts",
    out: "./migrations/postgres",
    dialect: "postgres",
  });

  const mode = relayDatabaseMode(stage);
  const migrations = { dir: schema.out, table: "relay_migrations" };
  const project =
    mode === "shared-database"
      ? yield* Neon.Project("RelayNeonProject", {
          name: "infinitus-relay",
          region: "aws-ap-southeast-1",
          ...(process.env.NEON_ORG_ID ? { orgId: process.env.NEON_ORG_ID } : {}),
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
