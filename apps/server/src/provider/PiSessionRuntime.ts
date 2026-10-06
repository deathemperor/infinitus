/**
 * PiSessionRuntime — one `pi --mode rpc` child process and its JSONL wire.
 *
 * Owns the transport only: spawn, frame commands onto stdin, decode records
 * off stdout, and hand them to the adapter as they arrive. Translation into
 * orchestration events lives in {@link ./PiAdapter.ts}.
 *
 * @module provider/Layers/PiSessionRuntime
 */
import type { PiSettings } from "@infinitus/contracts";
import { resolveSpawnCommand } from "@infinitus/shared/shell";
import * as Effect from "effect/Effect";
import * as Option from "effect/Option";
import * as Queue from "effect/Queue";
import * as Ref from "effect/Ref";
import * as Schema from "effect/Schema";
import * as Scope from "effect/Scope";
import * as Stream from "effect/Stream";
import { ChildProcess, ChildProcessSpawner } from "effect/unstable/process";

import { expandHomePath } from "../../pathExpansion.ts";
import { piHomeEnvironment } from "./piHomeEnvironment.ts";
import {
  decodePiRpcRecord,
  serializePiRpcCommand,
  splitPiRpcLines,
  type PiRpcRecord,
} from "./piRpcProtocol.ts";

/** Parses one framed line, or `undefined` when it is not a record we can read. */
function readPiRpcLine(line: string): PiRpcRecord | undefined {
  let parsed: unknown;
  try {
    parsed = JSON.parse(line);
  } catch {
    return undefined;
  }
  return Option.getOrUndefined(decodePiRpcRecord(parsed));
}

/** SIGTERM first, then SIGKILL, matching the other CLI-backed runtimes. */
const PI_FORCE_KILL_AFTER = "2 seconds" as const;

export interface PiSessionRuntimeOptions {
  readonly cwd: string;
  readonly homePath?: string;
  readonly environment: NodeJS.ProcessEnv;
  /** `provider/model`; omitted for the `pi-default` sentinel. */
  readonly model?: string;
  /** Resume cursor. `--session-id` is exact and creates the session if absent. */
  readonly sessionId?: string;
}

export interface PiSessionRuntimeShape {
  /** Records as Pi emits them, in order. Ends when the process exits. */
  readonly records: Stream.Stream<PiRpcRecord>;
  readonly send: (command: unknown) => Effect.Effect<void, PiRpcTransportError>;
  /** Stderr collected so far, for error detail on a failed spawn or turn. */
  readonly stderr: Effect.Effect<string>;
  readonly pid: number;
}

export class PiRpcTransportError extends Schema.TaggedError<PiRpcTransportError>()(
  "PiRpcTransportError",
  {
    detail: Schema.String,
    cause: Schema.optional(Schema.Defect()),
  },
) {
  override get message(): string {
    return `Pi RPC transport error: ${this.detail}`;
  }
}

/**
 * Builds the argv for an RPC session.
 *
 * `--mode rpc` is the protocol. A model is passed only when the caller
 * resolved one — `pi-default` is our sentinel for "whatever Pi is configured
 * to use" and is not a slug Pi knows, so passing it fails the process with
 * `Model "pi-default" not found`.
 */
export function piRpcArgs(options: {
  readonly model?: string;
  readonly sessionId?: string;
}): ReadonlyArray<string> {
  return [
    "--mode",
    "rpc",
    ...(options.model ? ["--model", options.model] : []),
    ...(options.sessionId ? ["--session-id", options.sessionId] : []),
  ];
}

export const makePiSessionRuntime = Effect.fn("makePiSessionRuntime")(function* (
  piSettings: PiSettings,
  options: PiSessionRuntimeOptions,
): Effect.fn.Return<
  PiSessionRuntimeShape,
  PiRpcTransportError,
  ChildProcessSpawner.ChildProcessSpawner | Scope.Scope
> {
  const spawner = yield* ChildProcessSpawner.ChildProcessSpawner;
  const runtimeScope = yield* Scope.Scope;
  const binaryPath = expandHomePath(piSettings.binaryPath || "pi");
  const args = piRpcArgs(options);
  const env = piHomeEnvironment(options.environment, options.homePath);

  const spawnCommand = yield* resolveSpawnCommand(binaryPath, args, { env }).pipe(
    Effect.mapError(
      (cause) => new PiRpcTransportError({ detail: `Failed to resolve '${binaryPath}'.`, cause }),
    ),
  );

  // Commands are written from many fibers (a turn, an abort, a compaction), so
  // they are serialised through a queue rather than racing on the stdin sink.
  const outbound = yield* Queue.unbounded<Uint8Array>();
  const encoder = new TextEncoder();

  const child = yield* spawner
    .spawn(
      ChildProcess.make(spawnCommand.command, spawnCommand.args, {
        cwd: options.cwd,
        env,
        forceKillAfter: PI_FORCE_KILL_AFTER,
        shell: spawnCommand.shell,
        stdin: { stream: Stream.fromQueue(outbound), endOnDone: false },
      }),
    )
    .pipe(
      Effect.provideService(Scope.Scope, runtimeScope),
      Effect.mapError(
        (cause) =>
          new PiRpcTransportError({
            detail: `Failed to spawn '${binaryPath} --mode rpc'.`,
            cause,
          }),
      ),
    );

  const stderrRef = yield* Ref.make("");
  yield* child.stderr.pipe(
    Stream.decodeText(),
    Stream.runForEach((chunk) =>
      // Bounded: a chatty or looping child must not grow this without limit.
      Ref.update(stderrRef, (current) => `${current}${chunk}`.slice(-8_192)),
    ),
    Effect.ignore,
    Effect.forkIn(runtimeScope),
  );

  const send = (command: unknown): Effect.Effect<void, PiRpcTransportError> =>
    Queue.offer(outbound, encoder.encode(serializePiRpcCommand(command))).pipe(
      Effect.asVoid,
      Effect.catchCause((cause) =>
        Effect.fail(
          new PiRpcTransportError({
            detail: "Failed to write a command to the Pi RPC session.",
            cause,
          }),
        ),
      ),
    );

  // Framing is ours, not Effect's: `Stream.splitLines` also terminates on CR,
  // and Pi's protocol is LF-only because U+2028/U+2029 and lone CRs are legal
  // inside a JSON string. See `splitPiRpcLines`.
  const records: Stream.Stream<PiRpcRecord> = child.stdout.pipe(
    Stream.decodeText(),
    Stream.mapAccumArray(
      () => "",
      // `chunk` is `mapAccumArray`'s array of decoded STRINGS, not one string
      // being walked per character, so each `piece` is a whole decoded chunk
      // and the framing stays linear in the bytes read.
      (carry: string, chunk) => {
        const decoded: Array<PiRpcRecord> = [];
        let nextCarry = carry;
        for (const piece of chunk) {
          const split = splitPiRpcLines(nextCarry, piece);
          nextCarry = split.carry;
          for (const line of split.lines) {
            // A record we cannot read is dropped rather than failing the
            // stream, which would take the turn's own completion event with it.
            const record = readPiRpcLine(line);
            if (record !== undefined) decoded.push(record);
          }
        }
        return [nextCarry, decoded] as const;
      },
    ),
    Stream.orDie,
  );

  return {
    records,
    send,
    stderr: Ref.get(stderrRef),
    pid: Number(child.pid),
  };
});
