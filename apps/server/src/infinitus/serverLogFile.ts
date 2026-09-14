import { RotatingFileSink } from "@t3tools/shared/logging";
import * as Effect from "effect/Effect";
import * as Logger from "effect/Logger";

/**
 * The backend's own log file (#1182).
 *
 * Upstream persists a server's log lines only through whoever started it: a
 * boot service redirects stdout into `server.log` (`cloud/bootService.ts`),
 * and the desktop's Electron main process drains the child's pipes into
 * `server-child.log`. A packaged desktop backend gets neither in practice, so
 * every `Effect.log*` line — a withheld push, a stale port, a tunnel that
 * never came up — lived only on a pipe and was gone by the time anyone
 * looked. The trace file next to this one keeps spans, and `tracerLogger`
 * records a log as a span event only while a sampled span is open, which is
 * the minority of them.
 *
 * So the backend writes its own, whoever spawned it: one NDJSON record per
 * line, rotated by the same sink the trace file uses. It is a separate file
 * from `serverLogPath` on purpose — a boot service redirects stdout there,
 * and writing both would put every line in that file twice, in two formats.
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

  return yield* Logger.batched(Logger.formatJson, {
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
