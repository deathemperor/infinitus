import * as Alchemy from "alchemy";
import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as Layer from "effect/Layer";
import * as Schema from "effect/Schema";

/**
 * Where transcript chunks' bytes live (#1592): R2 in the Worker, a Map in
 * tests. One row per chunk stays in Postgres (`infinitus_team_transcripts`);
 * this is only the text. Keys are
 * `teams/<team>/<user>/<environment>/<thread>/<seq>.jsonl`.
 */
export class InfinitusTeamTranscriptStoreError extends Schema.TaggedError<InfinitusTeamTranscriptStoreError>()(
  "InfinitusTeamTranscriptStoreError",
  { op: Schema.Literals(["put", "get", "delete"]), cause: Schema.Defect() },
) {
  override get message(): string {
    return `Infinitus Team transcript ${this.op} failed`;
  }
}

export class InfinitusTeamTranscriptStore extends Context.Service<
  InfinitusTeamTranscriptStore,
  {
    readonly put: (
      key: string,
      lines: string,
    ) => Effect.Effect<void, InfinitusTeamTranscriptStoreError>;
    readonly get: (key: string) => Effect.Effect<string | null, InfinitusTeamTranscriptStoreError>;
    readonly delete: (
      keys: ReadonlyArray<string>,
    ) => Effect.Effect<void, InfinitusTeamTranscriptStoreError>;
  }
>()("infinitus-relay/infinitusTeam/InfinitusTeamTranscriptStore") {}

export const objectKey = (input: {
  readonly teamId: string;
  readonly userId: string;
  readonly environmentId: string;
  readonly threadId: string;
  readonly seq: number;
}) =>
  `teams/${input.teamId}/${input.userId}/${encodeURIComponent(input.environmentId)}/${encodeURIComponent(input.threadId)}/${input.seq}.jsonl`;

export const inMemoryLayer = (objects: Map<string, string> = new Map()) =>
  Layer.succeed(InfinitusTeamTranscriptStore, {
    put: (key, lines) =>
      Effect.sync(() => {
        objects.set(key, lines);
      }),
    get: (key) => Effect.sync(() => objects.get(key) ?? null),
    delete: (keys) =>
      Effect.sync(() => {
        for (const key of keys) objects.delete(key);
      }),
  });

/** The Worker's store: the R2 bucket binding, every call run under the
    Alchemy runtime context the binding needs (as the queue senders are). */
export const layerR2 = (
  bucket: {
    readonly put: (
      key: string,
      value: string,
    ) => Effect.Effect<unknown, { readonly message: string }, Alchemy.RuntimeContext>;
    readonly get: (
      key: string,
    ) => Effect.Effect<
      { text(): Effect.Effect<string, { readonly message: string }> } | null,
      { readonly message: string },
      Alchemy.RuntimeContext
    >;
    readonly delete: (
      keys: string | string[],
    ) => Effect.Effect<void, { readonly message: string }, Alchemy.RuntimeContext>;
  },
  runtimeContext: Alchemy.BaseRuntimeContext,
) =>
  Layer.succeed(InfinitusTeamTranscriptStore, {
    put: (key, lines) =>
      bucket.put(key, lines).pipe(
        Effect.asVoid,
        Effect.mapError((cause) => new InfinitusTeamTranscriptStoreError({ op: "put", cause })),
        Effect.provideService(Alchemy.RuntimeContext, runtimeContext),
      ),
    get: (key) =>
      bucket.get(key).pipe(
        Effect.flatMap((body) => (body === null ? Effect.succeed(null) : body.text())),
        Effect.mapError((cause) => new InfinitusTeamTranscriptStoreError({ op: "get", cause })),
        Effect.provideService(Alchemy.RuntimeContext, runtimeContext),
      ),
    delete: (keys) =>
      keys.length === 0
        ? Effect.void
        : bucket.delete([...keys]).pipe(
            Effect.mapError(
              (cause) => new InfinitusTeamTranscriptStoreError({ op: "delete", cause }),
            ),
            Effect.provideService(Alchemy.RuntimeContext, runtimeContext),
          ),
  });
