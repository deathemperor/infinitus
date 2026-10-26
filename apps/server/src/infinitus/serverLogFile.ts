import { RotatingFileSink } from "@infinitus/shared/logging";
import * as Effect from "effect/Effect";
import * as Logger from "effect/Logger";

/**
 * The backend's own log file (#1182). Upstream persists log lines only through whoever started the
 * server, and a packaged desktop backend gets neither, so lines lived on a pipe and vanished. This
 * writes one NDJSON record per line whoever spawned it, rotated by the trace file's sink; separate
 * from the boot service's redirected-stdout `server.log` so no line lands twice in two formats.
 */
const SERVER_LOG_FILE_MAX_BYTES = 10 * 1024 * 1024;
const SERVER_LOG_FILE_MAX_FILES = 10;
const SERVER_LOG_FILE_BATCH_WINDOW_MS = 1_000;

export interface ServerLogFileOptions {
  readonly filePath: string;
  readonly maxBytes?: number;
  readonly maxFiles?: number;
  readonly batchWindowMs?: number;
  /** Seam for the test; the sink writes with `node:fs` by default. */
  readonly write?: (chunk: string) => void;
}

/**
 * `Logger.formatJson` stringifies the message, which runs every getter on it:
 * a getter that throws would fail the log call itself. Write accessor fields
 * of a plain message object as `[Getter]`, as the console's `util.inspect`
 * does, so logging never runs caller code.
 */
const formatJsonWithoutGetters = Logger.make<unknown, string>((options) =>
  Logger.formatJson.log({
    ...options,
    message: Array.isArray(options.message)
      ? options.message.map(withoutGetters)
      : withoutGetters(options.message),
  }),
);

function withoutGetters(value: unknown): unknown {
  if (typeof value !== "object" || value === null) return value;
  const prototype: unknown = Object.getPrototypeOf(value);
  if (prototype !== Object.prototype && prototype !== null) return value;
  const descriptors: PropertyDescriptorMap = Object.getOwnPropertyDescriptors(value);
  let changed = false;
  for (const key of Reflect.ownKeys(descriptors)) {
    const descriptor = descriptors[key];
    if (descriptor === undefined || "value" in descriptor) continue;
    descriptors[key] = { value: "[Getter]", enumerable: descriptor.enumerable === true };
    changed = true;
  }
  return changed ? Object.create(prototype, descriptors) : value;
}

/**
 * A logger that appends each record as one NDJSON line. Batched on a window,
 * so a burst of log lines is one append; the batch flushes when the scope
 * closes, so a clean shutdown loses nothing.
 */
export const makeServerLogFileLogger = Effect.fnUntraced(function* (options: ServerLogFileOptions) {
  const write =
    options.write ??
    ((): ((chunk: string) => void) => {
      const sink = new RotatingFileSink({
        filePath: options.filePath,
        maxBytes: options.maxBytes ?? SERVER_LOG_FILE_MAX_BYTES,
        maxFiles: options.maxFiles ?? SERVER_LOG_FILE_MAX_FILES,
      });
      return (chunk) => sink.write(chunk);
    })();

  return yield* Logger.batched(formatJsonWithoutGetters, {
    window: `${options.batchWindowMs ?? SERVER_LOG_FILE_BATCH_WINDOW_MS} millis`,
    // A sink that cannot write says so by swallowing it (`throwOnError` is
    // off): a log file is never worth failing a turn over.
    flush: (records) =>
      Effect.sync(() => {
        if (records.length === 0) return;
        write(`${records.join("\n")}\n`);
      }),
  });
});
