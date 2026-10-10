import * as Context from "effect/Context";
import * as Effect from "effect/Effect";
import * as NodeDns from "node:dns";
import * as NodeOS from "node:os";
import * as NodeSea from "node:sea";

export const Platform = Context.Reference<NodeJS.Platform>(
  "@infinitus/shared/HostProcess/Platform",
  {
    defaultValue: () => process.platform,
  },
);

export const Architecture = Context.Reference<NodeJS.Architecture>(
  "@infinitus/shared/HostProcess/Architecture",
  {
    defaultValue: () => process.arch,
  },
);

export const Hostname = Context.Reference<string>("@infinitus/shared/HostProcess/Hostname", {
  defaultValue: () => NodeOS.hostname(),
});

export const HomeDirectory = Context.Reference<string>(
  "@infinitus/shared/HostProcess/HomeDirectory",
  {
    defaultValue: () => NodeOS.homedir(),
  },
);

export const Environment = Context.Reference<NodeJS.ProcessEnv>(
  "@infinitus/shared/HostProcess/Environment",
  {
    defaultValue: () => process.env,
  },
);

export const WorkingDirectory = Context.Reference<string>(
  "@infinitus/shared/HostProcess/WorkingDirectory",
  {
    defaultValue: () => process.cwd(),
  },
);

export const ExecutablePath = Context.Reference<string>(
  "@infinitus/shared/HostProcess/ExecutablePath",
  {
    defaultValue: () => process.execPath,
  },
);

export const Arguments = Context.Reference<ReadonlyArray<string>>(
  "@infinitus/shared/HostProcess/Arguments",
  {
    defaultValue: () => process.argv,
  },
);

/**
 * The command the shell was given, before Node resolved it to the binary:
 * `t3` for a PATH lookup, `./t3` or the launcher symlink for an explicit
 * path. `process.argv[0]` and `execPath` are always the resolved binary.
 */
export const InvokedAs = Context.Reference<string>("@infinitus/shared/HostProcess/InvokedAs", {
  defaultValue: () => process.argv0,
});

/**
 * Whether this process is a Node single-executable rather than a script run
 * by a Node on the machine. Code that needs a sibling file or a Node to run
 * one branches on this: an executable hosts such things as hidden
 * subcommands of itself.
 */
export const IsExecutable = Context.Reference<boolean>(
  "@infinitus/shared/HostProcess/IsExecutable",
  {
    defaultValue: () => NodeSea.isSea(),
  },
);

/**
 * Every IP address this machine answers to: the interface addresses, plus
 * whatever the resolver returns for the machine's own hostname. The latter
 * matters because a hostname can map to an address no interface carries —
 * Debian-style hosts put `127.0.1.1` in `/etc/hosts` — and a program that
 * records "its" address by resolving its hostname (Firefox's profile lock
 * does) will write that one. "Is this address ours" has to accept both.
 *
 * Best effort: a failed lookup just leaves the interface set.
 */
export const Addresses = Context.Reference<Effect.Effect<ReadonlySet<string>>>(
  "@infinitus/shared/HostProcess/Addresses",
  {
    defaultValue: () =>
      Effect.gen(function* () {
        const interfaces = Object.values(NodeOS.networkInterfaces())
          .flat()
          .flatMap((entry) => (entry ? [entry.address] : []));
        const resolved = yield* Effect.tryPromise(() =>
          NodeDns.promises.lookup(NodeOS.hostname(), { all: true }),
        ).pipe(
          Effect.map((entries) => entries.map((entry) => entry.address)),
          Effect.orElseSucceed(() => [] as ReadonlyArray<string>),
        );
        return new Set([...interfaces, ...resolved]);
      }),
  },
);

/** Undefined on platforms without POSIX uids (Windows). */
export const UserId = Context.Reference<number | undefined>(
  "@infinitus/shared/HostProcess/UserId",
  {
    defaultValue: () => process.getuid?.(),
  },
);

export const isWindows = Effect.map(Platform, (platform) => platform === "win32");
