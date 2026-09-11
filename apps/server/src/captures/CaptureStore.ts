/**
 * CaptureStore — a project's capture list (#433), kept as one JSON file per
 * project under the server's state directory and streamed whole to every
 * client of the project after each change.
 *
 * Never in the workspace: a file there would show in every `git status`,
 * in the diff panels, and in each worktree separately. Loaded on first use,
 * written atomically, changed under one lock.
 *
 * @module CaptureStore
 */
import type { ProjectId } from "@t3tools/contracts";
import {
  CaptureList,
  CaptureListFull,
  CaptureStoreError,
  MAX_CAPTURES_PER_PROJECT,
  type CaptureCommand,
  type CaptureId,
} from "@t3tools/contracts/captures";
import { fromJsonStringPretty } from "@t3tools/shared/schemaJson";
import * as Context from "effect/Context";
import * as Crypto from "effect/Crypto";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import * as Semaphore from "effect/Semaphore";
import * as Stream from "effect/Stream";
import * as SubscriptionRef from "effect/SubscriptionRef";

import { writeFileStringAtomically } from "../atomicWrite.ts";
import * as ServerConfig from "../config.ts";

export interface CaptureStoreShape {
  /** The project's list now, then the whole list again after every change. */
  readonly subscribe: (
    projectId: ProjectId,
  ) => Effect.Effect<Stream.Stream<CaptureList>, CaptureStoreError>;
  /** One change, written to disk before the subscribers see it. */
  readonly apply: (
    projectId: ProjectId,
    command: CaptureCommand,
  ) => Effect.Effect<void, CaptureListFull | CaptureStoreError>;
}

export class CaptureStore extends Context.Service<CaptureStore, CaptureStoreShape>()(
  "t3/captures/CaptureStore",
) {}

const CaptureListJson = fromJsonStringPretty(CaptureList);
const decodeCaptureList = Schema.decodeUnknownEffect(CaptureListJson);
const encodeCaptureList = Schema.encodeEffect(CaptureListJson);

/** What one command does to a list. A command naming an id that is gone,
    or a `setDone` that changes nothing, returns the same list. */
export function applyCaptureCommand(
  list: CaptureList,
  command: CaptureCommand,
  context: { readonly id: CaptureId; readonly now: DateTime.Utc },
): CaptureList {
  switch (command.type) {
    case "add":
      return [
        ...list,
        { id: context.id, text: command.text, createdAt: context.now, doneAt: null },
      ];
    case "edit":
      return list.some((item) => item.id === command.id && item.text !== command.text)
        ? list.map((item) => (item.id === command.id ? { ...item, text: command.text } : item))
        : list;
    case "setDone":
      return list.some((item) => item.id === command.id && (item.doneAt !== null) !== command.done)
        ? list.map((item) =>
            item.id === command.id ? { ...item, doneAt: command.done ? context.now : null } : item,
          )
        : list;
    case "remove":
      return list.some((item) => item.id === command.id)
        ? list.filter((item) => item.id !== command.id)
        : list;
    case "clearDone":
      return list.some((item) => item.doneAt !== null)
        ? list.filter((item) => item.doneAt === null)
        : list;
  }
}

const make = Effect.gen(function* () {
  const { stateDir } = yield* ServerConfig.ServerConfig;
  const fs = yield* FileSystem.FileSystem;
  const path = yield* Path.Path;
  const crypto = yield* Crypto.Crypto;
  const lock = yield* Semaphore.make(1);
  const lists = new Map<ProjectId, SubscriptionRef.SubscriptionRef<CaptureList>>();

  // Ids are trimmed non-empty strings of any shape; percent-encoding keeps
  // every one of them a single path segment.
  const filePath = (projectId: ProjectId) =>
    path.join(stateDir, "captures", `${encodeURIComponent(projectId)}.json`);

  const storeError = (projectId: ProjectId) => (cause: { readonly message: string }) =>
    new CaptureStoreError({ projectId, detail: cause.message });

  const load = (projectId: ProjectId) =>
    Effect.gen(function* () {
      const file = filePath(projectId);
      if (!(yield* fs.exists(file).pipe(Effect.mapError(storeError(projectId))))) {
        return [] as CaptureList;
      }
      const raw = yield* fs.readFileString(file).pipe(Effect.mapError(storeError(projectId)));
      // A file this server cannot read stays as it is: the error names the
      // issue, never the contents, and nothing overwrites the user's notes.
      return yield* decodeCaptureList(raw).pipe(Effect.mapError(storeError(projectId)));
    });

  /** The project's ref, loading its file the first time. Under the lock so
      two first callers share one load. */
  const ref = (projectId: ProjectId) =>
    lock.withPermits(1)(
      Effect.gen(function* () {
        const existing = lists.get(projectId);
        if (existing !== undefined) return existing;
        const created = yield* SubscriptionRef.make(yield* load(projectId));
        lists.set(projectId, created);
        return created;
      }),
    );

  const subscribe: CaptureStoreShape["subscribe"] = (projectId) =>
    ref(projectId).pipe(Effect.map((current) => SubscriptionRef.changes(current)));

  const apply: CaptureStoreShape["apply"] = (projectId, command) =>
    Effect.gen(function* () {
      const current = yield* ref(projectId);
      yield* lock.withPermits(1)(
        Effect.gen(function* () {
          const list = yield* SubscriptionRef.get(current);
          if (command.type === "add" && list.length >= MAX_CAPTURES_PER_PROJECT) {
            return yield* new CaptureListFull({ projectId, limit: MAX_CAPTURES_PER_PROJECT });
          }
          const id = (yield* crypto.randomUUIDv4.pipe(Effect.orDie)) as CaptureId;
          const next = applyCaptureCommand(list, command, { id, now: yield* DateTime.now });
          if (next === list) return;
          const contents = yield* encodeCaptureList(next).pipe(
            Effect.mapError(storeError(projectId)),
          );
          yield* writeFileStringAtomically({ filePath: filePath(projectId), contents }).pipe(
            Effect.provideService(FileSystem.FileSystem, fs),
            Effect.provideService(Path.Path, path),
            Effect.mapError(storeError(projectId)),
          );
          yield* SubscriptionRef.set(current, next);
        }),
      );
    });

  return { subscribe, apply } satisfies CaptureStoreShape;
});

export const layer = Layer.effect(CaptureStore, make);
