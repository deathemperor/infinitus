import { ProjectId } from "@t3tools/contracts";
import { MAX_CAPTURES_PER_PROJECT, type CaptureId } from "@t3tools/contracts/captures";
import * as NodeServices from "@effect/platform-node/NodeServices";
import { it } from "@effect/vitest";
import * as DateTime from "effect/DateTime";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Layer from "effect/Layer";
import * as Option from "effect/Option";
import * as Path from "effect/Path";
import * as Queue from "effect/Queue";
import * as Stream from "effect/Stream";
import { describe, expect } from "vite-plus/test";

import * as ServerConfig from "../config.ts";
import { applyCaptureCommand, CaptureStore, layer as CaptureStoreLayer } from "./CaptureStore.ts";

const PROJECT = ProjectId.make("project-1");
const OTHER = ProjectId.make("project/with slashes");

const storeLayer = () =>
  CaptureStoreLayer.pipe(
    Layer.provideMerge(
      Layer.fresh(ServerConfig.layerTest(process.cwd(), { prefix: "t3code-captures-test-" })),
    ),
    Layer.provideMerge(NodeServices.layer),
  );

const current = (store: CaptureStore["Service"], projectId: ProjectId) =>
  store
    .subscribe(projectId)
    .pipe(Effect.flatMap(Stream.runHead), Effect.map(Option.getOrElse(() => [])));

const capturesFile = (projectId: ProjectId) =>
  Effect.gen(function* () {
    const { stateDir } = yield* ServerConfig.ServerConfig;
    const path = yield* Path.Path;
    return path.join(stateDir, "captures", `${encodeURIComponent(projectId)}.json`);
  });

describe("applyCaptureCommand", () => {
  const now = DateTime.makeUnsafe("2026-09-11T10:00:00Z");
  const later = DateTime.makeUnsafe("2026-09-11T10:05:00Z");
  const id = "cap-1" as CaptureId;
  const one = applyCaptureCommand([], { type: "add", text: "buy milk" }, { id, now });

  it("appends an open item", () => {
    expect(one).toEqual([{ id, text: "buy milk", createdAt: now, doneAt: null }]);
  });

  it("checks off with the time, reopens with null, and returns the same list when nothing changes", () => {
    const done = applyCaptureCommand(one, { type: "setDone", id, done: true }, { id, now: later });
    expect(done[0]?.doneAt).toEqual(later);
    expect(applyCaptureCommand(done, { type: "setDone", id, done: true }, { id, now })).toBe(done);
    expect(
      applyCaptureCommand(done, { type: "setDone", id, done: false }, { id, now })[0]?.doneAt,
    ).toBeNull();
  });

  it("ignores commands naming an id that is gone", () => {
    const missing = "cap-9" as CaptureId;
    expect(applyCaptureCommand(one, { type: "remove", id: missing }, { id, now })).toBe(one);
    expect(applyCaptureCommand(one, { type: "edit", id: missing, text: "x" }, { id, now })).toBe(
      one,
    );
    expect(
      applyCaptureCommand(one, { type: "setDone", id: missing, done: true }, { id, now }),
    ).toBe(one);
  });

  it("clears only the done items", () => {
    const two = applyCaptureCommand(
      one,
      { type: "add", text: "call mum" },
      { id: "cap-2" as CaptureId, now },
    );
    const done = applyCaptureCommand(two, { type: "setDone", id, done: true }, { id, now });
    expect(
      applyCaptureCommand(done, { type: "clearDone" }, { id, now }).map((item) => item.id),
    ).toEqual(["cap-2"]);
    expect(applyCaptureCommand(two, { type: "clearDone" }, { id, now })).toBe(two);
  });
});

describe("CaptureStore", () => {
  it.effect("starts empty, applies in order, and streams the whole list after each change", () =>
    Effect.gen(function* () {
      const store = yield* CaptureStore;
      expect(yield* current(store, PROJECT)).toEqual([]);

      const changes = yield* store.subscribe(PROJECT);
      const seen = yield* Queue.unbounded<ReadonlyArray<string>>();
      yield* Stream.runForEach(changes, (list) =>
        Queue.offer(
          seen,
          list.map((item) => item.text),
        ),
      ).pipe(Effect.forkScoped);
      // The current list comes first — and proves the subscription is up.
      expect(yield* Queue.take(seen)).toEqual([]);

      // Trimming is the contract's job at decode; the store keeps what it is given.
      yield* store.apply(PROJECT, { type: "add", text: "first" });
      expect(yield* Queue.take(seen)).toEqual(["first"]);
      yield* store.apply(PROJECT, { type: "add", text: "second" });
      expect(yield* Queue.take(seen)).toEqual(["first", "second"]);

      const [first] = yield* current(store, PROJECT);
      yield* store.apply(PROJECT, { type: "setDone", id: first!.id, done: true });
      yield* store.apply(PROJECT, { type: "clearDone" });
      expect((yield* current(store, PROJECT)).map((item) => item.text)).toEqual(["second"]);
    }).pipe(Effect.scoped, Effect.provide(storeLayer())),
  );

  it.effect("keeps each project's list in its own file under the state dir and reads it back", () =>
    Effect.gen(function* () {
      const store = yield* CaptureStore;
      const fs = yield* FileSystem.FileSystem;
      yield* store.apply(PROJECT, { type: "add", text: "alpha" });
      yield* store.apply(OTHER, { type: "add", text: "beta" });

      const file = yield* capturesFile(OTHER);
      expect(file.endsWith("project%2Fwith%20slashes.json")).toBe(true);
      const raw = yield* fs.readFileString(file);
      expect(raw).toContain('"text": "beta"');
      expect(raw).not.toContain("alpha");

      // A fresh store over the same directory sees the file, not the memory.
      const config = yield* ServerConfig.ServerConfig;
      const reread = yield* Effect.gen(function* () {
        const again = yield* CaptureStore;
        return yield* current(again, OTHER);
      }).pipe(
        Effect.provide(
          CaptureStoreLayer.pipe(
            Layer.provide(ServerConfig.layer(config)),
            Layer.provide(NodeServices.layer),
          ),
        ),
      );
      expect(reread.map((item) => item.text)).toEqual(["beta"]);
    }).pipe(Effect.provide(storeLayer())),
  );

  it.effect("refuses to add past the cap and to touch a file it cannot read", () =>
    Effect.gen(function* () {
      const store = yield* CaptureStore;
      const fs = yield* FileSystem.FileSystem;
      for (let index = 0; index < MAX_CAPTURES_PER_PROJECT; index += 1) {
        yield* store.apply(PROJECT, { type: "add", text: `item ${index}` });
      }
      const full = yield* store.apply(PROJECT, { type: "add", text: "one more" }).pipe(Effect.flip);
      expect(full._tag).toBe("CaptureListFull");
      // Removing still works when full.
      const [first] = yield* current(store, PROJECT);
      yield* store.apply(PROJECT, { type: "remove", id: first!.id });
      expect((yield* current(store, PROJECT)).length).toBe(MAX_CAPTURES_PER_PROJECT - 1);

      const file = yield* capturesFile(OTHER);
      yield* fs.makeDirectory(file.slice(0, file.lastIndexOf("/")), { recursive: true });
      yield* fs.writeFileString(file, "{ not a list");
      const broken = yield* store.apply(OTHER, { type: "add", text: "x" }).pipe(Effect.flip);
      expect(broken._tag).toBe("CaptureStoreError");
      expect(yield* fs.readFileString(file)).toBe("{ not a list");
    }).pipe(Effect.provide(storeLayer())),
  );
});
