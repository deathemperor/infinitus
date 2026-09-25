CREATE TABLE "infinitus_team_commands" (
	"command_id" varchar(36) PRIMARY KEY,
	"team_id" varchar(36) NOT NULL,
	"from_user_id" varchar(191) NOT NULL,
	"to_user_id" varchar(191) NOT NULL,
	"environment_id" varchar(191) NOT NULL,
	"grant_id" varchar(36) NOT NULL,
	"thread_id" varchar(512) NOT NULL,
	"action" varchar(16) NOT NULL,
	"text" text,
	"project" varchar(256),
	"status" varchar(16) NOT NULL,
	"ack_json" jsonb,
	"created_at" varchar(64) NOT NULL,
	"expires_at" varchar(64) NOT NULL,
	"answered_at" varchar(64)
);
--> statement-breakpoint
CREATE TABLE "infinitus_team_documents" (
	"team_id" varchar(36),
	"user_id" varchar(191),
	"environment_id" varchar(191),
	"kind" varchar(16),
	"key" varchar(32),
	"body_json" jsonb NOT NULL,
	"updated_at" varchar(64) NOT NULL,
	CONSTRAINT "infinitus_team_documents_pkey" PRIMARY KEY("team_id","user_id","environment_id","kind","key")
);
--> statement-breakpoint
CREATE TABLE "infinitus_team_grants" (
	"grant_id" varchar(36) PRIMARY KEY,
	"team_id" varchar(36) NOT NULL,
	"user_id" varchar(191) NOT NULL,
	"environment_id" varchar(191) NOT NULL,
	"audience_json" jsonb NOT NULL,
	"threads_json" jsonb NOT NULL,
	"capabilities_json" jsonb NOT NULL,
	"preauthorized_json" jsonb NOT NULL,
	"expires_at" varchar(64),
	"created_at" varchar(64) NOT NULL
);
--> statement-breakpoint
CREATE TABLE "infinitus_team_invites" (
	"invite_id" varchar(36) PRIMARY KEY,
	"team_id" varchar(36) NOT NULL,
	"token_hash" varchar(64) NOT NULL,
	"created_by_user_id" varchar(191) NOT NULL,
	"one_use" boolean NOT NULL,
	"used_by_user_id" varchar(191),
	"expires_at" varchar(64) NOT NULL,
	"revoked_at" varchar(64),
	"created_at" varchar(64) NOT NULL
);
--> statement-breakpoint
CREATE TABLE "infinitus_team_members" (
	"team_id" varchar(36),
	"user_id" varchar(191),
	"role" varchar(8) NOT NULL,
	"name" varchar(64) NOT NULL,
	"shares_json" jsonb NOT NULL,
	"since" varchar(64) NOT NULL,
	"updated_at" varchar(64) NOT NULL,
	CONSTRAINT "infinitus_team_members_pkey" PRIMARY KEY("team_id","user_id")
);
--> statement-breakpoint
CREATE TABLE "infinitus_team_requests" (
	"team_id" varchar(36),
	"user_id" varchar(191),
	"name" varchar(64) NOT NULL,
	"invite_id" varchar(36) NOT NULL,
	"created_at" varchar(64) NOT NULL,
	CONSTRAINT "infinitus_team_requests_pkey" PRIMARY KEY("team_id","user_id")
);
--> statement-breakpoint
CREATE TABLE "infinitus_team_transcripts" (
	"team_id" varchar(36),
	"user_id" varchar(191),
	"environment_id" varchar(191),
	"thread_id" varchar(512),
	"seq" integer,
	"rows" integer NOT NULL,
	"bytes" integer NOT NULL,
	"object_key" text NOT NULL,
	"created_at" varchar(64) NOT NULL,
	CONSTRAINT "infinitus_team_transcripts_pkey" PRIMARY KEY("team_id","user_id","environment_id","thread_id","seq")
);
--> statement-breakpoint
CREATE TABLE "infinitus_teams" (
	"team_id" varchar(36) PRIMARY KEY,
	"name" varchar(64) NOT NULL,
	"founder_user_id" varchar(191) NOT NULL,
	"policy_requests" varchar(8) DEFAULT 'code' NOT NULL,
	"created_at" varchar(64) NOT NULL,
	"updated_at" varchar(64) NOT NULL
);
--> statement-breakpoint
CREATE INDEX "idx_infinitus_team_commands_env_status" ON "infinitus_team_commands" ("environment_id","status");--> statement-breakpoint
CREATE INDEX "idx_infinitus_team_commands_from" ON "infinitus_team_commands" ("from_user_id","created_at");--> statement-breakpoint
CREATE INDEX "idx_infinitus_team_documents_team_kind" ON "infinitus_team_documents" ("team_id","kind");--> statement-breakpoint
CREATE INDEX "idx_infinitus_team_grants_env" ON "infinitus_team_grants" ("team_id","environment_id");--> statement-breakpoint
CREATE UNIQUE INDEX "uq_infinitus_team_invites_token_hash" ON "infinitus_team_invites" ("token_hash");--> statement-breakpoint
CREATE INDEX "idx_infinitus_team_invites_team" ON "infinitus_team_invites" ("team_id");--> statement-breakpoint
CREATE INDEX "idx_infinitus_team_members_user" ON "infinitus_team_members" ("user_id");--> statement-breakpoint
CREATE INDEX "idx_infinitus_team_transcripts_member" ON "infinitus_team_transcripts" ("team_id","user_id","created_at");