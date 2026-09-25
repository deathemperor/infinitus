import { boolean, index, integer, jsonb, pgTable, primaryKey, text, uniqueIndex, varchar } from "drizzle-orm/pg-core";

/**
 * Team on Infinitus Connect (#1592). Times are ISO strings like the rest of
 * the relay schema; ids are uuids the relay mints. Re-exported from
 * `persistence/schema.ts`, the one path `Drizzle.Schema` reads, so the
 * migration generator sees these tables.
 */

export const infinitusTeams = pgTable("infinitus_teams", {
  teamId: varchar("team_id", { length: 36 }).primaryKey(),
  name: varchar("name", { length: 64 }).notNull(),
  founderUserId: varchar("founder_user_id", { length: 191 }).notNull(),
  policyRequests: varchar("policy_requests", { length: 8 }).notNull().default("code"),
  createdAt: varchar("created_at", { length: 64 }).notNull(),
  updatedAt: varchar("updated_at", { length: 64 }).notNull(),
});

export const infinitusTeamMembers = pgTable(
  "infinitus_team_members",
  {
    teamId: varchar("team_id", { length: 36 }).notNull(),
    userId: varchar("user_id", { length: 191 }).notNull(),
    role: varchar("role", { length: 8 }).notNull(),
    name: varchar("name", { length: 64 }).notNull(),
    sharesJson: jsonb("shares_json").$type<Record<string, string>>().notNull(),
    since: varchar("since", { length: 64 }).notNull(),
    updatedAt: varchar("updated_at", { length: 64 }).notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.teamId, table.userId] }),
    index("idx_infinitus_team_members_user").on(table.userId),
  ],
);

export const infinitusTeamInvites = pgTable(
  "infinitus_team_invites",
  {
    inviteId: varchar("invite_id", { length: 36 }).primaryKey(),
    teamId: varchar("team_id", { length: 36 }).notNull(),
    tokenHash: varchar("token_hash", { length: 64 }).notNull(),
    createdByUserId: varchar("created_by_user_id", { length: 191 }).notNull(),
    oneUse: boolean("one_use").notNull(),
    usedByUserId: varchar("used_by_user_id", { length: 191 }),
    expiresAt: varchar("expires_at", { length: 64 }).notNull(),
    revokedAt: varchar("revoked_at", { length: 64 }),
    createdAt: varchar("created_at", { length: 64 }).notNull(),
  },
  (table) => [
    uniqueIndex("uq_infinitus_team_invites_token_hash").on(table.tokenHash),
    index("idx_infinitus_team_invites_team").on(table.teamId),
  ],
);

export const infinitusTeamRequests = pgTable(
  "infinitus_team_requests",
  {
    teamId: varchar("team_id", { length: 36 }).notNull(),
    userId: varchar("user_id", { length: 191 }).notNull(),
    name: varchar("name", { length: 64 }).notNull(),
    inviteId: varchar("invite_id", { length: 36 }).notNull(),
    createdAt: varchar("created_at", { length: 64 }).notNull(),
  },
  (table) => [primaryKey({ columns: [table.teamId, table.userId] })],
);

export const infinitusTeamDocuments = pgTable(
  "infinitus_team_documents",
  {
    teamId: varchar("team_id", { length: 36 }).notNull(),
    userId: varchar("user_id", { length: 191 }).notNull(),
    environmentId: varchar("environment_id", { length: 191 }).notNull(),
    kind: varchar("kind", { length: 16 }).notNull(),
    key: varchar("key", { length: 32 }).notNull(),
    bodyJson: jsonb("body_json").$type<unknown>().notNull(),
    updatedAt: varchar("updated_at", { length: 64 }).notNull(),
  },
  (table) => [
    primaryKey({ columns: [table.teamId, table.userId, table.environmentId, table.kind, table.key] }),
    index("idx_infinitus_team_documents_team_kind").on(table.teamId, table.kind),
  ],
);

export const infinitusTeamTranscripts = pgTable(
  "infinitus_team_transcripts",
  {
    teamId: varchar("team_id", { length: 36 }).notNull(),
    userId: varchar("user_id", { length: 191 }).notNull(),
    environmentId: varchar("environment_id", { length: 191 }).notNull(),
    threadId: varchar("thread_id", { length: 512 }).notNull(),
    seq: integer("seq").notNull(),
    rows: integer("rows").notNull(),
    bytes: integer("bytes").notNull(),
    objectKey: text("object_key").notNull(),
    createdAt: varchar("created_at", { length: 64 }).notNull(),
  },
  (table) => [
    primaryKey({
      columns: [table.teamId, table.userId, table.environmentId, table.threadId, table.seq],
    }),
    index("idx_infinitus_team_transcripts_member").on(table.teamId, table.userId, table.createdAt),
  ],
);

export const infinitusTeamGrants = pgTable(
  "infinitus_team_grants",
  {
    grantId: varchar("grant_id", { length: 36 }).primaryKey(),
    teamId: varchar("team_id", { length: 36 }).notNull(),
    userId: varchar("user_id", { length: 191 }).notNull(),
    environmentId: varchar("environment_id", { length: 191 }).notNull(),
    audienceJson: jsonb("audience_json").$type<unknown>().notNull(),
    threadsJson: jsonb("threads_json").$type<unknown>().notNull(),
    capabilitiesJson: jsonb("capabilities_json").$type<ReadonlyArray<string>>().notNull(),
    preauthorizedJson: jsonb("preauthorized_json").$type<ReadonlyArray<string>>().notNull(),
    expiresAt: varchar("expires_at", { length: 64 }),
    createdAt: varchar("created_at", { length: 64 }).notNull(),
  },
  (table) => [index("idx_infinitus_team_grants_env").on(table.teamId, table.environmentId)],
);

export const infinitusTeamCommands = pgTable(
  "infinitus_team_commands",
  {
    commandId: varchar("command_id", { length: 36 }).primaryKey(),
    teamId: varchar("team_id", { length: 36 }).notNull(),
    fromUserId: varchar("from_user_id", { length: 191 }).notNull(),
    toUserId: varchar("to_user_id", { length: 191 }).notNull(),
    environmentId: varchar("environment_id", { length: 191 }).notNull(),
    grantId: varchar("grant_id", { length: 36 }).notNull(),
    threadId: varchar("thread_id", { length: 512 }).notNull(),
    action: varchar("action", { length: 16 }).notNull(),
    text: text("text"),
    project: varchar("project", { length: 256 }),
    status: varchar("status", { length: 16 }).notNull(),
    ackJson: jsonb("ack_json").$type<unknown>(),
    createdAt: varchar("created_at", { length: 64 }).notNull(),
    expiresAt: varchar("expires_at", { length: 64 }).notNull(),
    answeredAt: varchar("answered_at", { length: 64 }),
  },
  (table) => [
    index("idx_infinitus_team_commands_env_status").on(table.environmentId, table.status),
    index("idx_infinitus_team_commands_from").on(table.fromUserId, table.createdAt),
  ],
);
