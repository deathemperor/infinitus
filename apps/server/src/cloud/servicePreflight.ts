import packageJson from "../../package.json" with { type: "json" };
<<<<<<< HEAD
import { PRODUCT_NAME } from "@infinitus/shared/productName";
=======
import { BUILD_MIGRATION_HEAD, recordedMigrations } from "../persistence/databaseMigrationHead.ts";
>>>>>>> upstream-sync-97e35bcf2-upstream-renamed
import { SERVICE_LAUNCHER_PROTOCOL } from "./serviceProtocol.ts";

export type ServicePreflightResult =
  | {
      readonly status: "ready";
      readonly version: string;
      readonly launcherProtocol: typeof SERVICE_LAUNCHER_PROTOCOL;
    }
  | {
      readonly status: "blocked";
      readonly version: string;
      readonly reason: string;
    };

export function runServicePreflight(input: {
  readonly databasePath: string;
  readonly launcherProtocol: number;
  readonly version?: string;
}): ServicePreflightResult {
  const version = input.version ?? packageJson.version;
  if (input.launcherProtocol !== SERVICE_LAUNCHER_PROTOCOL) {
    return {
      status: "blocked",
      version,
      // A stale `infinitus` earlier on PATH (an old npm/nvm global) makes `infinitus service install`
      // reinstall itself and report success, so name the exact install and the path check. The
      // installer is not pinned to `version`: that is the server package's, not the release's.
      reason: [
        `The installed service launcher speaks protocol ${input.launcherProtocol}, but infinitus ${version} requires protocol ${SERVICE_LAUNCHER_PROTOCOL}.`,
        "On the server machine, install the current CLI: `curl -fsSL https://infinitus.run/install.sh | sh`.",
        `Check that \`infinitus --version\` prints ${version} and that \`which -a infinitus\` lists no older infinitus (such as an npm or nvm install) first, then run \`~/.local/bin/infinitus service install\` (the installer's default path).`,
        `Updating the ${PRODUCT_NAME} desktop app does not update this CLI, and \`infinitus service update\` only repairs the service with whichever CLI runs it.`,
      ].join(" "),
    };
  }

  const newer = newerRecordedMigrations(input.databasePath);
  if (newer === null) {
    return {
      status: "blocked",
      version,
      reason: `Could not read this database to confirm t3@${version} supports it.`,
    };
  }
  if (newer.length > 0) {
    return {
      status: "blocked",
      version,
      reason: `This database has migrations that t3@${version} does not know: ${newer.join(", ")}. A newer build wrote them, and running t3@${version} on this database is not safe. Stay on the newer release, or wait for a release that includes these migrations.`,
    };
  }

  return { status: "ready", version, launcherProtocol: SERVICE_LAUNCHER_PROTOCOL };
}

/** Migrations a newer build recorded, or null when the database exists but cannot be read.
 * Startup already handles renamed ids this build knows. */
function newerRecordedMigrations(databasePath: string): ReadonlyArray<string> | null {
  const recorded = recordedMigrations(databasePath);
  return recorded === null
    ? null
    : recorded.filter(({ id }) => id > BUILD_MIGRATION_HEAD).map(({ id, name }) => `${id}_${name}`);
}

export function decodeServicePreflightResult(value: unknown): ServicePreflightResult | undefined {
  if (typeof value !== "object" || value === null) {
    return undefined;
  }
  const record = value as Record<string, unknown>;
  if (
    record.status === "ready" &&
    record.launcherProtocol === SERVICE_LAUNCHER_PROTOCOL &&
    typeof record.version === "string"
  ) {
    return {
      status: "ready",
      version: record.version,
      launcherProtocol: SERVICE_LAUNCHER_PROTOCOL,
    };
  }
  if (
    record.status === "blocked" &&
    typeof record.version === "string" &&
    typeof record.reason === "string"
  ) {
    return { status: "blocked", version: record.version, reason: record.reason };
  }
  return undefined;
}
