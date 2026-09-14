import * as NodeServices from "@effect/platform-node/NodeServices";
import { it } from "@effect/vitest";
import * as Effect from "effect/Effect";
import * as FileSystem from "effect/FileSystem";
import * as Logger from "effect/Logger";
import * as Path from "effect/Path";
import * as Schema from "effect/Schema";
import { expect } from "vite-plus/test";

import { makeServerLogFileLogger } from "./serverLogFile.ts";

const decodeJsonLine = Schema.decodeUnknownSync(Schema.fromJsonString(Schema.Unknown));

/** Every non-empty line must be one JSON document; returns the raw lines. */
const jsonLines = (chunks: ReadonlyArray<string>): ReadonlyArray<string> => {
  const lines = chunks
    .join("")
    .split("\n")
    .filter((line) => line.length > 0);
  for (const line of lines) decodeJsonLine(line);
  return lines;
};

const captureLayer = (chunks: Array<string>) =>
  Logger.layer(
    [
      makeServerLogFileLogger({
        filePath: "/never-written",
        batchWindowMs: 60_000,
        write: (chunk) => chunks.push(chunk),
      }),
    ],
    { mergeWithExisting: false },
  );

it.effect("writes one JSON record per line and flushes the batch when the scope closes", () =>
  Effect.gen(function* () {
    const chunks: Array<string> = [];
    yield* Effect.gen(function* () {
      yield* Effect.logInfo("first line");
      yield* Effect.logWarning("second line").pipe(Effect.annotateLogs({ threadId: "thread-1" }));
      yield* Effect.logInfo("third line");
    }).pipe(Effect.provide(captureLayer(chunks)));

    // Nothing was written by the window; the layer's scope closing flushed it.
    expect(chunks.length).toBe(1);
    expect(chunks[0]?.endsWith("\n")).toBe(true);
    const lines = jsonLines(chunks);
    expect(lines.length).toBe(3);
    expect(lines[0]).toContain("first line");
    expect(lines[1]).toContain("second line");
    expect(lines[1]).toContain("thread-1");
    expect(lines[2]).toContain("third line");
  }),
);

it.effect("writes nothing when nothing was logged", () =>
  Effect.gen(function* () {
    const chunks: Array<string> = [];
    yield* Effect.void.pipe(Effect.provide(captureLayer(chunks)));
    expect(chunks).toEqual([]);
  }),
);

it.effect("appends NDJSON to the real rotating file when no seam is given", () =>
  Effect.gen(function* () {
    const fs = yield* FileSystem.FileSystem;
    const path = yield* Path.Path;
    const dir = yield* fs.makeTempDirectoryScoped({ prefix: "infinitus-server-log-" });
    const filePath = path.join(dir, "logs", "server.log.ndjson");
    yield* Effect.logInfo("on disk").pipe(
      Effect.provide(
        Logger.layer([makeServerLogFileLogger({ filePath, batchWindowMs: 60_000 })], {
          mergeWithExisting: false,
        }),
      ),
    );
    const lines = jsonLines([yield* fs.readFileString(filePath)]);
    expect(lines.length).toBe(1);
    expect(lines[0]).toContain("on disk");
  }).pipe(Effect.scoped, Effect.provide(NodeServices.layer)),
);
